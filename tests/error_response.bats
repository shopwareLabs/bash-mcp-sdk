#!/usr/bin/env bats
# bats file_tags=mcp-core,error-response
# Tests create_error_response(): the JSON-RPC error envelope builder, and its
# optional fourth `data` parameter.
# Sources lib/mcpserver_core.sh directly. Consumers vendor that file verbatim, so
# this suite covers the function wherever it is vendored.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    MCP_CONFIG_FILE="/dev/null"
    MCP_TOOLS_LIST_FILE="/dev/null"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE
}

# --- create_error_response ---

@test "create_error_response: without data matches the pre-existing envelope, no data key" {
    run create_error_response 1 -32602 "Invalid params"
    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}'
}

@test "create_error_response: empty data argument omits the data key" {
    run create_error_response 1 -32602 "Invalid params" ""
    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}'
}

@test "create_error_response: object data is carried through as parsed JSON" {
    run create_error_response 1 -32602 "Invalid params" '{"param":"age"}'
    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":{"param":"age"}}}'

    run jq -e '.error.data.param == "age"' <<< "$output"
    assert_success
}

@test "create_error_response: non-object JSON data (a string literal) is carried through" {
    run create_error_response 1 -32602 "Invalid params" '"details"'
    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"details"}}'
}

@test "create_error_response: invalid JSON in data fails hard" {
    run create_error_response 1 -32602 "Invalid params" '{not json'
    assert_failure
}
