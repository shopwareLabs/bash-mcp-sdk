#!/usr/bin/env bats
# bats file_tags=mcp-core,tool-declaration
# Pins that the tools list, not the shell, decides which tools a tools/call can
# reach. A tool is dispatched only when the list declares it exactly once with a
# non-null inputSchema and a shell function `tool_<name>` implements it:
#   - a sourced `tool_*` function the list does not declare answers -32601, and
#     so does a `tool_<name>_cancel` hook called as tool `<name>_cancel`;
#   - an entry with no inputSchema, a null one, or a name declared twice is an
#     isError result rather than an unvalidated dispatch;
#   - an executable on PATH answers neither as a tool nor as a cancel hook;
#   - an unreadable tools list stays an isError result, never -32601.
# Each "did not run" claim is proved by the marker file the tool would have
# written, not by the response text alone. Requests are driven through
# process_request, the real entry point.
# Before the change every case below except three failed: the dispatched,
# precedence and object-valued-list cases are guards of behavior the change
# keeps, and are labelled as such.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    MCP_CONFIG_FILE="/dev/null"
    MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT

    # shellcheck source=../lib/mcpserver_core.sh
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT
}

# A tools/call line for tool <name> with <arguments-json>, built with jq so the
# name and the arguments reach process_request as the JSON they name.
_call_request() {
    local name="$1"
    local arguments_json="$2"
    jq -nc --arg n "${name}" --argjson a "${arguments_json}" \
        '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $n, arguments: $a}}'
}

# Write an executable script named <name> into a directory placed first on
# PATH. Run, it creates <marker>.
_put_executable_on_path() {
    local name="$1"
    local marker="$2"
    local bin_dir="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin_dir}"
    printf '#!/usr/bin/env bash\n: > %q\n' "${marker}" > "${bin_dir}/${name}"
    chmod +x "${bin_dir}/${name}"
    PATH="${bin_dir}:${PATH}"
}

# Assert <response> is a -32601 `Tool not found: <name>` error for id 1.
_assert_tool_not_found() {
    local response="$1"
    local name="$2"
    run jq -e --arg m "Tool not found: ${name}" \
        '.id == 1 and .error.code == -32601 and .error.message == $m and (.result == null)' <<< "${response}"
    assert_success
}

# Assert <response> is an isError result for id 1 whose text is exactly <text>.
_assert_is_error_text() {
    local response="$1"
    local text="$2"
    run jq -e --arg t "${text}" \
        '.id == 1 and .result.isError == true and .result.content[0].text == $t and (.error == null)' <<< "${response}"
    assert_success
}

# --- declared and implemented ---

@test "process_request: a declared, implemented tool is dispatched (guard: unchanged behavior)" {
    printf '%s\n' '{"tools": [{"name": "x", "inputSchema": {"type": "object", "properties": {}}}]}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/x.ran"
    tool_x() { : > "${marker}"; printf 'x done\n'; }

    run process_request "$(_call_request x '{}')"

    assert_success
    run jq -e '.id == 1 and .result.isError == false and .result.content[0].text == "x done"' <<< "${output}"
    assert_success
    assert [ -e "${marker}" ]
}

# --- not declared ---

@test "process_request: a sourced tool function the list does not declare answers -32601 and does not run" {
    printf '%s\n' '{"tools": [{"name": "other", "inputSchema": {"type": "object"}}]}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/x.ran"
    tool_x() { : > "${marker}"; }

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_tool_not_found "${output}" x
    assert [ ! -e "${marker}" ]
}

@test "process_request: a cancel hook is not callable as a tool when only its tool is declared" {
    printf '%s\n' '{"tools": [{"name": "foo", "inputSchema": {"type": "object"}}]}' > "${MCP_TOOLS_LIST_FILE}"
    local hook_marker="${BATS_TEST_TMPDIR}/foo_cancel.ran"
    tool_foo() { printf 'foo done\n'; }
    tool_foo_cancel() { : > "${hook_marker}"; }

    run process_request "$(_call_request foo_cancel '{}')"

    assert_success
    _assert_tool_not_found "${output}" foo_cancel
    assert [ ! -e "${hook_marker}" ]
}

@test "process_request: an invalid tool name answers -32602 ahead of the declaration lookup (guard: unchanged behavior)" {
    printf '%s\n' '{"tools": []}' > "${MCP_TOOLS_LIST_FILE}"

    run process_request "$(_call_request a-b '{}')"

    assert_success
    run jq -e '.id == 1 and .error.code == -32602 and .error.message == "Invalid tool name: a-b"' <<< "${output}"
    assert_success
}

# --- declared without a usable schema ---

@test "process_request: a declared entry with no inputSchema is an isError result and does not run" {
    printf '%s\n' '{"tools": [{"name": "x", "description": "no schema"}]}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/x.ran"
    tool_x() { : > "${marker}"; }

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_is_error_text "${output}" "Cannot validate arguments for x: its entry in ${MCP_TOOLS_LIST_FILE} declares no inputSchema."
    assert [ ! -e "${marker}" ]
}

@test "process_request: a declared entry whose inputSchema is null is an isError result and does not run" {
    printf '%s\n' '{"tools": [{"name": "x", "inputSchema": null}]}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/x.ran"
    tool_x() { : > "${marker}"; }

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_is_error_text "${output}" "Cannot validate arguments for x: its entry in ${MCP_TOOLS_LIST_FILE} declares no inputSchema."
    assert [ ! -e "${marker}" ]
}

@test "process_request: a tool declared twice is an isError result naming the duplicate and does not run" {
    printf '%s\n' '{"tools": [{"name": "x", "inputSchema": {"type": "object"}}, {"name": "x", "inputSchema": {"type": "object", "required": ["n"]}}]}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/x.ran"
    tool_x() { : > "${marker}"; }

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_is_error_text "${output}" "Cannot validate arguments for x: the tool list at ${MCP_TOOLS_LIST_FILE} declares it more than once."
    assert [ ! -e "${marker}" ]
}

@test "process_request: an object-valued tools map declares its entries, and their schema is enforced (guard: unchanged behavior)" {
    # `.tools[]?` walks an object's values as well as an array's elements, so
    # the declaration check and the validator read this list the same way.
    printf '%s\n' '{"tools": {"k": {"name": "x", "inputSchema": {"type": "object", "required": ["n"]}}}}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/x.ran"
    tool_x() { : > "${marker}"; }

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_is_error_text "${output}" "Missing required parameter(s): n."
    assert [ ! -e "${marker}" ]
}

# --- an unreadable tools list ---

@test "process_request: a missing tools list is an isError result, not -32601, for a tool with no function" {
    # No tool_x is defined, so a lookup ordered after the function check would
    # answer -32601 and hide the unreadable list.
    rm -f -- "${MCP_TOOLS_LIST_FILE}"

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_is_error_text "${output}" "Cannot validate arguments for x: the tool list at ${MCP_TOOLS_LIST_FILE} is missing or does not hold one JSON object."
}

@test "process_request: a tools list holding a non-object element is an isError result, not -32601, for a tool with no function" {
    printf '%s\n' '{"tools": [1]}' > "${MCP_TOOLS_LIST_FILE}"

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_is_error_text "${output}" "Cannot validate arguments for x: the tool list at ${MCP_TOOLS_LIST_FILE} does not hold a usable tools list."
}

# --- executables on PATH ---

@test "process_request: a declared tool with no function answers -32601 even when a tool_ executable is on PATH" {
    printf '%s\n' '{"tools": [{"name": "x", "inputSchema": {"type": "object"}}]}' > "${MCP_TOOLS_LIST_FILE}"
    local marker="${BATS_TEST_TMPDIR}/path-tool.ran"
    _put_executable_on_path tool_x "${marker}"

    run process_request "$(_call_request x '{}')"

    assert_success
    _assert_tool_not_found "${output}" x
    assert [ ! -e "${marker}" ]
}

@test "_run_cancel_hook: a tool_<name>_cancel executable on PATH is not run as the hook" {
    local marker="${BATS_TEST_TMPDIR}/path-hook.ran"
    _put_executable_on_path tool_x_cancel "${marker}"

    run _run_cancel_hook x '{}'

    assert_success
    assert [ ! -e "${marker}" ]
}
