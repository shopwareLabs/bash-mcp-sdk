#!/usr/bin/env bats
# bats file_tags=mcp-core,lifecycle
# Pins server-lifecycle teardown: whatever kills the server — a supervisor
# killing its whole process group, a signal to its pid alone, or SIGKILL that no
# trap can catch — no tool process may outlive it. A signal that arrives while a
# teardown is already running belongs to that pass: it may not cut the teardown
# short, and the shell still dies by the signal.
# Also pinned here: that the harness's process count sees only the server the
# test started, which every exact count below relies on; and, called in-process,
# how a teardown treats the in-flight record it reads: a tombstone releases the
# call's files without signalling, and a record naming a path outside a call
# root removes nothing and hands its cancel hook no MCP_CALL_TMPDIR.
# The server is tests/fixtures/cancellation_server.sh driven through
# tests/test_helper/mcp_client.bash; mcp_start_server_isolated is the harness
# helper that puts the server in a process group of its own so a test can signal
# the group, and GRANDCHILD_PID_FILE names the deepest process a fixture tool
# spawns, which is what a descendant check has to reach.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CANCELLATION_SERVER="${REPO_ROOT}/tests/fixtures/cancellation_server.sh"

setup() {
    # The fixture exports its own config and tools list over these two paths.
    mcp_test_env "${REPO_ROOT}/tests/fixtures/cancellation_config.json" \
        "${REPO_ROOT}/tests/fixtures/cancellation_tools_list.json"
    export SLOW_MARKER_FILE="${BATS_TEST_TMPDIR}/slow.marker"
    export CHILD_PID_FILE="${BATS_TEST_TMPDIR}/child.pid"
    export GRANDCHILD_PID_FILE="${BATS_TEST_TMPDIR}/grandchild.pid"
}

teardown() {
    mcp_stop_server
    # A decoy group a test started is killed here, so a failed assertion before
    # the end of the body cannot leave its sleeper running.
    if [[ -n "${DECOY_PID:-}" ]]; then
        kill -KILL -- "-${DECOY_PID}" 2>/dev/null || true
        wait "${DECOY_PID}" 2>/dev/null || true
    fi
    unset DECOY_PID SLOW_MARKER_FILE CHILD_PID_FILE GRANDCHILD_PID_FILE \
        SLOW_SECS TOOL_SLEEP_PID_FILE MCP_SERVER_PGID TMPDIR CANCEL_HOOK_FILE _MCP_INFLIGHT_FILE \
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
    local foreign="foreign-$$-${RANDOM}"
    set -m
    bash -c 'sleep 30; true' "${CANCELLATION_SERVER}" "--mcp-test-instance=${foreign}" &
    DECOY_PID=$!
    set +m

    # The same scan, scoped to the decoy's marker, finds it: the decoy is past
    # its exec and visible by path before the real count runs.
    MCP_SERVER_INSTANCE="${foreign}" run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 1 3
    assert_success

    run mcp_count_server_procs "${CANCELLATION_SERVER}"
    assert_output "1"
}

@test "SIGKILL to the server's process group leaves no tool process behind" {
    export SLOW_SECS=6
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"spawns_tree","arguments":{}}}'

    run mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    # A supervisor killing the whole group: the server, its dispatch subshell,
    # and every other server process die with no chance to run a trap, so the
    # lifeline sentinel is the only thing left that can reach the tool.
    kill -KILL -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    run mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run mcp_wait_for_exit "${grandchild_pid}" 3
    assert_success
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 0 3
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

    run mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    kill -KILL "${MCP_SERVER_PID}" 2>/dev/null || true

    run mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run mcp_wait_for_exit "${grandchild_pid}" 3
    assert_success
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 0 3
    assert_success
}

@test "SIGKILL to the server pid leaves no tool process behind when the server runs in posix mode" {
    # Posix mode switches process substitution off on Bash 4.1 to 5.0. The
    # sentinel turns posix mode off for itself; without that, it would find no
    # group id there and kill nothing. `set -o posix` goes after the `source`
    # line, which Bash 4.1 to 5.0 cannot parse in posix mode.
    export TOOL_SLEEP_PID_FILE="${BATS_TEST_TMPDIR}/sleep.pid"
    write_fixture_files '{"tools": [{"name": "hold", "inputSchema": {"type": "object"}}]}'
    local server="${BATS_TEST_TMPDIR}/posix_server.sh"
    write_server "${server}" <<'BODY'
set -o posix
tool_hold() {
    sleep 30 &
    printf '%s\n' "$!" > "${TOOL_SLEEP_PID_FILE}"
    wait
}
BODY
    mcp_start_server_isolated "${server}"
    mcp_send '{"jsonrpc":"2.0","id":161,"method":"tools/call","params":{"name":"hold","arguments":{}}}'

    run mcp_wait_for_file "${TOOL_SLEEP_PID_FILE}" 5
    assert_success
    local sleep_pid
    sleep_pid="$(<"${TOOL_SLEEP_PID_FILE}")"

    kill -KILL "${MCP_SERVER_PID}" 2>/dev/null || true

    run mcp_wait_for_exit "${sleep_pid}" 3
    assert_success
}

@test "SIGTERM to the server's process group stops the in-flight tool" {
    export SLOW_SECS=8
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"slow_with_child","arguments":{}}}'

    run mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    # The tool runs in a group of its own, which the shutdown teardown and the
    # lifeline sentinel can each kill; the assertions show only that the server,
    # the tool's child and every server process are gone, not which one did it.
    run mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    run mcp_wait_for_exit "${child_pid}" 5
    assert_success
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 0 5
    assert_success
}

@test "SIGTERM to the server pid alone defers until the call finishes, then cleans up the child the tool left running" {
    export SLOW_SECS=2
    write_fixture_files '{"tools": [{"name": "leaves_child", "inputSchema": {"type": "object"}}]}'
    local server="${BATS_TEST_TMPDIR}/leaves_child_server.sh"
    # The tool returns while its background child still sleeps, so the child is
    # alive after the call and only a cleanup can stop it. The marker is written
    # last, so it exists only once the body ran to its end.
    write_server "${server}" <<'BODY'
tool_leaves_child() {
    sleep 30 &
    printf '%s\n' "$!" > "${CHILD_PID_FILE}"
    sleep "${SLOW_SECS}"
    printf 'done\n' > "${SLOW_MARKER_FILE}"
}
BODY
    mcp_start_server_isolated "${server}"
    mcp_send '{"jsonrpc":"2.0","id":301,"method":"tools/call","params":{"name":"leaves_child","arguments":{}}}'

    run mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    kill -TERM "${MCP_SERVER_PID}" 2>/dev/null || true

    # The signal reaches the server's pid alone, mid-dispatch, and bash runs a
    # trap only between foreground commands, so the call runs to completion
    # first; a teardown that TERMed the tool group instead would cut the body
    # short of the marker.
    run mcp_wait_for_file "${SLOW_MARKER_FILE}" $(( SLOW_SECS + 3 ))
    assert_success

    run mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    run mcp_wait_for_exit "${child_pid}" 5
    assert_success
    run mcp_wait_for_server_procs "${server}" exact 0 5
    assert_success
}

@test "a completed call leaves no sentinel or tool process behind" {
    export SLOW_SECS=2
    mcp_start_server_isolated "${CANCELLATION_SERVER}"

    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 1 3
    assert_success

    mcp_send '{"jsonrpc":"2.0","id":401,"method":"tools/call","params":{"name":"slow","arguments":{}}}'

    run mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success

    # While the call runs the server is not alone: the dispatch subshell, the
    # tool's wrapper, and the lifeline sentinel all carry the server's argv.
    # The count is what shows the sentinel is real, so its absence after the
    # call means something.
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" at-least 4 5
    assert_success

    run mcp_wait_for_response 401 6
    assert_success

    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 1 5
    assert_success
}

@test "a successful call kills an unawaited background child" {
    export SLOW_SECS=5
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":451,"method":"tools/call","params":{"name":"unawaited_child","arguments":{}}}'

    run mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    local child_pid
    child_pid="$(<"${CHILD_PID_FILE}")"

    run mcp_wait_for_response 451 5
    assert_success
    run mcp_wait_for_exit "${child_pid}" 3
    assert_success
}

@test "a cancelled call leaves no sentinel behind" {
    export SLOW_SECS=5
    mcp_start_server_isolated "${CANCELLATION_SERVER}"
    mcp_send '{"jsonrpc":"2.0","id":501,"method":"tools/call","params":{"name":"spawns_tree","arguments":{}}}'

    run mcp_wait_for_file "${CHILD_PID_FILE}" 5
    assert_success
    run mcp_wait_for_file "${GRANDCHILD_PID_FILE}" 5
    assert_success
    local child_pid grandchild_pid
    child_pid="$(<"${CHILD_PID_FILE}")"
    grandchild_pid="$(<"${GRANDCHILD_PID_FILE}")"

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":501}}'

    run mcp_assert_no_response 501 1
    assert_success
    run mcp_wait_for_exit "${child_pid}" 3
    assert_success
    run mcp_wait_for_exit "${grandchild_pid}" 3
    assert_success

    # The server survived the cancellation, and the call's group is fully gone
    # — sentinel included — rather than merely detached.
    mcp_send '{"jsonrpc":"2.0","id":502,"method":"ping"}'
    run mcp_wait_for_response 502 5
    assert_success
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 1 5
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

    run mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" at-least 4 5
    assert_success

    mcp_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":601}}'
    # Inside the grace period the cancellation is holding open, so the server
    # dies before its own SIGKILL would have landed. The cancelling line is
    # written on the way into the teardown, just before the group TERM, so
    # waiting on it puts this SIGKILL inside the window that TERM opens rather
    # than at a fixed delay a loaded machine can put on either side of it.
    run mcp_wait_for_log regex 'Cancelling in-flight tools/call 601' 1
    assert_success
    kill -KILL -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    # The tool would outlive that window on its own terms — it ignores TERM and
    # sleeps in one-second steps for twelve seconds — so the group is gone
    # within three only because the sentinel fired.
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 0 3
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

    run mcp_wait_for_file "${SLOW_MARKER_FILE}" 5
    assert_success
    run mcp_wait_for_call_roots "${TMPDIR}" 1 5
    assert_success

    kill -TERM -- "-${MCP_SERVER_PGID}" 2>/dev/null || true

    # The hook is the first thing a teardown does, so its file appearing is the
    # evidence that the teardown is running: the second signal below lands
    # inside the pass rather than before it starts.
    run mcp_wait_for_file "${CANCEL_HOOK_FILE}" 5
    assert_success
    kill -TERM "${MCP_SERVER_PID}" 2>/dev/null || true

    run mcp_wait_for_exit "${MCP_SERVER_PID}" 5
    assert_success
    # The pass ran to its end rather than ending early: the call root, which it
    # removes after stopping the tool group, is gone.
    run mcp_wait_for_call_roots "${TMPDIR}" 0 5
    assert_success
    run mcp_wait_for_server_procs "${CANCELLATION_SERVER}" exact 0 5
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

    local call_root output_file sentinel_file record_file
    call_root="${BATS_TEST_TMPDIR}/mcp-call.tombstone"
    mkdir "${call_root}"
    output_file="${call_root}/output"
    printf 'tool output\n' > "${output_file}"
    sentinel_file="${call_root}/sentinel"
    printf '%s\n' '4242' > "${sentinel_file}"
    record_file="${BATS_TEST_TMPDIR}/inflight"
    printf '%s %s %s\n' '-' 'slow' "${output_file}" > "${record_file}"
    export _MCP_INFLIGHT_FILE="${record_file}"

    # A cancel hook for the tool the record names. The tombstone is what says
    # the call was already stopped, so the hook must not run — and without it a
    # teardown that entered the signalling branch and one that did not are
    # indistinguishable from the files alone.
    local hook_file="${BATS_TEST_TMPDIR}/cancel-hook.log"
    tool_slow_cancel() {
        printf 'ran\n' > "${hook_file}"
    }
    # `kill -0 -- --` fails on its own, so the tombstone alone never reaches the
    # hook; the spy is what shows the teardown does not probe `-` as a group id.
    local kill_log="${BATS_TEST_TMPDIR}/kill.log"
    kill() {
        printf '%s\n' "$*" >> "${kill_log}"
        builtin kill "$@"
    }

    run _server_teardown

    assert_success
    assert [ ! -e "${call_root}" ]
    assert [ ! -e "${record_file}" ]
    assert [ ! -e "${hook_file}" ]
    assert [ ! -e "${kill_log}" ]
}

@test "an in-flight record naming a path outside a call root is refused, and nothing is removed" {
    # The record is the only handle a teardown has on the call root, and the
    # root is derived from the output path it names. A record naming a path
    # outside an mcp-call.* directory — a stale record, or one written by
    # something other than this SDK — must not aim the removal at that path's
    # parent.
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"

    local victim_dir keep_file record_file
    victim_dir="${BATS_TEST_TMPDIR}/victim"
    mkdir "${victim_dir}"
    keep_file="${victim_dir}/keep"
    printf 'keep me\n' > "${keep_file}"
    record_file="${BATS_TEST_TMPDIR}/inflight"
    printf '%s %s %s\n' '-' 'slow' "${victim_dir}/output" > "${record_file}"
    export _MCP_INFLIGHT_FILE="${record_file}"

    run _server_teardown

    assert_success
    assert [ -d "${victim_dir}" ]
    assert [ -e "${keep_file}" ]
    run grep -qF "refusing to remove ${victim_dir}: not a call root" "${MCP_LOG_FILE}"
    assert_success
}

@test "a live in-flight record naming a path outside a call root gives its cancel hook no MCP_CALL_TMPDIR" {
    # The tombstone case above reaches no cancel hook. A numeric pgid reaches
    # one, and the hook is handed the call's MCP_CALL_TMPDIR during a teardown
    # that may run while the call's directory is still populated. A record
    # naming a path outside an mcp-call.* directory must therefore not hand the
    # hook that path's parent as the directory to read.
    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"

    local victim_dir keep_file record_file hook_file
    victim_dir="${BATS_TEST_TMPDIR}/victim"
    mkdir "${victim_dir}"
    keep_file="${victim_dir}/keep"
    printf 'keep me\n' > "${keep_file}"
    record_file="${BATS_TEST_TMPDIR}/inflight"

    # A real, live process group, in a group of its own: a numeric pgid that
    # passes the teardown's liveness check is what takes the branch that runs
    # the hook. The teardown TERMs it, so it must be a process that dies on the
    # first TERM.
    set -m
    sleep 30 &
    DECOY_PID=$!
    set +m
    printf '%s %s %s\n' "${DECOY_PID}" 'slow' "${victim_dir}/output" > "${record_file}"
    export _MCP_INFLIGHT_FILE="${record_file}"

    hook_file="${BATS_TEST_TMPDIR}/cancel-hook.log"
    tool_slow_cancel() {
        printf '%s\n' "${MCP_CALL_TMPDIR-unset}" > "${hook_file}"
    }

    run _server_teardown

    assert_success
    # The hook ran — the record's group was live — and it saw no directory:
    # `${var-word}` yields the word only when the variable is unset, so a hook
    # handed the victim directory, or an empty string, records something else.
    assert_equal "$(<"${hook_file}")" "unset"
    assert [ -d "${victim_dir}" ]
    assert [ -e "${keep_file}" ]
    run grep -qF "refusing to derive a call root from ${victim_dir}/output: not a call root" "${MCP_LOG_FILE}"
    assert_success
    run mcp_wait_for_exit "${DECOY_PID}" 3
    assert_success
}
