#!/usr/bin/env bats
# bats file_tags=mcp-core,error-response
# Tests create_error_response(): the JSON-RPC error envelope builder, and its
# optional fourth `data` parameter.
# Sources lib/mcpserver_core.sh directly. Consumers vendor that file verbatim, so
# this suite covers the function wherever it is vendored.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

setup() {
    mcp_test_env /dev/null /dev/null
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

# --- create_error_response ---

@test "create_error_response: without a data argument builds the envelope with no data key" {
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
}

@test "create_error_response: non-object JSON data (a string literal) is carried through" {
    run create_error_response 1 -32602 "Invalid params" '"details"'
    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"details"}}'
}

@test "create_error_response: invalid JSON in data fails with status 5 and nothing on stdout" {
    run -5 --separate-stderr create_error_response 1 -32602 "Invalid params" '{not json'
    assert_output ''
}
