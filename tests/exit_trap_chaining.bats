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

# Write a throwaway server at <path>, taking the script's own lines from stdin.
# The preamble names the MCP_* paths setup() created and the body follows it, so
# a case varies only in what it installs ahead of the call.
_write_server() {
    local path="$1"
    local body
    body="$(cat)"

    cat > "${path}" <<SERVER
#!/usr/bin/env bash
set -euo pipefail
export MCP_CONFIG_FILE="${BATS_TEST_TMPDIR}/config.json"
export MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
${body}
source "${CORE_SH}"
run_mcp_server
SERVER
}

# Print the number of entries directly under <dir>. Every temp file a server
# creates lives there — the shutdown flag, the in-flight record, the partial-line
# handoff, the lifeline directory and the captured handler — and its teardown
# releases them all, so the count is how far a teardown got.
_mcp_entry_count() {
    local dir="$1"
    local entries=""
    shopt -s nullglob
    entries=("${dir}"/*)
    shopt -u nullglob
    printf '%s' "${#entries[@]}"
}

@test "a caller's EXIT handler runs when the server exits on a closed stdin" {
    local state_file="${BATS_TEST_TMPDIR}/handler-state"
    printf 'state\n' > "${state_file}"

    _write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'rm -f -- "${state_file}"' EXIT
BODY

    run bash "${BATS_TEST_TMPDIR}/server.sh" < /dev/null

    assert_success
    assert [ ! -e "${state_file}" ]
}

@test "a caller's EXIT handler runs when a signal tears the server down" {
    local marker_file="${BATS_TEST_TMPDIR}/handler-marker"

    _write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
trap 'printf "chained\n" > "${marker_file}"' EXIT
BODY
    chmod +x "${BATS_TEST_TMPDIR}/server.sh"

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

@test "both commands of a compound EXIT handler run, each exactly once" {
    local first_marker="${BATS_TEST_TMPDIR}/first-marker"
    local second_marker="${BATS_TEST_TMPDIR}/second-marker"

    _write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
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

    _write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
handler() {
    printf 'handler stdout\n'
    printf 'ran\n' > "${marker_file}"
}
trap 'handler' EXIT
BODY
    chmod +x "${BATS_TEST_TMPDIR}/server.sh"

    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"
    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

    run mcp_wait_for_response 1
    assert_success

    mcp_close_stdin
    wait "${MCP_SERVER_PID}" 2>/dev/null || true

    # The handler ran, and the JSON-RPC capture holds the one response and no
    # stray byte of it.
    assert [ -e "${marker_file}" ]
    run grep -c '' "${MCP_SERVER_OUT}"
    assert_output "1"
    local response
    response="$(<"${MCP_SERVER_OUT}")"
    run jq -e '.id == 1 and has("result")' <<< "${response}"
    assert_success
    run grep -q 'handler stdout' "${MCP_SERVER_ERR}"
    assert_success
}

@test "an EXIT handler that fails leaves the exit status and the teardown intact" {
    export TMPDIR="${BATS_TEST_TMPDIR}/server-tmp"
    mkdir -p "${TMPDIR}"

    # The marker sits outside TMPDIR so the entry count below stays about the
    # server's own files. It is what makes this case fail on a library that
    # never runs the handler: `false` alone leaves nothing to observe.
    local marker_file="${BATS_TEST_TMPDIR}/failing-handler-ran"
    _write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
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
