#!/bin/bash
# Client harness for driving an MCP server over a FIFO, one JSON-RPC line at a
# time, so a test can write to the server while it is mid-call instead of
# feeding it a fixed stdin and waiting for exit.
#
# Source this file from a BATS suite; it defines no setup or teardown of its
# own. Every helper reports its own failures on stderr and returns non-zero, so
# a caller under `set -e` fails at the point of the problem rather than on a
# timeout later.
#
# Exports set by mcp_start_server:
#   MCP_SERVER_PID      pid of the server process
#   MCP_SERVER_OUT      file capturing the server's stdout (the JSON-RPC stream)
#                       from the first response after startup on:
#                       mcp_start_server sends one ping of its own (id
#                       "mcp-harness-ready"), checks that its response is the
#                       only thing on the stream, then empties the file. The
#                       ping still appears in the server's log and, with
#                       MCP_LOG_STDERR, in MCP_SERVER_ERR.
#   MCP_SERVER_ERR      file capturing the server's stderr
#   MCP_CLIENT_TMPDIR   directory holding the FIFO and both capture files
#   MCP_SERVER_INSTANCE marker unique to this start, carried in the server's
#                       argument vector and inherited by every process the
#                       server forks. A test that has to find the server's
#                       processes with `ps` filters on it, so a server started
#                       by another test — or by another run — is never counted.
#                       The server script receives it as an argument and is
#                       free to ignore it.
#
# mcp_start_server_isolated sets the same, plus MCP_SERVER_PGID, the process
# group id of the server it started.
#
# The write end of the server's stdin stays open in MCP_CLIENT_FD for the life
# of the test, so the server blocks on read instead of seeing EOF between
# messages.
#
# Below the server helpers sit the ones every suite shares: polling waits for a
# file, a process exit and a log line, counters for a server's processes and a
# call's root directories, builders for the request lines a test sends, and
# assertions on a tools/call result and on the order of two responses.

# File descriptor holding the FIFO write end; empty until mcp_start_server
# opens it. Allocated dynamically (>10) because bats itself holds fd 3, and bats'
# tracing holds fd 4.
MCP_CLIENT_FD=""
MCP_CLIENT_FD_OPEN=0

# Print the process state of <pid>, empty when it has no ps entry. Read from a
# full listing filtered here because BusyBox `ps` has no `-p` selection, and
# through the `stat` keyword, the one spelling procps, BSD and BusyBox share —
# `state` is procps and BSD only.
_mcp_proc_state() {
    local pid="$1"
    local entry_pid state
    while read -r entry_pid state _; do
        if [[ "${entry_pid}" == "${pid}" ]]; then
            printf '%s' "${state}"
            return 0
        fi
    done < <(ps -A -o pid=,stat= 2>/dev/null)
    return 0
}

# Wait until the server just started answers a ping, so its startup (temp files,
# trap installation) is complete before a test signals it or counts its
# processes. Fails loudly on a ping that cannot be written, a server that is
# gone, no answer in 10s, or anything on the protocol stream besides the ping's
# own response: a server that died at startup has not started, and driving its
# pipe would raise the failure somewhere else entirely. On success the capture
# file is emptied, so MCP_SERVER_OUT holds only what a test provokes itself.
_mcp_await_ready() {
    local ready_id="mcp-harness-ready"
    local expected='{"jsonrpc":"2.0","id":"mcp-harness-ready","result":{}}'
    local timeout=10
    local reason=""

    if ! mcp_send "{\"jsonrpc\":\"2.0\",\"id\":\"${ready_id}\",\"method\":\"ping\"}" 2>/dev/null; then
        reason="exited during startup (the ping could not be written)"
    else
        local polls
        local i
        local state
        polls="$(_mcp_polls_for mcp_start_server "${timeout}")"
        reason="gave no ping answer within ${timeout}s"
        for (( i = 0; i < polls; i++ )); do
            # The id is on the stream and the last byte is a newline, so the
            # response is whole: the comparison never sees a half-written line.
            if grep -qF "\"id\":\"${ready_id}\"" "${MCP_SERVER_OUT}" \
                && [[ -z "$(tail -c 1 "${MCP_SERVER_OUT}")" ]]; then
                if cmp -s - "${MCP_SERVER_OUT}" <<< "${expected}"; then
                    : > "${MCP_SERVER_OUT}"
                    return 0
                fi
                reason="wrote to the protocol stream during startup"
                break
            fi
            # An empty state means the shell already reaped the child, and a
            # leading "Z" means it exited and is waiting to be reaped. `kill -0`
            # cannot stand in for this: it succeeds for a zombie.
            state="$(_mcp_proc_state "${MCP_SERVER_PID}")"
            if [[ -z "${state}" || "${state}" == Z* ]]; then
                reason="exited during startup"
                break
            fi
            sleep 0.1
        done
    fi

    printf 'mcp_start_server: server %s %s\n' "${MCP_SERVER_PID}" "${reason}" >&2
    if [[ -s "${MCP_SERVER_OUT}" ]]; then
        printf 'mcp_start_server: server stdout:\n%s\n' "$(< "${MCP_SERVER_OUT}")" >&2
    fi
    if [[ -s "${MCP_SERVER_ERR}" ]]; then
        printf 'mcp_start_server: server stderr:\n%s\n' "$(< "${MCP_SERVER_ERR}")" >&2
    fi
    mcp_stop_server
    return 1
}

# Start <server-script-path> with a FIFO as its stdin and its stdout and stderr
# captured to files under a fresh temp dir. Returns once the server has answered
# a ping, so it is past startup; fails loudly if it never does.
mcp_start_server() {
    local server_script="${1:-}"
    if [[ -z "${server_script}" || ! -x "${server_script}" ]]; then
        printf 'mcp_start_server: not an executable server script: %s\n' "${server_script}" >&2
        return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/mcp-client.XXXXXX")"
    MCP_CLIENT_TMPDIR="${tmpdir}"
    MCP_SERVER_OUT="${tmpdir}/server.out"
    MCP_SERVER_ERR="${tmpdir}/server.err"
    MCP_SERVER_IN="${tmpdir}/server.in"
    export MCP_CLIENT_TMPDIR MCP_SERVER_OUT MCP_SERVER_ERR

    : > "${MCP_SERVER_OUT}"
    : > "${MCP_SERVER_ERR}"
    mkfifo "${MCP_SERVER_IN}"

    # A marker unique to this start, passed to the server as an argument so it
    # sits in the server's argv. A bash subshell keeps its parent's argv, so
    # every process the server forks carries it, and a process left over from
    # an earlier test or another run carries a different one. The fixture
    # scripts take no arguments and ignore it.
    MCP_SERVER_INSTANCE="mcp-test-$$-${RANDOM}${RANDOM}"
    export MCP_SERVER_INSTANCE

    # Opened for append: the harness empties this file while the server holds it,
    # and a plain write offset would leave NUL bytes before the next response.
    # The child blocks opening the FIFO for reading until the parent opens the
    # write end below; the two opens complete together.
    "${server_script}" "--mcp-test-instance=${MCP_SERVER_INSTANCE}" \
        < "${MCP_SERVER_IN}" >> "${MCP_SERVER_OUT}" 2> "${MCP_SERVER_ERR}" &
    MCP_SERVER_PID=$!
    export MCP_SERVER_PID

    exec {MCP_CLIENT_FD}> "${MCP_SERVER_IN}"
    MCP_CLIENT_FD_OPEN=1

    _mcp_await_ready
}

# Write one JSON-RPC line to the server's stdin. Fails rather than sending a
# blank line, which the server skips silently.
mcp_send() {
    local line="${1:-}"
    if [[ "${MCP_CLIENT_FD_OPEN}" != "1" ]]; then
        printf 'mcp_send: server stdin is not open\n' >&2
        return 1
    fi
    if [[ -z "${line}" ]]; then
        printf 'mcp_send: refusing to send an empty line\n' >&2
        return 1
    fi
    # In a subshell: to a dead reader the write raises SIGPIPE, which ends the
    # subshell instead of the test process.
    if ! ( printf '%s\n' "${line}" >&"${MCP_CLIENT_FD}" ) 2>/dev/null; then
        printf 'mcp_send: write failed; the server is not reading its stdin (pid %s)\n' \
            "${MCP_SERVER_PID}" >&2
        return 1
    fi
}

# Close the held write end, so the server reads EOF. Safe on an already-closed
# stream.
mcp_close_stdin() {
    if [[ "${MCP_CLIENT_FD_OPEN}" == "1" ]]; then
        exec {MCP_CLIENT_FD}>&-
        MCP_CLIENT_FD_OPEN=0
    fi
    return 0
}

# Print the first captured line whose .id equals <id>. Polls until the line
# arrives or <timeout-secs> (default 10) elapse, then returns non-zero with a
# diagnostic on stderr.
mcp_wait_for_response() {
    local id="${1:-}"
    local timeout="${2:-10}"
    if [[ -z "${id}" ]]; then
        printf 'mcp_wait_for_response: missing response id\n' >&2
        return 1
    fi

    local polls
    local i
    local line
    polls="$(_mcp_polls_for mcp_wait_for_response "${timeout}")" || return 1
    for (( i = 0; i < polls; i++ )); do
        while IFS= read -r line; do
            if [[ -z "${line}" ]]; then
                continue
            fi
            if printf '%s' "${line}" | jq -e --argjson id "${id}" '.id == $id' >/dev/null 2>&1; then
                printf '%s\n' "${line}"
                return 0
            fi
        done < "${MCP_SERVER_OUT}"
        sleep 0.1
    done

    printf 'mcp_wait_for_response: no response for id %s within %ss\n' "${id}" "${timeout}" >&2
    return 1
}

# Wait <window-secs>, then fail if any captured line carries <id>. Returns
# non-zero on an unexpected response, so a bare call fails the enclosing test.
mcp_assert_no_response() {
    local id="${1:-}"
    local window="${2:-}"
    if [[ -z "${id}" || -z "${window}" ]]; then
        printf 'mcp_assert_no_response: usage: mcp_assert_no_response <id> <window-secs>\n' >&2
        return 1
    fi

    sleep "${window}"
    local line
    while IFS= read -r line; do
        if [[ -z "${line}" ]]; then
            continue
        fi
        if printf '%s' "${line}" | jq -e --argjson id "${id}" '.id == $id' >/dev/null 2>&1; then
            printf 'mcp_assert_no_response: unexpected response for id %s: %s\n' "${id}" "${line}" >&2
            return 1
        fi
    done < "${MCP_SERVER_OUT}"
    return 0
}

# Close stdin, TERM the server if it is still alive, reap it, and remove the
# temp dir. Safe to call twice, and safe after a failed mcp_start_server. The
# pid and capture paths are left in place so a caller can still assert on them.
# A server still running 10s after the TERM is killed and the call fails, so a
# server that does not stop fails the test instead of hanging it.
mcp_stop_server() {
    local rc=0
    mcp_close_stdin

    if [[ -n "${MCP_SERVER_PID:-}" ]] && kill -0 "${MCP_SERVER_PID}" 2>/dev/null; then
        kill -TERM "${MCP_SERVER_PID}" 2>/dev/null || true
        if ! mcp_wait_for_exit "${MCP_SERVER_PID}" 10 2>/dev/null; then
            printf 'mcp_stop_server: server %s was still running 10s after SIGTERM; sent SIGKILL\n' \
                "${MCP_SERVER_PID}" >&2
            kill -KILL "${MCP_SERVER_PID}" 2>/dev/null || true
            rc=1
        fi
        wait "${MCP_SERVER_PID}" 2>/dev/null || true
    fi

    if [[ -n "${MCP_CLIENT_TMPDIR:-}" && -d "${MCP_CLIENT_TMPDIR}" ]]; then
        rm -rf -- "${MCP_CLIENT_TMPDIR}"
    fi
    return "${rc}"
}

# Start a server exactly as mcp_start_server does, but in a process group of its
# own, so a test can signal the whole group (the shape a supervisor uses) as
# well as the leader pid alone. Monitor mode is what puts the background job in
# a new group, and the job's pid is that group's id. Everything else — the FIFO,
# the capture files, the exported variables — is mcp_start_server's contract,
# which this does not change.
# Exports on success, in addition to mcp_start_server's: MCP_SERVER_PGID.
mcp_start_server_isolated() {
    local rc=0
    set -m
    # Collected with `||` so a failed start under errexit still turns monitor
    # mode off before returning.
    mcp_start_server "$@" || rc=$?
    set +m
    if [[ "${rc}" -ne 0 ]]; then
        return "${rc}"
    fi
    MCP_SERVER_PGID="${MCP_SERVER_PID}"
    export MCP_SERVER_PGID
    return 0
}

# --- polling waits ---
#
# Every wait below takes its limit in whole seconds, turns it into a count of
# polls (10 per second, one every 0.1s), and fails with a message naming what it
# waited for and the limit. A limit read from SECONDS would end up to a second
# early whenever the clock ticks between the read and the first poll, which a
# one-second limit cannot absorb. The limit is a required argument.

# Print the poll count for <secs> seconds. <caller> names the helper in the
# diagnostic. Returns 1 for anything but a positive whole number of seconds.
_mcp_polls_for() {
    local caller="$1"
    local secs="${2:-}"
    local polls=0
    case "${secs}" in
        '' | *[!0-9]*) ;;
        *) polls=$(( 10#${secs} * 10 )) ;;
    esac
    if (( polls == 0 )); then
        printf '%s: the limit must be a positive whole number of seconds, got "%s"\n' \
            "${caller}" "${secs}" >&2
        return 1
    fi
    printf '%s' "${polls}"
}

# Wait for <file> to exist and hold something.
mcp_wait_for_file() {
    local file="${1:-}"
    local secs="${2:-}"
    local polls
    local i
    if [[ -z "${file}" ]]; then
        printf 'mcp_wait_for_file: usage: mcp_wait_for_file <file> <secs>\n' >&2
        return 1
    fi
    polls="$(_mcp_polls_for mcp_wait_for_file "${secs}")" || return 1
    for (( i = 0; i < polls; i++ )); do
        if [[ -s "${file}" ]]; then
            return 0
        fi
        sleep 0.1
    done
    printf 'mcp_wait_for_file: %s held nothing after %ss\n' "${file}" "${secs}" >&2
    return 1
}

# Wait for process <pid> to be gone. A process the shell has already reaped has
# no ps entry, and one that exited but has not been reaped yet shows state Z;
# either way it is no longer running. `kill -0` cannot stand in for this: it
# succeeds for a zombie.
mcp_wait_for_exit() {
    local pid="${1:-}"
    local secs="${2:-}"
    local polls
    local i
    local state
    if [[ -z "${pid}" ]]; then
        printf 'mcp_wait_for_exit: usage: mcp_wait_for_exit <pid> <secs>\n' >&2
        return 1
    fi
    polls="$(_mcp_polls_for mcp_wait_for_exit "${secs}")" || return 1
    for (( i = 0; i < polls; i++ )); do
        state="$(_mcp_proc_state "${pid}")"
        if [[ -z "${state}" || "${state}" == Z* ]]; then
            return 0
        fi
        sleep 0.1
    done
    printf 'mcp_wait_for_exit: process %s was still running after %ss\n' "${pid}" "${secs}" >&2
    return 1
}

# Wait for MCP_LOG_FILE to carry a line matching <pattern>. <mode> is `fixed`
# for a fixed string (grep -F) or `regex` for an extended regular expression
# (grep -E). A teardown logs each phase as it reaches it, so the line's arrival
# is when that phase began, which is what a test that has to act inside a window
# the teardown holds open synchronizes on.
mcp_wait_for_log() {
    local mode="${1:-}"
    local pattern="${2:-}"
    local secs="${3:-}"
    local flag
    local polls
    local i
    case "${mode}" in
        fixed) flag="-F" ;;
        regex) flag="-E" ;;
        *)
            printf 'mcp_wait_for_log: the mode must be "fixed" or "regex", got "%s"\n' "${mode}" >&2
            return 1
            ;;
    esac
    if [[ -z "${pattern}" || -z "${MCP_LOG_FILE:-}" ]]; then
        printf 'mcp_wait_for_log: usage: mcp_wait_for_log <fixed|regex> <pattern> <secs>, with MCP_LOG_FILE set\n' >&2
        return 1
    fi
    polls="$(_mcp_polls_for mcp_wait_for_log "${secs}")" || return 1
    for (( i = 0; i < polls; i++ )); do
        if [[ -f "${MCP_LOG_FILE}" ]] && grep -q "${flag}" -- "${pattern}" "${MCP_LOG_FILE}"; then
            return 0
        fi
        sleep 0.1
    done
    printf 'mcp_wait_for_log: no %s match for "%s" in %s after %ss\n' \
        "${mode}" "${pattern}" "${MCP_LOG_FILE}" "${secs}" >&2
    return 1
}

# --- counters ---

# Print the number of running processes that belong to the server this test
# started: those whose command line names <script> and carries the server's own
# instance marker. Every subshell the SDK forks for a server (the dispatch
# subshell, a tool's wrapper, the lifeline sentinel) keeps the server's argv, so
# one filter accounts for all of them, and the marker keeps a process from
# another test or another run, which carries a different one, out of the count.
# Defunct processes are excluded: a server this shell has killed but not yet
# reaped is not running any more. The marker is read from the harness, which
# mints a fresh one per start.
mcp_count_server_procs() {
    local script="${1:-}"
    local marker="--mcp-test-instance=${MCP_SERVER_INSTANCE:-}"
    local line
    local count=0
    if [[ -z "${script}" ]]; then
        printf 'mcp_count_server_procs: usage: mcp_count_server_procs <script>\n' >&2
        return 1
    fi
    while IFS= read -r line; do
        if [[ "${line}" == Z* ]]; then
            continue
        fi
        if [[ "${line}" == *"${script}"* && "${line}" == *"${marker}"* ]]; then
            count=$(( count + 1 ))
        fi
    done < <(ps -A -o stat=,args=)
    printf '%s' "${count}"
}

# Print the number of call roots directly under <dir>. The SDK names a call's
# root mcp-call.*, it exists while the call is in flight and holds the call's
# files, and its path is held only by the dispatch subshell that created it, so
# the directory is the only place a test can see whether a teardown removed it.
mcp_count_call_roots() {
    local dir="${1:-}"
    local entry
    local count=0
    if [[ -z "${dir}" ]]; then
        printf 'mcp_count_call_roots: usage: mcp_count_call_roots <dir>\n' >&2
        return 1
    fi
    for entry in "${dir}"/*; do
        if [[ -e "${entry}" && "${entry}" == */mcp-call.* ]]; then
            count=$(( count + 1 ))
        fi
    done
    printf '%s' "${count}"
}

# Poll the counter command given as the trailing arguments until its count
# satisfies <comparison> (`exact`: equal to <want>; `at-least`: not below it),
# for at most <secs> seconds. <what> names the counted thing in the diagnostic.
_mcp_wait_for_count() {
    local what="$1"
    local comparison="$2"
    local want="$3"
    local secs="$4"
    shift 4
    local polls
    local i
    local count=""
    case "${comparison}" in
        exact | at-least) ;;
        *)
            printf '_mcp_wait_for_count: the comparison must be "exact" or "at-least", got "%s"\n' \
                "${comparison}" >&2
            return 1
            ;;
    esac
    case "${want}" in
        '' | *[!0-9]*)
            printf '_mcp_wait_for_count: the wanted count must be a whole number, got "%s"\n' "${want}" >&2
            return 1
            ;;
    esac
    polls="$(_mcp_polls_for "waiting for ${what}" "${secs}")" || return 1
    for (( i = 0; i < polls; i++ )); do
        count="$("$@")" || return 1
        if [[ "${comparison}" == exact && "${count}" == "${want}" ]]; then
            return 0
        fi
        if [[ "${comparison}" == at-least && -n "${count}" ]] && (( count >= want )); then
            return 0
        fi
        sleep 0.1
    done
    printf 'expected %s %s %s, saw %s after %ss\n' "${comparison}" "${want}" "${what}" "${count}" "${secs}" >&2
    return 1
}

# Wait until the processes of the server started from <script> number <want>
# (<comparison> `exact`) or at least <want> (`at-least`). The at-least form is
# how a test shows that the sentinel and the wrapper exist while a call runs, so
# that their absence afterwards means something.
mcp_wait_for_server_procs() {
    local script="${1:-}"
    local comparison="${2:-}"
    local want="${3:-}"
    local secs="${4:-}"
    if [[ -z "${script}" ]]; then
        printf 'mcp_wait_for_server_procs: usage: mcp_wait_for_server_procs <script> <exact|at-least> <want> <secs>\n' >&2
        return 1
    fi
    _mcp_wait_for_count "server process(es)" "${comparison}" "${want}" "${secs}" \
        mcp_count_server_procs "${script}"
}

# Wait until exactly <want> call roots exist under <dir>.
mcp_wait_for_call_roots() {
    local dir="${1:-}"
    local want="${2:-}"
    local secs="${3:-}"
    if [[ -z "${dir}" ]]; then
        printf 'mcp_wait_for_call_roots: usage: mcp_wait_for_call_roots <dir> <want> <secs>\n' >&2
        return 1
    fi
    _mcp_wait_for_count "call root(s) under ${dir}" exact "${want}" "${secs}" \
        mcp_count_call_roots "${dir}"
}

# --- request builders ---
#
# Each prints one JSON-RPC request line, built by jq from its arguments so a
# name or a document reaches the server as the JSON it names, never as text
# spliced into a template. The id is a required argument and is JSON: `7` for a
# number, `'"a"'` for a string. An argument past the OS argument limit cannot
# pass through jq's argv; a test that sends one builds its own line with
# `--rawfile`.

# Print a tools/call request for tool <name> with <arguments-json>.
mcp_tools_call_request() {
    if (( $# != 3 )); then
        printf 'mcp_tools_call_request: usage: mcp_tools_call_request <id> <tool-name> <arguments-json>\n' >&2
        return 1
    fi
    jq -nc --argjson id "$1" --arg name "$2" --argjson arguments "$3" \
        '{jsonrpc: "2.0", id: $id, method: "tools/call", params: {name: $name, arguments: $arguments}}'
}

# Print a ping request.
mcp_ping_request() {
    if (( $# != 1 )); then
        printf 'mcp_ping_request: usage: mcp_ping_request <id>\n' >&2
        return 1
    fi
    jq -nc --argjson id "$1" '{jsonrpc: "2.0", id: $id, method: "ping"}'
}

# --- result and order assertions ---

# Assert <response> answers request <id> with a result, no error member, whose
# isError is <is-error> (`true` or `false`) and whose first content text is
# <text>: the whole text when <match> is `exact` (the default), or its start
# when <match> is `prefix`. On a mismatch print the expectation and the
# response on stderr and return 1. The text travels through jq's argv, so it
# must fit the OS argument limit; mcp_assert_tool_result_file takes a larger one.
mcp_assert_tool_result() {
    local response="${1:-}"
    local id="${2:-}"
    local is_error="${3:-}"
    local text="${4:-}"
    local match="${5:-exact}"
    if (( $# < 4 || $# > 5 )) || [[ -z "${id}" ]]; then
        printf 'mcp_assert_tool_result: usage: mcp_assert_tool_result <response> <id> <true|false> <text> [exact|prefix]\n' >&2
        return 1
    fi
    case "${is_error}" in
        true | false) ;;
        *)
            printf 'mcp_assert_tool_result: isError must be "true" or "false", got "%s"\n' "${is_error}" >&2
            return 1
            ;;
    esac
    case "${match}" in
        exact | prefix) ;;
        *)
            printf 'mcp_assert_tool_result: the match must be "exact" or "prefix", got "%s"\n' "${match}" >&2
            return 1
            ;;
    esac
    if ! jq -e --argjson id "${id}" --argjson e "${is_error}" --arg t "${text}" --arg m "${match}" '
        .id == $id and .result.isError == $e and (.error == null)
        and (.result.content[0].text as $actual
             | if $m == "exact" then $actual == $t else ($actual | startswith($t)) end)
    ' <<< "${response}" > /dev/null 2>&1; then
        printf 'mcp_assert_tool_result: the response does not match\n  expected: id %s, isError %s, text (%s match): %s\n  actual:   %s\n' \
            "${id}" "${is_error}" "${match}" "${text}" "${response}" >&2
        return 1
    fi
}

# Assert <response> answers request <id> with a result, no error member, whose
# isError is <is-error> (`true` or `false`) and whose first content text is
# exactly the content of <expected-file>. The text never passes through argv, so
# it may be of any size. On a mismatch print the sizes and the starts of both
# sides on stderr and return 1.
mcp_assert_tool_result_file() {
    local response="${1:-}"
    local id="${2:-}"
    local is_error="${3:-}"
    local expected_file="${4:-}"
    local actual
    if (( $# != 4 )) || [[ -z "${id}" || -z "${expected_file}" ]]; then
        printf 'mcp_assert_tool_result_file: usage: mcp_assert_tool_result_file <response> <id> <true|false> <expected-file>\n' >&2
        return 1
    fi
    case "${is_error}" in
        true | false) ;;
        *)
            printf 'mcp_assert_tool_result_file: isError must be "true" or "false", got "%s"\n' "${is_error}" >&2
            return 1
            ;;
    esac
    if [[ ! -f "${expected_file}" ]]; then
        printf 'mcp_assert_tool_result_file: no such expected file: %s\n' "${expected_file}" >&2
        return 1
    fi
    if ! jq -e --argjson id "${id}" --argjson e "${is_error}" --rawfile t "${expected_file}" '
        .id == $id and .result.isError == $e and (.error == null)
        and .result.content[0].text == $t
    ' <<< "${response}" > /dev/null 2>&1; then
        actual="$(jq -c '{id, isError: .result.isError, error, text_chars: (.result.content[0].text | length), text_start: (.result.content[0].text[0:100])}' \
            <<< "${response}" 2>/dev/null)" \
            || actual="$(printf '%s' "${response}" | head -c 300)"
        printf 'mcp_assert_tool_result_file: the response does not match\n  expected: id %s, isError %s, text of %s bytes in %s, starting: %s\n  actual:   %s\n' \
            "${id}" "${is_error}" "$(( $(wc -c < "${expected_file}") ))" "${expected_file}" \
            "$(head -c 100 "${expected_file}")" "${actual}" >&2
        return 1
    fi
}

# Assert the server's stdout (MCP_SERVER_OUT) holds the response for <first-id>
# on an earlier line than the response for <second-id>. Fails, naming the
# missing one, when either is absent. Each id is JSON, as for the builders.
mcp_assert_response_order() {
    local first="${1:-}"
    local second="${2:-}"
    local line
    local n=0
    local first_at=0
    local second_at=0
    if (( $# != 2 )) || [[ -z "${first}" || -z "${second}" ]]; then
        printf 'mcp_assert_response_order: usage: mcp_assert_response_order <first-id> <second-id>\n' >&2
        return 1
    fi
    if [[ ! -f "${MCP_SERVER_OUT:-}" ]]; then
        printf 'mcp_assert_response_order: no server capture file: "%s"\n' "${MCP_SERVER_OUT:-}" >&2
        return 1
    fi
    while IFS= read -r line; do
        n=$(( n + 1 ))
        if [[ -z "${line}" ]]; then
            continue
        fi
        if (( first_at == 0 )) && jq -e --argjson id "${first}" '.id == $id' <<< "${line}" > /dev/null 2>&1; then
            first_at="${n}"
        fi
        if (( second_at == 0 )) && jq -e --argjson id "${second}" '.id == $id' <<< "${line}" > /dev/null 2>&1; then
            second_at="${n}"
        fi
    done < "${MCP_SERVER_OUT}"
    if (( first_at == 0 || second_at == 0 || first_at >= second_at )); then
        printf 'mcp_assert_response_order: expected the response for id %s before the one for id %s\n  actual: the first is on line %s, the second on line %s (0 means no such response)\n' \
            "${first}" "${second}" "${first_at}" "${second_at}" >&2
        return 1
    fi
}
