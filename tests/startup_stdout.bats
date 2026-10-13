#!/usr/bin/env bats
# bats file_tags=mcp-core,startup-stdout
# Pins that only responses reach the JSON-RPC stream once a server has sourced
# the core: what the server script writes to stdout between the `source` line
# and run_mcp_server goes to stderr, a second source in the same shell keeps
# responses on the real stdout, and a tool cannot write to the descriptor the
# responses travel on.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    cat > "${BATS_TEST_TMPDIR}/config.json" <<'JSON'
{}
JSON

    cat > "${BATS_TEST_TMPDIR}/tools.json" <<'JSON'
{"tools": [{"name": "protocol_write", "description": "writes to the protocol descriptor", "inputSchema": {"type": "object"}}]}
JSON

    mcp_test_env "${BATS_TEST_TMPDIR}/config.json" "${BATS_TEST_TMPDIR}/tools.json"
}

teardown() {
    mcp_stop_server
}

@test "a line a server script echoes before run_mcp_server goes to stderr, not the protocol stream" {
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<'BODY'
echo stray
BODY
    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"

    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    run mcp_wait_for_response 1
    assert_success
    mcp_close_stdin
    wait "${MCP_SERVER_PID}"

    # The stream holds the one response and nothing ahead of it: jq fails on a
    # line that is not JSON.
    run jq -c '.id' "${MCP_SERVER_OUT}"
    assert_success
    assert_output "1"
    run grep -x 'stray' "${MCP_SERVER_ERR}"
    assert_success
}

@test "a tool cannot write to the descriptor that carries the responses" {
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<'BODY'
tool_protocol_write() {
    if printf 'x' >&"${_MCP_PROTOCOL_FD}"; then
        printf 'write succeeded\n'
    else
        printf 'write failed\n'
    fi
}
BODY
    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"

    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    mcp_send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"protocol_write","arguments":{}}}'
    run mcp_wait_for_response 2
    assert_success
    local response="${output}"
    mcp_close_stdin
    wait "${MCP_SERVER_PID}"

    run jq -r '.result.content[0].text | split("\n") | map(select(. != "")) | last' <<< "${response}"
    assert_success
    assert_output "write failed"
    # Every line of the stream is one whole response, in request order.
    run jq -c '.id' "${MCP_SERVER_OUT}"
    assert_success
    assert_output $'1\n2'
}

@test "sourcing the core sends a later write to stdout to stderr instead" {
    # shellcheck disable=SC2016 # $1 is the inner shell's argument, expanded there.
    run --separate-stderr bash -c 'source "$1"; echo hi' bash "${CORE_SH}"

    assert_success
    assert_output ''
    assert_equal "${stderr}" 'hi'
}

@test "a second source in the same shell keeps responses on the real stdout" {
    write_server "${BATS_TEST_TMPDIR}/server.sh" <<BODY
source "${CORE_SH}"
echo stray
BODY
    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"

    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    run mcp_wait_for_response 1
    assert_success
    mcp_close_stdin
    wait "${MCP_SERVER_PID}"

    run jq -c '.id' "${MCP_SERVER_OUT}"
    assert_success
    assert_output "1"
    run grep -x 'stray' "${MCP_SERVER_ERR}"
    assert_success
}
