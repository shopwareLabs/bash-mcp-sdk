#!/usr/bin/env bats
# bats file_tags=mcp-client,client-harness
# Validates tests/test_helper/mcp_client.bash against the server's current
# behavior: start a fixture server, drive one request at a time over the FIFO,
# wait for its response, assert silence for an id that was never sent, and tear
# the server down. Cancellation behavior is covered by cancellation.bats, which
# uses these helpers to drive the in-flight request stream.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"

CANCELLATION_SERVER="${REPO_ROOT}/tests/fixtures/cancellation_server.sh"

setup() {
    # Keep the fixture's log out of mktemp's directory and inside the test's.
    export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    mcp_start_server "${CANCELLATION_SERVER}"
}

teardown() {
    mcp_stop_server
    unset MCP_LOG_FILE
}

@test "mcp_start_server: the server answers initialize with the request id" {
    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

    run mcp_wait_for_response 1
    assert_success
    local response="${output}"

    run jq -e '.id == 1 and has("result")' <<< "${response}"
    assert_success
}

@test "mcp_send + mcp_wait_for_response: tools/call of fast returns its text" {
    mcp_send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fast","arguments":{}}}'

    run mcp_wait_for_response 2
    assert_success
    local response="${output}"

    run jq -r '.result.content[0].text' <<< "${response}"
    assert_success
    assert_output "fast done"

    run jq -e '.result.isError == false' <<< "${response}"
    assert_success
}

@test "mcp_assert_no_response: passes for an id the client never sent" {
    run mcp_assert_no_response 99 0.5
    assert_success
    [[ -z "${output}" ]]
}

@test "mcp_stop_server: leaves no server process running and removes its temp dir" {
    local pid="${MCP_SERVER_PID}"
    local tmpdir="${MCP_CLIENT_TMPDIR}"

    mcp_stop_server

    run kill -0 "${pid}"
    assert_failure
    [[ ! -d "${tmpdir}" ]]
}

@test "mcp_send: a payload with single quotes and unicode arrives intact" {
    # The invalid tool name is deliberate: the server echoes it back verbatim in
    # its error message, so the assertion covers the payload's characters and
    # not just that some well-formed request arrived.
    local payload="{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"O'Brien ✓ ünïcödé\",\"arguments\":{}}}"

    mcp_send "${payload}"

    run mcp_wait_for_response 5
    assert_success
    local response="${output}"

    run jq -r '.error.message' <<< "${response}"
    assert_success
    assert_output "Invalid tool name: O'Brien ✓ ünïcödé"
}
