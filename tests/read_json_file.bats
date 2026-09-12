#!/usr/bin/env bats
# bats file_tags=mcp-core,read-json-file
# Pins read_json_file(): one JSON document per file, and what its callers answer
# when the file is missing, empty, holds more than one document, or is not JSON.
# Requests are driven through process_request, the real entry point, so the
# suite covers the initialize and tools/list wiring on top of the function.
# Only the missing-file cases below were answered as a normal result before the
# change: a missing config file yielded the default initialize result and a
# missing tools list yielded {"tools": []}, which is the defect this suite
# exists to catch. The malformed, empty, and multi-document cases were not
# answered at all: raw bytes reached the handlers and errored instead of
# yielding a protocol error. The two success cases are guards, not regression
# cases: they hold before and after, and pin that the change is scoped to the
# failure path.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    MCP_CONFIG_FILE="${BATS_TEST_TMPDIR}/config.json"
    MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE
}

_initialize_request() {
    jq -nc '{jsonrpc: "2.0", id: 1, method: "initialize", params: {}}'
}

_tools_list_request() {
    jq -nc '{jsonrpc: "2.0", id: 2, method: "tools/list", params: {}}'
}

# Answer <request> through process_request and assert the reply is a -32603
# error whose message names <path>. assert_success pins that the dispatch
# survived the unreadable file: a handler that hit errexit would produce no
# response at all, which is a different failure from the one under test.
_assert_configuration_error() {
    local request="$1"
    local path="$2"
    local response

    run process_request "$request"
    assert_success
    response="$output"

    run jq -e '.jsonrpc == "2.0" and .error.code == -32603 and (.result == null)' <<< "$response"
    assert_success
    run jq -r '.error.message' <<< "$response"
    assert_output --partial "$path"
}

# --- process_request: initialize against an unreadable configuration ---

@test "process_request: initialize with a missing config file returns -32603" {
    _assert_configuration_error "$(_initialize_request)" "${MCP_CONFIG_FILE}"
}

@test "process_request: initialize with a malformed config file returns -32603" {
    printf '%s' '{ not json' > "${MCP_CONFIG_FILE}"
    _assert_configuration_error "$(_initialize_request)" "${MCP_CONFIG_FILE}"
}

@test "process_request: initialize with an empty config file returns -32603" {
    : > "${MCP_CONFIG_FILE}"
    _assert_configuration_error "$(_initialize_request)" "${MCP_CONFIG_FILE}"
}

@test "process_request: initialize with a two-document config file returns -32603" {
    printf '%s\n%s\n' '{"protocolVersion": "1.0"}' '{"protocolVersion": "2.0"}' > "${MCP_CONFIG_FILE}"
    _assert_configuration_error "$(_initialize_request)" "${MCP_CONFIG_FILE}"
}

@test "process_request: initialize with a valid config file returns its values" {
    cat > "${MCP_CONFIG_FILE}" <<'JSON'
{"protocolVersion": "2025-06-18", "serverInfo": {"name": "probe", "version": "9.9.9"}}
JSON
    run process_request "$(_initialize_request)"
    assert_success
    run jq -e '.result.protocolVersion == "2025-06-18" and .result.serverInfo.name == "probe"' <<< "$output"
    assert_success
}

# --- process_request: tools/list against an unreadable tools list ---

@test "process_request: tools/list with a missing tools list file returns -32603" {
    _assert_configuration_error "$(_tools_list_request)" "${MCP_TOOLS_LIST_FILE}"
}

@test "process_request: tools/list with a malformed tools list file returns -32603" {
    printf '%s' '{"tools": [ broken' > "${MCP_TOOLS_LIST_FILE}"
    _assert_configuration_error "$(_tools_list_request)" "${MCP_TOOLS_LIST_FILE}"
}

@test "process_request: tools/list with an empty tools list file returns -32603" {
    : > "${MCP_TOOLS_LIST_FILE}"
    _assert_configuration_error "$(_tools_list_request)" "${MCP_TOOLS_LIST_FILE}"
}

@test "process_request: tools/list with a two-document tools list file returns -32603" {
    printf '%s\n%s\n' '{"tools": []}' '{"tools": []}' > "${MCP_TOOLS_LIST_FILE}"
    _assert_configuration_error "$(_tools_list_request)" "${MCP_TOOLS_LIST_FILE}"
}

@test "process_request: tools/list with a valid tools file returns the tools" {
    cat > "${MCP_TOOLS_LIST_FILE}" <<'JSON'
{"tools": [{"name": "greet", "description": "Say hello."}]}
JSON
    run process_request "$(_tools_list_request)"
    assert_success
    run jq -e '.result.tools[0].name == "greet"' <<< "$output"
    assert_success
}

# --- read_json_file: the function's own stdout and status contract ---

@test "read_json_file: a missing file returns 1 and prints nothing" {
    run read_json_file "${BATS_TEST_TMPDIR}/absent.json"
    assert_failure
    assert_output ""
}

@test "read_json_file: a file with two JSON documents returns 1 and prints nothing" {
    printf '%s\n%s\n' '{"a": 1}' '{"b": 2}' > "${BATS_TEST_TMPDIR}/two.json"
    run read_json_file "${BATS_TEST_TMPDIR}/two.json"
    assert_failure
    assert_output ""
}

@test "read_json_file: a valid file prints the parsed document in compact form" {
    cat > "${BATS_TEST_TMPDIR}/one.json" <<'JSON'
{
  "a": 1,
  "b": 2
}
JSON
    run read_json_file "${BATS_TEST_TMPDIR}/one.json"
    assert_success
    assert_output '{"a":1,"b":2}'
}

@test "read_json_file: a file whose only document is null succeeds and prints null" {
    # `null` is a parseable document. A `jq -e`-based parse gate would reject
    # it, since `jq -e` exits 1 on a null result; this pins that the gate does
    # not do that.
    printf '%s' 'null' > "${BATS_TEST_TMPDIR}/null.json"
    run read_json_file "${BATS_TEST_TMPDIR}/null.json"
    assert_success
    assert_output 'null'
}

@test "read_json_file: a file whose only document is false succeeds and prints false" {
    # Same guard as `null`: `jq -e` exits 1 on `false` too.
    printf '%s' 'false' > "${BATS_TEST_TMPDIR}/false.json"
    run read_json_file "${BATS_TEST_TMPDIR}/false.json"
    assert_success
    assert_output 'false'
}
