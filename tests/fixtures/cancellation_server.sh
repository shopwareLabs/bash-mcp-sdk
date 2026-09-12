#!/usr/bin/env bash
# Test fixture: an MCP server whose tools block, spawn a child, ignore TERM, or
# read stdin, so a suite can drive cancellation and teardown over the real
# protocol instead of calling internals. Environment variables and marker files
# record after the fact what a tool did and which process it held. Nothing here
# is part of the SDK; consumers never see this file.
#
# The dispatcher calls every tool as `tool_<name> <arguments-json>`, so each
# function receives the client's arguments as $1. Only tool_hooked_cancel
# inspects its argument.
set -euo pipefail

# Resolve the repo root the way tests/test_helper/common_setup.bash does: walk
# up from this file until the directory holding .bats/ is found.
_fixture_repo_root() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [[ ! -d "${dir}/.bats" ]] && [[ "${dir}" != "/" ]]; do
        dir="$(dirname "${dir}")"
    done
    printf '%s\n' "${dir}"
}

FIXTURE_REPO_ROOT="$(_fixture_repo_root)"

export MCP_TOOLS_LIST_FILE="${FIXTURE_REPO_ROOT}/tests/fixtures/cancellation_tools_list.json"
export MCP_LOG_FILE="${MCP_LOG_FILE:-$(mktemp)}"

source "${FIXTURE_REPO_ROOT}/lib/mcpserver_core.sh"

# Sleeps, then reports completion. SLOW_MARKER_FILE receives "started" as soon
# as the tool body runs, so a test can tell a started call from one that never
# arrived.
tool_slow() {
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'started\n' > "${SLOW_MARKER_FILE}"
    fi
    sleep "${SLOW_SECS:-5}"
    printf 'slow done\n'
}

# Sleeps in a background child and waits for it, publishing the child's pid so
# a test can assert what happened to a process the tool left behind.
tool_slow_with_child() {
    local child_pid
    sleep "${SLOW_SECS:-5}" &
    child_pid=$!
    if [[ -n "${CHILD_PID_FILE:-}" ]]; then
        printf '%s\n' "${child_pid}" > "${CHILD_PID_FILE}"
    fi
    wait "${child_pid}"
    printf 'child done\n'
}

# Ignores TERM and sleeps in one-second steps, re-entering sleep after each, so
# the body outlasts a signal that would end a plain sleep.
tool_stubborn() {
    trap '' TERM
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'started\n' > "${SLOW_MARKER_FILE}"
    fi
    local remaining="${SLOW_SECS:-5}"
    while (( remaining > 0 )); do
        sleep 1
        remaining=$(( remaining - 1 ))
    done
    printf 'stubborn done\n'
}

# The counterpart of tool_hooked_cancel: a plain blocking tool whose
# cancellation hook is defined below.
tool_hooked() {
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'started\n' > "${SLOW_MARKER_FILE}"
    fi
    sleep "${SLOW_SECS:-5}"
    printf 'hooked done\n'
}

# The counterpart of tool_hooked for a shutdown that has to cross a group that
# ignores TERM: the tool holds the grace period open, so a test has a window in
# which to signal the server again while its teardown is still running.
tool_hooked_stubborn() {
    trap '' TERM
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'started\n' > "${SLOW_MARKER_FILE}"
    fi
    local remaining="${SLOW_SECS:-5}"
    while (( remaining > 0 )); do
        sleep 1
        remaining=$(( remaining - 1 ))
    done
    printf 'hooked stubborn done\n'
}

# The cancel hook for tool_hooked_stubborn. It appends rather than overwrites, so
# a test can count how many times a shutdown ran it. Unlike tool_hooked_cancel it
# takes no interest in its argument: a teardown driven by a signal passes an
# empty string, because the in-flight record holds the tool's group and name and
# no arguments.
tool_hooked_stubborn_cancel() {
    printf '%s\n' "${1:-}" >> "${CANCEL_HOOK_FILE}"
}

# Not a dispatched tool and deliberately absent from the tools list: the
# cancellation hook for tool_hooked. It receives the original arguments JSON as
# $1 and records it, so a test can assert the hook ran with what the client
# sent. A missing CANCEL_HOOK_FILE is a failure, not a silent no-op.
tool_hooked_cancel() {
    local arguments="$1"
    printf '%s\n' "${arguments}" > "${CANCEL_HOOK_FILE}"
}

# A cancellation hook that waits on a TERM-ignoring child. Its child pid lets a
# test prove hook cleanup reaches the hook's process group rather than only the
# hook shell.
tool_hooked_child() {
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'started\n' > "${SLOW_MARKER_FILE}"
    fi
    sleep "${SLOW_SECS:-5}"
    printf 'hooked child done\n'
}

tool_hooked_child_cancel() {
    (
        trap '' TERM
        while true; do
            sleep 1
        done
    ) &
    local child_pid
    child_pid=$!
    printf '%s\n' "${child_pid}" > "${HOOK_CHILD_PID_FILE}"
    wait "${child_pid}"
}

# Lets the tool wrapper accept TERM while a child in the same group ignores it.
# The cancellation grace period must be measured against the group, not only
# against this wrapper.
tool_term_wrapper_stubborn_child() {
    (
        trap '' TERM
        while true; do
            sleep 1
        done
    ) &
    local child_pid
    child_pid=$!
    printf '%s\n' "${child_pid}" > "${CHILD_PID_FILE}"
    wait "${child_pid}"
}

# Returns without waiting for the child. The SDK must still remove the child
# with the rest of the tool group once the call has been answered.
tool_unawaited_child() {
    sleep "${SLOW_SECS:-5}" &
    local child_pid
    child_pid=$!
    printf '%s\n' "${child_pid}" > "${CHILD_PID_FILE}"
    printf 'unawaited done\n'
}

# Spawns a child that spawns its own child, publishing both pids, so a test can
# show a teardown reaching a tool's whole descendant tree rather than only the
# process the tool registered. The marker gets "started" at entry and "done"
# once the child has been waited for, so a test can tell a killed call from one
# that ran to completion.
tool_spawns_tree() {
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'started\n' > "${SLOW_MARKER_FILE}"
    fi
    (
        sleep "${SLOW_SECS:-5}" &
        if [[ -n "${GRANDCHILD_PID_FILE:-}" ]]; then
            printf '%s\n' "$!" > "${GRANDCHILD_PID_FILE}"
        fi
        wait
    ) &
    local child_pid
    child_pid=$!
    if [[ -n "${CHILD_PID_FILE:-}" ]]; then
        printf '%s\n' "${child_pid}" > "${CHILD_PID_FILE}"
    fi
    wait "${child_pid}"
    if [[ -n "${SLOW_MARKER_FILE:-}" ]]; then
        printf 'done\n' >> "${SLOW_MARKER_FILE}"
    fi
    printf 'tree done\n'
}

tool_fast() {
    printf 'fast done\n'
}

# Dispatches a nested tools/call through the public entry point — the shape a
# consumer server takes when one tool delegates to another. The nested dispatch
# must start from the plain-call state: with the outer dispatch's server-loop
# state inherited it polls this tool's /dev/null stdin, reads the instant EOF as
# a client closing the stream, and touches the shutdown flag, which stops the
# server once the outer call returns; it also overwrites the outer call's
# in-flight record. The nested call's response is printed, so it lands in the
# outer tool's output and the test can see that the nested dispatch ran.
tool_nested_dispatch() {
    # The nested dispatch turns monitor mode on around its own child, and bash
    # reports the job that just finished on the shell's stderr — which, in a
    # tool, is the tool's output file. Dropped so the outer call's text is the
    # nested response and nothing else.
    handle_tools_call 9001 '{"name":"fast","arguments":{}}' 2>/dev/null
}

# Consumes one line from the server's stdin (the client's protocol pipe) and
# reports it, so a test can show what a tool does to the stream.
tool_reads_stdin() {
    local line
    if IFS= read -r line; then
        printf 'read:%s\n' "${line}"
    else
        printf 'read:EOF\n'
    fi
}

run_mcp_server
