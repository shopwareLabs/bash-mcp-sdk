#!/usr/bin/env bats
# bats file_tags=mcp-core,tools-call-params
# Pins handle_tools_call's refusal of a `tools/call` whose params is not a JSON
# object, and the two behaviors that refusal buys:
#   - under `set -o posix`, where bash inherits errexit into command
#     substitutions, the server answers the refused call and the next request;
#   - a non-object params leaves nothing on the process's stderr, so no raw
#     `Cannot index ...` jq diagnostic bypasses `log`.
# It also pins the request members read by type rather than with jq's `//`:
# a present `null` or `false` params, a non-string `name`, and a non-string
# `method`, each answered rather than read as absent or as a name, and the
# name, method and jsonrpc values that `jq -r` and command substitution would
# alter.
# Requests are driven through process_request and, for the server-loop cases,
# through run_mcp_server, so the suite covers the real entry points. A case
# marked as a guard pins behavior the refusals leave in place.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    mcp_test_env "${BATS_TEST_TMPDIR}/config.json" "${BATS_TEST_TMPDIR}/tools.json"

    write_fixture_files '{"tools": []}'

    # shellcheck source=../lib/mcpserver_core.sh
    source "${CORE_SH}"
}

# A tools/call line with id 1 carrying <params-json> verbatim as the params
# value. It stays beside mcp_tools_call_request because that builder always sends
# an object params with a string name, and these cases send params that are not
# an object, or an object whose name is absent or not a string. The value is
# built with `jq -nc --argjson` so it reaches process_request as the JSON type it
# names.
_raw_params_request() {
    local params_json="$1"
    jq -nc --argjson p "${params_json}" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: $p}'
}

# --- process_request: a non-object params answers -32602 ---

# One gate tests the params type, so a number stands for every non-object type
# other than the `null` and `false` cases further down.

# Answer <request> through process_request and assert the reply is a -32602
# error envelope carrying the request's id and the params message. The response
# is parsed with jq rather than compared as a string. stderr is dropped so the
# response holds only the protocol line; what reaches stderr is the subject of
# a server-loop case further down.
_assert_non_object_params_rejected() {
    local request="$1"
    local response

    response=$(process_request "$request" 2>/dev/null)

    run jq -e '.jsonrpc == "2.0" and .id == 1 and .error.code == -32602 and (.result == null)' <<< "$response"
    assert_success
    run jq -r '.error.message' <<< "$response"
    assert_output "Invalid params: expected an object"
}

@test "process_request: a numeric params answers -32602 Invalid params" {
    _assert_non_object_params_rejected "$(_raw_params_request '5')"
}

# --- run_mcp_server: a non-object params under the real server loop ---

# The two-line session the server-loop cases below drive: a tools/call whose
# params is not an object, then a ping. The ping's response shows the server
# outlived the refused call.
_session_input() {
    printf '%s\n%s\n' "$(_raw_params_request '5')" "$(mcp_ping_request 2)"
}

@test "run_mcp_server: under set -o posix a non-object params is answered and the server survives to answer the next request" {
    local session_output

    # The server runs in a subshell, so run_mcp_server's EXIT trap lives and
    # dies there and no TAP line is lost to an EXIT-trap clobber.
    session_output=$(_session_input | bash -c 'set -o posix; source "$1"; ( run_mcp_server )' _ "${CORE_SH}" 2>/dev/null)

    # Both responses arrive. No exit status is asserted: it differs across bash
    # versions and is not what this pin is about.
    run jq -s -e '
        (map(select(.id == 1)) | length == 1 and .[0].error == {code: -32602, message: "Invalid params: expected an object"})
        and (map(select(.id == 2)) | length == 1 and .[0].result == {})
    ' <<< "$session_output"
    assert_success
}

@test "run_mcp_server: a non-object params is answered with nothing written to stderr" {
    local session_stderr
    local session_stdout="${BATS_TEST_TMPDIR}/session.out"

    # stderr is captured alone: the second redirection sends stdout to the
    # file after stderr has been duplicated onto the command substitution's
    # pipe, so only stderr is collected.
    session_stderr=$(_session_input | bash -c 'source "$1"; ( run_mcp_server )' _ "${CORE_SH}" 2>&1 >"${session_stdout}")

    # Both responses arrive, so the empty stderr below comes from a server that
    # handled the refused call rather than from one that never read it.
    run jq -s -e 'map(.id) == [1, 2] and .[0].error.code == -32602 and .[1].result == {}' "${session_stdout}"
    assert_success
    assert_equal "${session_stderr}" ""
}

# --- process_request: a present null or false params is not an absent one ---

# jq's `//` treats a present `null` or `false` as absent, so only a params read
# by key presence lets the object gate see them.

@test "process_request: a null params answers -32602 Invalid params" {
    _assert_non_object_params_rejected "$(_raw_params_request 'null')"
}

@test "process_request: a false params answers -32602 Invalid params" {
    _assert_non_object_params_rejected "$(_raw_params_request 'false')"
}

# --- process_request: a tools/call name that is not a string answers -32602 ---

# `jq -r` prints `null`, `false` and `true` as words the identifier regex
# accepts, so the name's type, not the regex, is what refuses a non-string name. A tool named `true` is
# declared and implemented here so that dispatch would be observable.
_assert_non_string_name_rejected() {
    local params_json="$1"
    local marker="${BATS_TEST_TMPDIR}/true.ran"
    write_fixture_files '{"tools": [{"name": "true", "inputSchema": {"type": "object"}}]}'
    tool_true() { : > "${marker}"; }

    run --separate-stderr process_request "$(_raw_params_request "${params_json}")"

    assert_success
    run jq -e '.id == 1 and .error.code == -32602 and .error.message == "Invalid params: name must be a string" and (.result == null)' <<< "${output}"
    assert_success
    assert [ ! -e "${marker}" ]
}

@test "process_request: a null tool name answers -32602 name must be a string" {
    _assert_non_string_name_rejected '{"name": null, "arguments": {}}'
}

@test "process_request: a false tool name answers -32602 name must be a string" {
    _assert_non_string_name_rejected '{"name": false, "arguments": {}}'
}

@test "process_request: a true tool name answers -32602 and does not run a tool declared as true" {
    _assert_non_string_name_rejected '{"name": true, "arguments": {}}'
}

@test "process_request: a numeric tool name answers -32602 name must be a string" {
    _assert_non_string_name_rejected '{"name": 5, "arguments": {}}'
}

@test "process_request: an absent tool name answers -32602 name must be a string" {
    _assert_non_string_name_rejected '{"arguments": {}}'
}

@test "process_request: the string tool name true is dispatched (guard: unchanged behavior)" {
    local marker="${BATS_TEST_TMPDIR}/true.ran"
    write_fixture_files '{"tools": [{"name": "true", "inputSchema": {"type": "object"}}]}'
    tool_true() { : > "${marker}"; printf 'ran true\n'; }

    run --separate-stderr process_request "$(mcp_tools_call_request 1 true '{}')"

    assert_success
    mcp_assert_tool_result "${output}" 1 false "ran true"
    assert [ -e "${marker}" ]
}

# --- process_request: a method that is not a string ---

# JSON-RPC 2.0 §4 makes `method` a String, and its §7 examples answer
# `"method": 1` with -32600 Invalid Request rather than -32601 Method not found.

# A request line with id 1 whose `method` member is set from <method-json>, or
# left out when <method-json> is empty.
_method_request() {
    local method_json="$1"
    if [[ -z "${method_json}" ]]; then
        jq -nc '{jsonrpc: "2.0", id: 1}'
    else
        jq -nc --argjson m "${method_json}" '{jsonrpc: "2.0", id: 1, method: $m}'
    fi
}

_assert_non_string_method_rejected() {
    local request="$1"

    run --separate-stderr process_request "${request}"

    assert_success
    run jq -e '.jsonrpc == "2.0" and .id == 1 and .error.code == -32600 and .error.message == "Invalid Request: method must be a string" and (.result == null)' <<< "${output}"
    assert_success
}

@test "process_request: a null method answers -32600 method must be a string" {
    _assert_non_string_method_rejected "$(_method_request 'null')"
}

@test "process_request: a false method answers -32600 method must be a string" {
    _assert_non_string_method_rejected "$(_method_request 'false')"
}

@test "process_request: a numeric method answers -32600 method must be a string" {
    _assert_non_string_method_rejected "$(_method_request '5')"
}

@test "process_request: an absent method answers -32600 method must be a string" {
    _assert_non_string_method_rejected "$(_method_request '')"
}

@test "process_request: a notification with a numeric method is logged as dropped and gets no response" {
    run --separate-stderr process_request "$(jq -nc '{jsonrpc: "2.0", method: 5}')"

    assert_success
    assert_output ""
    run grep -c "Notification method is not a string; dropped" "${MCP_LOG_FILE}"
    assert_output "1"
}

# --- process_request: a name, method or jsonrpc that does not survive capture ---

# A command substitution strips a trailing newline and bash drops a NUL, so a
# name `"echo\n"` or a method `"ping\u0000"` read through `$(... | jq -r ...)`
# would match `tool_echo` or ping, and `jq -r` prints the number 2.0 as `2.0`.

@test "process_request: a tool name with a trailing newline or a NUL answers -32602 with the name JSON-encoded and does not run the tool" {
    local marker="${BATS_TEST_TMPDIR}/echo.ran"
    write_fixture_files '{"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]}'
    tool_echo() { : > "${marker}"; }
    local name request
    # Each name is held as JSON text, because a bash variable cannot hold a NUL.
    for name in '"echo\n"' '"\u0000echo"'; do
        request=$(jq -nc --argjson n "${name}" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $n, arguments: {}}}')

        run --separate-stderr process_request "${request}"

        assert_success
        run jq -e --argjson n "${name}" '.id == 1 and .error.code == -32602 and .error.message == "Invalid tool name: \($n | tojson)" and (.result == null)' <<< "${output}"
        assert_success
        assert [ ! -e "${marker}" ]
    done
}

@test "process_request: a method with a NUL or a trailing newline answers -32601 with the method JSON-encoded and is not answered as ping" {
    local method request
    for method in '"ping\u0000"' '"ping\n"'; do
        request=$(jq -nc --argjson m "${method}" '{jsonrpc: "2.0", id: 1, method: $m}')

        run --separate-stderr process_request "${request}"

        assert_success
        run jq -e --argjson m "${method}" '.id == 1 and .error.code == -32601 and .error.message == "Method not found: \($m | tojson)" and (.result == null)' <<< "${output}"
        assert_success
    done
}

@test "process_request: a jsonrpc of the number 2.0 or of \"2.0\\n\" answers -32600 jsonrpc must be 2.0" {
    local request
    for request in \
        '{"jsonrpc": 2.0, "id": 1, "method": "ping"}' \
        '{"jsonrpc": "2.0\n", "id": 1, "method": "ping"}'; do
        run --separate-stderr process_request "${request}"

        assert_success
        run jq -e '.id == 1 and .error.code == -32600 and .error.message == "Invalid Request: jsonrpc must be 2.0" and (.result == null)' <<< "${output}"
        assert_success
    done
}
