#!/usr/bin/env bats
# bats file_tags=mcp-core,exit-trap-chaining
# Pins what run_mcp_server does with the EXIT handler a server script installed
# before it called in. The direct shape chains that handler into the server's
# own teardown instead of dropping it, on a clean exit and on a trapped signal
# alike, and neither the handler's stdout nor its failure reaches the JSON-RPC
# stream or the server's exit status.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    # Only the case that drives a request reads these, but every server script
    # this suite writes points at the same pair.
    cat > "${BATS_TEST_TMPDIR}/config.json" <<'JSON'
{}
JSON

    cat > "${BATS_TEST_TMPDIR}/tools.json" <<'JSON'
{"tools": []}
JSON

    export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    : > "${MCP_LOG_FILE}"
}

teardown() {
    mcp_stop_server
    unset MCP_LOG_FILE
}

# Print the number of entries directly under <dir>. Every temp file a server
# creates lives there — the shutdown flag, the in-flight record, the partial-line
# handoff and the lifeline directory — and its teardown releases them all, so the
# count is how far a teardown got.
_mcp_entry_count() {
    local -a entries=("$1"/*)
    [[ -e "${entries[0]}" ]] || entries=()
    printf '%s' "${#entries[@]}"
}

@test "a caller's EXIT handler runs when the server exits on a closed stdin" {
    local state_file="${BATS_TEST_TMPDIR}/handler-state"
    printf 'state\n' > "${state_file}"

    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'rm -f -- "${state_file}"' EXIT
BODY

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_success
    assert [ ! -e "${state_file}" ]
}

@test "a caller's EXIT handler runs when a signal tears the server down" {
    local marker_file="${BATS_TEST_TMPDIR}/handler-marker"

    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'printf "chained\n" > "${marker_file}"' EXIT
BODY

    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"
    kill -TERM "${MCP_SERVER_PID}"

    local status=0
    wait "${MCP_SERVER_PID}" || status=$?

    assert [ -e "${marker_file}" ]
    assert_equal "$(<"${marker_file}")" "chained"
    # The handler ran inside the teardown, and the shell still died by the signal
    # it was sent rather than with a status the handler could have set.
    assert_equal "${status}" 143
}

@test "a chained handler's stdin is /dev/null, not the client's stream" {
    local marker_file="${BATS_TEST_TMPDIR}/read-status"

    # The handler reads once with a 2s timeout. On the client's held-open FIFO
    # that read blocks to the timeout (status > 128); on /dev/null it sees EOF at
    # once (status 1). The marker records which stdin the handler was given.
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'IFS= read -r -t 2 _; printf "%s" "\$?" > "${marker_file}"' EXIT
BODY

    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"
    kill -TERM "${MCP_SERVER_PID}"

    local status=0
    wait "${MCP_SERVER_PID}" || status=$?

    assert_equal "${status}" 143
    assert [ -e "${marker_file}" ]
    assert_equal "$(<"${marker_file}")" "1"
}

@test "both commands of a compound EXIT handler run, each exactly once" {
    local first_marker="${BATS_TEST_TMPDIR}/first-marker"
    local second_marker="${BATS_TEST_TMPDIR}/second-marker"

    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
first_fn() { printf 'first\n' >> "${first_marker}"; }
second_fn() { printf 'second\n' >> "${second_marker}"; }
trap 'first_fn; second_fn' EXIT
BODY

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_success
    # One line each, from a teardown that runs the captured handler once and the
    # second pass a shell makes over its EXIT trap not at all.
    run grep -c '' "${first_marker}"
    assert_output "1"
    run grep -c '' "${second_marker}"
    assert_output "1"
}

@test "an EXIT handler's stdout goes to stderr, not the protocol stream" {
    local marker_file="${BATS_TEST_TMPDIR}/handler-marker"

    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
handler() {
    printf 'handler stdout\n'
    printf 'ran\n' > "${marker_file}"
}
trap 'handler' EXIT
BODY

    run --separate-stderr bash "${BATS_TEST_TMPDIR}/server.sh" \
        <<< '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

    assert_success
    local server_stdout="${output}"
    local server_stderr="${stderr}"
    # The handler ran, and stdout holds the one response and no stray byte of it.
    assert [ -e "${marker_file}" ]
    assert_equal "${#lines[@]}" 1
    run jq -e '.id == 1 and has("result")' <<< "${server_stdout}"
    assert_success
    run printf '%s' "${server_stderr}"
    assert_output --partial 'handler stdout'
}

@test "an EXIT handler that fails leaves the exit status and the teardown intact" {
    export TMPDIR="${BATS_TEST_TMPDIR}/server-tmp"
    mkdir -p "${TMPDIR}"

    # The marker sits outside TMPDIR so the entry count below stays about the
    # server's own files. It is what makes this case fail on a library that
    # never runs the handler: `false` alone leaves nothing to observe.
    local marker_file="${BATS_TEST_TMPDIR}/failing-handler-ran"
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'touch "${marker_file}"; false' EXIT
BODY

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_success
    # The handler ran and its failure changed nothing: the exit status stays 0
    # and the teardown ran to its end — nothing the server created under
    # TMPDIR is left there.
    assert [ -e "${marker_file}" ]
    run _mcp_entry_count "${TMPDIR}"
    assert_output "0"
}

@test "a posix-mode server with no caller trap shuts down cleanly" {
    # Under `set -o posix` an unset EXIT trap is reported as `trap -- - EXIT`,
    # which the capture used to store and the teardown then ran as `eval "-"`.
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
set -o posix
BODY

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_success
    refute_output --partial 'command not found'
    run grep -q 'Chained caller EXIT trap failed' "${MCP_LOG_FILE}"
    assert_failure
}

@test "a signal a chained handler raises mid-pass still ends the server by that signal" {
    # The handler sends TERM to the server's own pid while the teardown pass
    # runs, so the signal is recorded during the pass and re-raised at its end.
    # `$$` stays the server's pid inside the handler's subshell.
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<'BODY'
trap 'kill -TERM $$' EXIT
BODY

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_equal "${status}" 143
}

@test "a chained handler that overruns the grace is killed and logged" {
    local marker_file="${BATS_TEST_TMPDIR}/late-marker"

    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'sleep 10; touch "${marker_file}"' EXIT
BODY

    local start=${SECONDS}
    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null
    local elapsed=$(( SECONDS - start ))

    assert_success
    # The handler is killed at the grace, so the marker its sleep guards is
    # never written and the overrun is logged.
    assert [ ! -e "${marker_file}" ]
    run grep -q 'did not finish within' "${MCP_LOG_FILE}"
    assert_success
    # A conservative outer bound, not a timing assertion: the handler sleeps
    # 10 seconds, so a shutdown that waited on it could not finish under this.
    assert [ "${elapsed}" -lt 8 ]
}

@test "a subshell-wrapped call runs the caller's EXIT handler exactly once" {
    local marker_file="${BATS_TEST_TMPDIR}/wrapped-marker"

    # The wrapped shape the README prescribes: the handler is installed in this
    # shell, and the call is isolated in a subshell. The subshell does not
    # capture the handler, so it runs once, from the wrapping shell's own exit.
    cat > "${BATS_TEST_TMPDIR}/server.sh" <<SERVER
#!/usr/bin/env bash
set -euo pipefail
export MCP_CONFIG_FILE="${BATS_TEST_TMPDIR}/config.json"
export MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
trap 'printf "handled\n" >> "${marker_file}"' EXIT
source "${CORE_SH}"
( run_mcp_server )
SERVER

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_success
    run grep -c '' "${marker_file}"
    assert_output "1"
}
