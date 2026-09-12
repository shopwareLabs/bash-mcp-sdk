#!/usr/bin/env bats
# bats file_tags=mcp-core,lifecycle
# Pins server-lifecycle teardown: whatever kills the server — a supervisor
# killing its whole process group, a signal to its pid alone, or SIGKILL that no
# trap can catch — no tool process may outlive it. A signal that arrives while a
# teardown is already running belongs to that pass: it may not cut the teardown
# short, and the shell still dies by the signal.
# The server is tests/fixtures/cancellation_server.sh driven through
# tests/test_helper/mcp_client.bash; mcp_start_server_isolated is the harness
# helper that puts the server in a process group of its own so a test can signal
# the group, and GRANDCHILD_PID_FILE names the deepest process a fixture tool
# spawns, which is what a descendant check has to reach.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"

CANCELLATION_SERVER="${REPO_ROOT}/tests/fixtures/cancellation_server.sh"

# Wait up to <secs> (default 5) for <file> to hold something. The fixture tools
# publish their markers and pids from the server process, so a test waits for
# the evidence that the call is genuinely in flight before acting on it.
_mcp_wait_for_file() {
    local file="$1"
    local limit="${2:-5}"
    local deadline=$(( SECONDS + limit ))
    while (( SECONDS < deadline )); do
        if [[ -s "${file}" ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Wait up to <secs> (default 5) for <file> to carry a line equal to <text>.
_mcp_wait_for_line() {
    local file="$1"
    local text="$2"
    local limit="${3:-5}"
    local deadline=$(( SECONDS + limit ))
    while (( SECONDS < deadline )); do
        if [[ -f "${file}" ]] && grep -qx -- "${text}" "${file}"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Wait up to <secs> (default 5) for process <pid> to be gone. A process this
# shell has already reaped has no ps entry; one that exited but has not been
# reaped yet shows state Z. Either way it is no longer running.
_mcp_wait_for_exit() {
    local pid="$1"
    local limit="${2:-5}"
    local deadline=$(( SECONDS + limit ))
    local state=""
    while (( SECONDS < deadline )); do
        state="$(_mcp_proc_state "${pid}")"
        if [[ -z "${state}" || "${state}" == Z* ]]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Wait up to <tries> polls of 0.05s for the server log to carry a line matching
# <pattern>. A teardown logs each phase as it reaches it, so the line's arrival
# is when that phase began — which is what a test that has to act inside a
# window the teardown holds open has to synchronize on.
_mcp_wait_for_log_pattern() {
    local pattern="$1"
    local tries="${2:-20}"
    local i
    for (( i = 0; i < tries; i++ )); do
        if [[ -f "${MCP_LOG_FILE}" ]] && grep -q -- "${pattern}" "${MCP_LOG_FILE}"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Count the running processes that belong to the server this test started: those
# whose command line names the fixture server *and* carries that server's own
# instance marker. Every subshell the SDK forks for a server — the dispatch
# subshell, a tool's wrapper, the lifeline sentinel — keeps the server's argv,
# so one filter accounts for all of them; the marker is what keeps a process
# from another test or another run, which carries a different one, out of the
# count. Defunct processes are excluded: a server this shell has killed but not
# yet reaped is not running any more.
# The marker is read from the harness, which mints a fresh one per start.
_mcp_fixture_procs() {
    local line
    local count=0
    local marker="--mcp-test-instance=${MCP_SERVER_INSTANCE:-}"
    while IFS= read -r line; do
        if [[ "${line}" == Z* ]]; then
            continue
        fi
        if [[ "${line}" == *"${CANCELLATION_SERVER}"* && "${line}" == *"${marker}"* ]]; then
            count=$(( count + 1 ))
        fi
    done < <(ps -A -o stat=,args=)
    printf '%s' "${count}"
}

# Wait up to <secs> (default 5) for exactly <want> fixture processes to remain.
_mcp_wait_for_proc_count() {
    local want="$1"
    local limit="${2:-5}"
    local deadline=$(( SECONDS + limit ))
    local count=""
    while (( SECONDS < deadline )); do
        count="$(_mcp_fixture_procs)"
        if [[ "${count}" == "${want}" ]]; then
            return 0
        fi
        sleep 0.1
    done
    printf 'expected %s fixture process(es), saw %s\n' "${want}" "${count}" >&2
    return 1
}

# Wait up to <secs> (default 5) for at least <want> fixture processes: the shape
# a test uses to show that the sentinel and the wrapper exist while a call runs,
# so that their absence afterwards means something.
_mcp_wait_for_proc_count_at_least() {
    local want="$1"
    local limit="${2:-5}"
    local deadline=$(( SECONDS + limit ))
    local count=""
    while (( SECONDS < deadline )); do
        count="$(_mcp_fixture_procs)"
        if [[ -n "${count}" ]] && (( count >= want )); then
            return 0
        fi
        sleep 0.1
    done
    printf 'expected at least %s fixture process(es), saw %s\n' "${want}" "${count}" >&2
    return 1
}

# Wait up to <secs> (default 5) for exactly <want> tool output files under
# TMPDIR. One exists while a call is in flight; the SDK names them
# mcp-tool-output.*, and the path is held only by the dispatch subshell that
# created it, so the directory is the only place a test can see whether a
# teardown removed it.
_mcp_tool_output_files() {
    local file
    local count=0
    for file in "${TMPDIR}"/*; do
        if [[ -e "${file}" && "${file}" == */mcp-tool-output.* ]]; then
            count=$(( count + 1 ))
        fi
    done
    printf '%s' "${count}"
}

_mcp_wait_for_tool_output_count() {
    local want="$1"
    local limit="${2:-5}"
    local deadline=$(( SECONDS + limit ))
    local count=""
    while (( SECONDS < deadline )); do
        count="$(_mcp_tool_output_files)"
        if [[ "${count}" == "${want}" ]]; then
            return 0
        fi
        sleep 0.1
    done
    printf 'expected %s tool output file(s), saw %s\n' "${want}" "${count}" >&2
    return 1
}

setup() {
    export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    export SLOW_MARKER_FILE="${BATS_TEST_TMPDIR}/slow.marker"
    export CHILD_PID_FILE="${BATS_TEST_TMPDIR}/child.pid"
    export GRANDCHILD_PID_FILE="${BATS_TEST_TMPDIR}/grandchild.pid"
}

teardown() {
    mcp_stop_server
    unset MCP_LOG_FILE SLOW_MARKER_FILE CHILD_PID_FILE GRANDCHILD_PID_FILE \
        SLOW_SECS MCP_SERVER_PGID TMPDIR CANCEL_HOOK_FILE _MCP_INFLIGHT_FILE \
        MCP_SERVER_INSTANCE
}

@test "the fixture-process count sees only the server this test started" {
    # A server left over from an earlier test or running in a concurrent suite
    # carries the same script path, so a count by path alone folds it into every
    # exact-count assertion in this file. The count is scoped by the per-start
    # marker in the server's argv instead, which a foreign server does not have.
    mcp_start_server_isolated "${CANCELLATION_SERVER}"

    # A decoy that is exactly such a foreign server: the fixture path in its
    # command line, and an instance marker of its own. The trailing `true` keeps
    # the shell from exec'ing its only command, which would replace the argv the
    # scan has to see.
    set -m
    bash -c 'sleep 30; true' "${CANCELLATION_SERVER}" --mcp-test-instance=foreign &
    local decoy_pid=$!
    set +m
    sleep 0.2

    run _mcp_fixture_procs
    assert_output "1"

    run kill -0 -- "-${decoy_pid}"
    assert_success
    kill -KILL -- "-${decoy_pid}" 2>/dev/null || true
    wait "${decoy_pid}" 2>/dev/null || true
}

@test "SIGKILL to the server's process group leaves no tool process behind" {
    export SLOW_SECS=6
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"spawns_tree","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run _mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    # A supervisor killing the whole group: the server, its dispatch subshell,
    # and every other server process die with no chance to run a trap, so the
    # lifeline sentinel is the only thing left that can reach the tool.
    kill -KILL -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    run _mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run _mcp_wait_for_exit "${grandchild_pid}" 3
    assert_success
    run _mcp_wait_for_proc_count 0 3
    assert_success

    # The marker holds the entry line only, so the tool was killed mid-call
    # rather than completing and exiting on its own.
    local marker
    marker="$(<"${SLOW_MARKER_FILE}")"
    assert_equal "${marker}" "started"
}

@test "SIGKILL to the server pid alone leaves no tool descendant behind" {
    export SLOW_SECS=6
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":151,"method":"tools/call","params":{"name":"spawns_tree","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run _mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    kill -KILL "${MCP_SERVER_PID}" 2>/dev/null || true

    run _mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run _mcp_wait_for_exit "${grandchild_pid}" 3
    assert_success
    run _mcp_wait_for_proc_count 0 3
    assert_success
}

@test "SIGTERM to the server's process group stops the in-flight tool" {
    export SLOW_SECS=8
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"slow_with_child","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    # The server and the dispatch subshell die on the signal while the tool is
    # still running, so what stops the tool is the shutdown teardown reaching
    # the group the in-flight file names.
    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    run _mcp_wait_for_exit "${child_pid}" 5
    assert_success
    run _mcp_wait_for_proc_count 0 5
    assert_success
}

@test "SIGTERM to the server pid alone defers until the call finishes, then cleans up" {
    export SLOW_SECS=2
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":301,"method":"tools/call","params":{"name":"spawns_tree","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run _mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    kill -TERM "${MCP_SERVER_PID}" 2>/dev/null || true

    # The signal reaches the server's pid alone, mid-dispatch, and bash runs a
    # trap only between foreground commands — so the call runs to completion
    # first. The marker's second line is that completion: the tool writes it
    # after the child it spawned has been waited for.
    run _mcp_wait_for_line "${SLOW_MARKER_FILE}" "done" $(( SLOW_SECS + 3 ))
    assert_success

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    # The deferral must not leave the tool group alive once the server is gone.
    run _mcp_wait_for_exit "${child_pid}" 5
    assert_success
    run _mcp_wait_for_exit "${grandchild_pid}" 5
    assert_success
    run _mcp_wait_for_proc_count 0 5
    assert_success
}

@test "a completed call leaves no sentinel or tool process behind" {
    export SLOW_SECS=2
    mcp_start_server_isolated "${CANCELLATION_SERVER}"

    run _mcp_wait_for_proc_count 1 3
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":401,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # While the call runs the server is not alone: the dispatch subshell, the
    # tool's wrapper, and the lifeline sentinel all carry the server's argv.
    # The count is what shows the sentinel is real, so its absence after the
    # call means something.
    run _mcp_wait_for_proc_count_at_least 4 5
    assert_success

    run mcp_wait_for_response 401 6
    assert_success

    run _mcp_wait_for_proc_count 1 5
    assert_success
}

@test "a successful call kills an unawaited background child" {
    export SLOW_SECS=5
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":451,"method":"tools/call","params":{"name":"unawaited_child","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    run mcp_wait_for_response 451 5
    assert_success
    run _mcp_wait_for_exit "${child_pid}" 3
    assert_success
}

@test "a cancelled call leaves no sentinel behind" {
    export SLOW_SECS=5
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":501,"method":"tools/call","params":{"name":"spawns_tree","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run _mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":501}}'

    run mcp_assert_no_response 501 1
    assert_success
    run _mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run _mcp_wait_for_exit "${grandchild_pid}" 3
    assert_success

    # The server survived the cancellation, and the call's group is fully gone
    # — sentinel included — rather than merely detached.
    mcp_send '{"jsonrpc":"2.0","id":502,"method":"ping"}'
    run mcp_wait_for_response 502 5
    assert_success
    run _mcp_wait_for_proc_count 1 5
    assert_success
}

@test "a teardown on a catchable signal removes the in-flight call's output file" {
    # The output file's path exists only in the dispatch subshell that created
    # it, so a server that goes down on a signal has nothing but its in-flight
    # record to reach it with. TMPDIR is pointed at a directory of the test's
    # own to make that file observable at all.
    export SLOW_SECS=8
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":601,"method":"tools/call","params":{"name":"slow_with_child","arguments":{}}}'

    run _mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run _mcp_wait_for_tool_output_count 1 5
    assert_success

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    run _mcp_wait_for_tool_output_count 0 5
    assert_success
}

@test "the sentinel survives a group TERM, so a SIGKILLed server still stops the tool" {
    # A cancellation sends the tool's group a TERM, and a cancelled tool that
    # ignores TERM leaves that group alive for the whole two-second grace. A
    # server killed inside that window can run no trap, so the sentinel is the
    # only thing left that can reach the group — and a TERM that removed the
    # sentinel would leave the tool running with nothing left to kill it.
    export SLOW_SECS=12
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":601,"method":"tools/call","params":{"name":"stubborn","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    run _mcp_wait_for_proc_count_at_least 4 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":601}}'
    # Inside the grace period the cancellation is holding open, so the server
    # dies before its own SIGKILL would have landed. The cancelling line is
    # written on the way into the teardown, just before the group TERM, so
    # waiting on it puts this SIGKILL inside the window that TERM opens rather
    # than at a fixed delay a loaded machine can put on either side of it.
    run _mcp_wait_for_log_pattern 'Cancelling in-flight tools/call 601' 20
    assert_success
    kill -KILL -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    # The tool would outlive that window on its own terms — it ignores TERM and
    # sleeps in one-second steps for twelve seconds — so the group is gone
    # within three only because the sentinel fired.
    run _mcp_wait_for_proc_count 0 3
    assert_success
}

@test "a second signal arriving during the teardown does not abort it" {
    # A cancellation TERMs the tool group and then waits out the grace, so a
    # supervisor that has already signalled the server once can signal it again
    # inside that window. The second signal must not re-enter the teardown that
    # is running: re-raised from its own trap it would end the shell where it
    # stands, before the SIGKILL to the tool group and before the removal of the
    # call's files. It is recorded instead, and the pass in progress finishes and
    # then dies by it.
    export SLOW_SECS=10
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
    export CANCEL_HOOK_FILE="${BATS_TEST_TMPDIR}/cancel-hook.log"
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":701,"method":"tools/call","params":{"name":"hooked_stubborn","arguments":{}}}'

    run _mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    run _mcp_wait_for_tool_output_count 1 5
    assert_success

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    # The hook is the first thing a teardown does, so its file appearing is the
    # evidence that the teardown is running: the second signal below lands
    # inside the pass rather than before it starts.
    run _mcp_wait_for_file "${CANCEL_HOOK_FILE}" 5
    assert_success
    kill -TERM "${MCP_SERVER_PID}" 2>/dev/null || true

    run _mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    # The pass ran to its end rather than ending early: the tool group was killed
    # and the call's output file removed.
    run _mcp_wait_for_tool_output_count 0 5
    assert_success
    run _mcp_wait_for_proc_count 0 5
    assert_success
    # Exactly one teardown ran, so the hook ran once: the first signal started
    # the pass and the second did not start another.
    run grep -c '' "${CANCEL_HOOK_FILE}"
    assert_output "1"

    # And the shell died by the signal it was sent, not with a plain zero.
    local status=0
    wait "${MCP_SERVER_PID}" || status=$?
    assert_equal "${status}" 143
}

@test "mcp_start_server fails loudly when the server exits immediately" {
    # The harness's contract: a server that died at startup has not started, so
    # starting one is an error at the start rather than a mystery on the first
    # write. A binary that exits before the check is exactly that server. Its
    # path is resolved rather than hardcoded: `true` lives under /usr/bin on
    # macOS and /bin on Alpine.
    run mcp_start_server "$(type -P true)"

    assert_failure
    assert_output --partial 'exited within 0.2s'
}

@test "a tombstone in-flight record releases the call's files without signalling" {
    # Once a dispatch has reaped its tool group it rewrites the record as a
    # tombstone: the call's tool name and output path stay, the pgid becomes a
    # literal `-`, because that id is free to belong to another process group by
    # then. A teardown reading such a record removes the files it still names
    # and signals nothing — no group, no cancel hook, no grace poll.
    # The record is written by hand here: probing the real one mid-call would
    # race the dispatch subshell that owns it.
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"

    local output_file sentinel_file record_file
    output_file="${BATS_TEST_TMPDIR}/mcp-tool-output.tombstone"
    printf 'tool output\n' > "${output_file}"
    sentinel_file="$(_sentinel_pid_file "${output_file}")"
    printf '%s\n' '4242' > "${sentinel_file}"
    record_file="${BATS_TEST_TMPDIR}/inflight"
    printf '%s %s %s\n' '-' 'slow' "${output_file}" > "${record_file}"
    export _MCP_INFLIGHT_FILE="${record_file}"

    # A decoy in a process group of its own, live across the teardown. The
    # record names no group, so nothing about this one may be signalled.
    set -m
    sleep 30 &
    local decoy_pid
    decoy_pid=$!
    set +m

    # A cancel hook for the tool the record names. The tombstone is what says
    # the call was already stopped, so the hook must not run — and without it a
    # teardown that entered the signalling branch and one that did not are
    # indistinguishable from the files alone.
    local hook_file="${BATS_TEST_TMPDIR}/cancel-hook.log"
    tool_slow_cancel() {
        printf 'ran\n' > "${hook_file}"
    }

    run _server_teardown

    assert_success
    assert [ ! -e "${output_file}" ]
    assert [ ! -e "${sentinel_file}" ]
    assert [ ! -e "${record_file}" ]
    assert [ ! -e "${hook_file}" ]
    assert kill -0 -- "-${decoy_pid}"

    kill -KILL -- "-${decoy_pid}" 2>/dev/null || true
    wait "${decoy_pid}" 2>/dev/null || true
}
