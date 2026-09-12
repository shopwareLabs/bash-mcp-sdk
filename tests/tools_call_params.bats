#!/usr/bin/env bats
# bats file_tags=mcp-core,tools-call-params
# Pins handle_tools_call's refusal of a `tools/call` whose params is not a JSON
# object, and the two behaviors that refusal buys:
#   - the extraction of `.name` and `.arguments` only ever sees an object, so
#     under `set -o posix` — where bash inherits errexit into command
#     substitutions — a failed extraction cannot end the server;
#   - jq's raw `Cannot index ...` diagnostics for a non-object params no longer
#     reach the process's stderr, unrouted through `log`.
# Requests are driven through process_request and, for the server-loop cases,
# through run_mcp_server, so the suite covers the real entry points.
# Pre-change, `params: 5`, `"x"` and `[1,2]` answered `-32602 Invalid tool name: `
# and under POSIX mode the server died without answering the request that
# followed; every case below fails against the pre-change library.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    MCP_CONFIG_FILE="/dev/null"
    MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT

    printf '%s\n' '{"tools": []}' > "${MCP_TOOLS_LIST_FILE}"

    # shellcheck source=../lib/mcpserver_core.sh
    source "${CORE_SH}"
}

teardown() {
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE PROJECT_ROOT
}

# A tools/call line carrying <params-json> verbatim as the params value. The
# value is built with `jq -nc --argjson` so a non-object params reaches
# process_request as the JSON type it names.
_call_request() {
    local params_json="$1"
    jq -nc --argjson p "${params_json}" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: $p}'
}

_ping_request() {
    jq -nc '{jsonrpc: "2.0", id: 2, method: "ping", params: {}}'
}

# --- process_request: a non-object params answers -32602 ---

# Answer <request> through process_request and assert the reply is a -32602
# error envelope carrying the request's id and the params message. The response
# is parsed with jq rather than compared as a string. stderr is dropped so the
# response holds only the protocol line; the raw jq diagnostics a non-object
# params used to produce are the subject of the server-loop case further down.
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
    _assert_non_object_params_rejected "$(_call_request '5')"
}

@test "process_request: a string params answers -32602 Invalid params" {
    _assert_non_object_params_rejected "$(_call_request '"x"')"
}

@test "process_request: an array params answers -32602 Invalid params" {
    _assert_non_object_params_rejected "$(_call_request '[1,2]')"
}

# --- run_mcp_server: the POSIX-mode crash regression ---

# The two-line session the server-loop cases below drive: a tools/call whose
# params is not an object, then a ping. Both responses must arrive; a session
# that answers only the first is the pre-change failure, where the failed
# `.name` extraction ended the server under POSIX-mode errexit inheritance
# before the ping was read.
_session_input() {
    printf '%s\n%s\n' "$(_call_request '5')" "$(_ping_request)"
}

@test "run_mcp_server: under set -o posix a non-object params is answered and the server survives to answer the next request" {
    local session_output

    # The server runs in a subshell, so run_mcp_server's EXIT trap lives and
    # dies there and no TAP line is lost to an EXIT-trap clobber.
    session_output=$(_session_input | bash -c "set -o posix; source '${CORE_SH}'; ( run_mcp_server )" 2>/dev/null)

    # Both responses arrive. No exit status is asserted: it differs across bash
    # versions and is not what this pin is about.
    run jq -s -e '
        (map(select(.id == 1)) | length == 1 and .[0].error.code == -32602)
        and (map(select(.id == 2)) | length == 1 and .[0].result == {})
    ' <<< "$session_output"
    assert_success
}

@test "run_mcp_server: a non-object params leaves no jq diagnostic on stderr" {
    local session_stderr

    # stderr is captured alone: the second redirection sends stdout to
    # /dev/null after stderr has been duplicated onto the command substitution's
    # pipe, so only stderr is collected.
    session_stderr=$(_session_input | bash -c "source '${CORE_SH}'; ( run_mcp_server )" 2>&1 >/dev/null)

    run printf '%s' "${session_stderr}"
    refute_output --partial "Cannot index"
}
