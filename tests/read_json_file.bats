#!/usr/bin/env bats
# bats file_tags=mcp-core,read-json-file
# Pins read_json_file(): one JSON object per file, and what its callers answer
# when the file is missing, empty, holds more than one document, is not JSON, or
# holds a single document that is not a JSON object.
# Requests are driven through process_request, the real entry point, so the
# suite covers the initialize and tools/list wiring on top of the function: an
# unreadable file is answered -32603 rather than as an empty configuration, and
# a readable one is answered with its contents. The last test drives
# run_mcp_server and pins that a non-object tools list leaves the server
# answering the next request.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"

setup() {
    mcp_test_env "${BATS_TEST_TMPDIR}/config.json" "${BATS_TEST_TMPDIR}/tools.json"
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
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

@test "process_request: initialize with a non-object config file returns -32603" {
    # One parseable document that is not an object parses fine, so the parse
    # gate alone would admit it; it is the object test that rejects it.
    printf '%s' '[1,2]' > "${MCP_CONFIG_FILE}"
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
    assert_failure 1
    assert_output ""
}

@test "read_json_file: a file with two JSON documents returns 1 and prints nothing" {
    printf '%s\n%s\n' '{"a": 1}' '{"b": 2}' > "${BATS_TEST_TMPDIR}/two.json"
    run read_json_file "${BATS_TEST_TMPDIR}/two.json"
    assert_failure 1
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

# --- read_json_file: a single document that is not a JSON object ---

# One parseable document of a non-object type is unusable to every caller:
# handle_initialize, handle_tools_list and _mcp_tool_schema pipe the output to
# jq and index it, and an index of an array, number or string errors. `null` and
# `false` are in this class even though they are valid JSON: an index of them
# yields `null` in place of the caller's key, so the configuration would read as
# an empty one.
_assert_non_object_rejected() {
    local payload="$1" name="$2"
    local file="${BATS_TEST_TMPDIR}/${name}.json"
    printf '%s' "$payload" > "$file"
    run read_json_file "$file"
    assert_failure 1
    assert_output ""
}

@test "read_json_file: a file whose only document is a number returns 1 and prints nothing" {
    _assert_non_object_rejected '5' 'number'
}

@test "read_json_file: a file whose only document is a string returns 1 and prints nothing" {
    _assert_non_object_rejected '"x"' 'string'
}

@test "read_json_file: a file whose only document is an array returns 1 and prints nothing" {
    _assert_non_object_rejected '[1,2]' 'array'
}

@test "read_json_file: a file whose only document is true returns 1 and prints nothing" {
    _assert_non_object_rejected 'true' 'true'
}

@test "read_json_file: a file whose only document is false returns 1 and prints nothing" {
    _assert_non_object_rejected 'false' 'false'
}

@test "read_json_file: a file whose only document is null returns 1 and prints nothing" {
    _assert_non_object_rejected 'null' 'null'
}

# --- run_mcp_server: a non-object tools list does not end the server ---

@test "run_mcp_server: a tools/list against a non-object tools file is answered -32603 and the server survives" {
    # A tools file holding `5`, a tools/list, then a ping. The server runs in a
    # fresh bash so that errexit governs its read loop the way it does in
    # production: invoked from this test's own shell, the capturing command
    # substitution would clear errexit. A server that died on the tools/list is
    # caught through the missing responses rather than the exit status, which
    # varies by bash version; the `|| true` keeps such a death's non-zero
    # pipeline status from aborting the test before those assertions report it.
    # run_mcp_server is run in a subshell because it replaces the process's
    # EXIT trap.
    printf '%s' '5' > "${MCP_TOOLS_LIST_FILE}"
    local out
    out=$(printf '%s\n%s\n' "$(_tools_list_request)" "$(mcp_ping_request 3)" \
        | bash -c 'source "$1"; ( run_mcp_server )' _ "${REPO_ROOT}/lib/mcpserver_core.sh" 2>/dev/null) || true

    # The tools/list is answered -32603 with a message naming the file it could
    # not read.
    run jq -e --arg path "${MCP_TOOLS_LIST_FILE}" \
        'select(.id == 2) | .jsonrpc == "2.0" and (.result == null) and .error.code == -32603 and (.error.message | contains($path))' <<< "$out"
    assert_success

    # The ping that followed is answered with a result: the server did not die
    # on the tools/list failure.
    run jq -e 'select(.id == 3) | .jsonrpc == "2.0" and .result == {}' <<< "$out"
    assert_success
}
