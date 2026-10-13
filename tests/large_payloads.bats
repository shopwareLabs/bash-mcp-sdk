#!/usr/bin/env bats
# bats file_tags=mcp-core,large-payloads
# Pins that the SDK answers requests whose data is past the OS argument limit
# (128 KiB per argument on Linux, 1 MiB for argv and environment together on
# macOS), where handing that data to jq as an argument fails the exec with
# E2BIG:
#   - a tool's 1,100,000-byte output comes back byte-for-byte as the result
#     text, then a ping is answered: on the success branch (plain and under
#     `inherit_errexit`), on the failure branch behind its `Error executing`
#     prefix, and when the before-tool hook ends the call;
#   - 1.1 MB of multibyte output whose characters straddle byte 4096 comes back
#     byte-for-byte;
#   - 1.1 MB arguments reach the tool byte-for-byte when the schema accepts
#     them, and come back as the exact validation text when it rejects them;
#   - a tools list over 1.1 MB is answered whole on tools/list, and a tools/call
#     validated against its oversized schema is answered;
#   - a server configuration over 1.1 MB is answered whole on initialize;
#   - create_response and create_error_response, called directly, build a
#     1.1 MB result and 1.1 MB data exactly, and fail with status 5 and nothing
#     on stdout for a result or data that is not exactly one JSON document;
#   - validate_tool_arguments, called directly, rejects arguments that hold two
#     JSON documents as not evaluable, rather than validating the first.
# Protocol cases drive a throwaway server over the FIFO client harness. Builder
# cases source the SDK into the test shell. Payloads are written to files and
# handed to jq with --rawfile, never as arguments.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

# Above both platform limits.
PAYLOAD_BYTES=1100000

setup() {
    mcp_test_env "${BATS_TEST_TMPDIR}/config.json" "${BATS_TEST_TMPDIR}/tools.json"
    export PAYLOAD_FILE="${BATS_TEST_TMPDIR}/payload.txt"
    export MULTIBYTE_FILE="${BATS_TEST_TMPDIR}/multibyte.txt"
    export ARGS_FILE="${BATS_TEST_TMPDIR}/received-arguments.json"

    # No trailing newline and no NUL: the SDK reads a tool's output with
    # `$(<file)`, which drops both, so the result text is these bytes exactly.
    head -c "${PAYLOAD_BYTES}" /dev/zero | tr '\0' 'x' > "${PAYLOAD_FILE}"

    printf '%s\n' '{}' > "${BATS_TEST_TMPDIR}/config.json"
    printf '%s\n' '{
        "tools": [
            {"name": "big_output", "inputSchema": {"type": "object"}},
            {"name": "big_failure", "inputSchema": {"type": "object"}},
            {"name": "multibyte", "inputSchema": {"type": "object"}},
            {"name": "hook_exits", "inputSchema": {"type": "object"}},
            {"name": "record_args", "inputSchema": {
                "type": "object",
                "properties": {"text": {"type": "string", "pattern": "^a*$"}},
                "additionalProperties": false
            }}
        ]
    }' > "${BATS_TEST_TMPDIR}/tools.json"

    SERVER="${BATS_TEST_TMPDIR}/server.sh"
}

teardown() {
    mcp_stop_server
}

# Write the suite's server, its tools followed by <extra> (shell lines, may be
# empty), then start it.
_start_server() {
    local extra="$1"
    {
        cat <<'BODY'
tool_big_output() { cat "${PAYLOAD_FILE}"; }
tool_big_failure() { cat "${PAYLOAD_FILE}"; return 3; }
tool_multibyte() { cat "${MULTIBYTE_FILE}"; }
tool_hook_exits() { printf 'tool ran'; }
tool_record_args() { printf '%s' "$1" > "${ARGS_FILE}"; printf 'recorded'; }
mcp_before_tool_call() {
    if [[ "$1" == hook_exits ]]; then
        cat "${PAYLOAD_FILE}"
        exit 1
    fi
    return 0
}
BODY
        printf '%s\n' "${extra}"
    } | write_server "${SERVER}"
    mcp_start_server "${SERVER}"
}

# Send a ping with <id> and assert it is answered.
_assert_ping_answered() {
    local id="$1"
    mcp_send "$(mcp_ping_request "${id}")"
    run mcp_wait_for_response "${id}" 10
    assert_equal "${status}" 0
}

# Send the tools/call for <tool> with id 1, wait for its response and assert
# its text is <expected-file> with isError <is_error>, then that a ping is
# answered.
_assert_call_text_then_ping() {
    local tool="$1"
    local is_error="$2"
    local expected_file="$3"
    mcp_send "$(mcp_tools_call_request 1 "${tool}" '{}')"
    run mcp_wait_for_response 1 30
    assert_equal "${status}" 0
    mcp_assert_tool_result_file "${output}" 1 "${is_error}" "${expected_file}"
    _assert_ping_answered 2
}

# Source the SDK into the test shell, for the cases that call its envelope
# builders directly. The MCP_* variables are already exported by setup().
_source_sdk() {
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

@test "a tool's 1.1 MB output comes back byte-for-byte, then a ping is answered" {
    _start_server ''
    _assert_call_text_then_ping big_output false "${PAYLOAD_FILE}"
}

@test "under inherit_errexit a tool's 1.1 MB output comes back byte-for-byte, then a ping is answered" {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        skip "inherit_errexit needs bash 4.4; this is ${BASH_VERSION}"
    fi
    _start_server 'shopt -s inherit_errexit'
    _assert_call_text_then_ping big_output false "${PAYLOAD_FILE}"
}

@test "a failing tool's 1.1 MB output comes back byte-for-byte behind the error prefix, then a ping is answered" {
    _start_server ''
    local expected="${BATS_TEST_TMPDIR}/expected.txt"
    { printf 'Error executing big_failure: '; cat "${PAYLOAD_FILE}"; } > "${expected}"
    _assert_call_text_then_ping big_failure true "${expected}"
}

@test "a before-tool hook that ends the call with 1.1 MB of output has it come back byte-for-byte, then a ping is answered" {
    _start_server ''
    local expected="${BATS_TEST_TMPDIR}/expected.txt"
    { printf 'mcp_before_tool_call ended the call instead of returning; tool hook_exits did not run.\n'; cat "${PAYLOAD_FILE}"; } > "${expected}"
    _assert_call_text_then_ping hook_exits true "${expected}"
}

@test "1.1 MB of multibyte output with a character straddling byte 4096 comes back byte-for-byte" {
    # Two single-byte characters, then 9-byte units of 2-, 3- and 4-byte
    # characters, 1,125,002 bytes in all: the 4-byte character at zero-based
    # offsets 4093-4096 straddles the first 4096-byte chunk, and later chunk
    # boundaries fall inside characters too.
    jq -n -j '"ab" + ([range(0; 125000) | "ü€😱"] | add)' > "${MULTIBYTE_FILE}"
    _start_server ''
    _assert_call_text_then_ping multibyte false "${MULTIBYTE_FILE}"
}

@test "1.1 MB arguments that the schema accepts reach the tool byte-for-byte" {
    _start_server ''
    local text_file="${BATS_TEST_TMPDIR}/text.txt"
    head -c "${PAYLOAD_BYTES}" /dev/zero | tr '\0' 'a' > "${text_file}"
    local request
    request=$(jq -n -c --rawfile text "${text_file}" \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_args","arguments":{"text":$text}}}')

    mcp_send "${request}"
    run mcp_wait_for_response 1 30
    assert_equal "${status}" 0
    mcp_assert_tool_result "${output}" 1 false "recorded"

    jq -j '.text' "${ARGS_FILE}" > "${BATS_TEST_TMPDIR}/received.txt"
    run cmp "${BATS_TEST_TMPDIR}/received.txt" "${text_file}"
    assert_equal "${status}" 0
}

@test "1.1 MB arguments that the schema rejects come back as the exact validation text" {
    _start_server ''
    local text_file="${BATS_TEST_TMPDIR}/text.txt"
    { head -c "${PAYLOAD_BYTES}" /dev/zero | tr '\0' 'a'; printf 'b'; } > "${text_file}"
    local request
    request=$(jq -n -c --rawfile text "${text_file}" \
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_args","arguments":{"text":$text}}}')
    local expected="${BATS_TEST_TMPDIR}/expected.txt"
    jq -n -j --rawfile text "${text_file}" \
        '"Invalid value(s): text=" + ($text | tojson) + " does not match pattern ^a*$."' > "${expected}"

    mcp_send "${request}"
    run mcp_wait_for_response 1 30
    assert_equal "${status}" 0
    mcp_assert_tool_result_file "${output}" 1 true "${expected}"
}

@test "a tools list over 1.1 MB is answered whole on tools/list" {
    # The size sits in record_args' inputSchema.
    jq -c --rawfile description "${PAYLOAD_FILE}" \
        '(.tools[] | select(.name == "record_args") | .inputSchema.description) = $description' \
        "${BATS_TEST_TMPDIR}/tools.json" > "${BATS_TEST_TMPDIR}/tools.big.json"
    mv "${BATS_TEST_TMPDIR}/tools.big.json" "${BATS_TEST_TMPDIR}/tools.json"
    _start_server ''

    mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
    run mcp_wait_for_response 1 30
    assert_equal "${status}" 0
    run jq -e --slurpfile list "${BATS_TEST_TMPDIR}/tools.json" '.result.tools == $list[0].tools' <<< "${output}"
    assert_equal "${status}" 0
}

@test "a tools/call validated against a 1.1 MB schema is answered with the tool's result" {
    jq -c --rawfile description "${PAYLOAD_FILE}" \
        '(.tools[] | select(.name == "record_args") | .inputSchema.description) = $description' \
        "${BATS_TEST_TMPDIR}/tools.json" > "${BATS_TEST_TMPDIR}/tools.big.json"
    mv "${BATS_TEST_TMPDIR}/tools.big.json" "${BATS_TEST_TMPDIR}/tools.json"
    _start_server ''

    mcp_send "$(mcp_tools_call_request 1 record_args '{"text":"aaa"}')"
    run mcp_wait_for_response 1 30
    assert_equal "${status}" 0
    mcp_assert_tool_result "${output}" 1 false "recorded"
}

@test "a server configuration over 1.1 MB is answered whole on initialize" {
    jq -n -c --rawfile name "${PAYLOAD_FILE}" '{"serverInfo": {"name": $name, "version": "1.0.0"}}' \
        > "${BATS_TEST_TMPDIR}/config.json"
    _start_server ''

    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    run mcp_wait_for_response 1 30
    assert_equal "${status}" 0
    run jq -e --slurpfile config "${BATS_TEST_TMPDIR}/config.json" '.result.serverInfo == $config[0].serverInfo' <<< "${output}"
    assert_equal "${status}" 0
}

@test "create_response builds a 1.1 MB result exactly" {
    _source_sdk
    local result
    result=$(jq -n -c --rawfile text "${PAYLOAD_FILE}" '{"text": $text}')
    jq -n -c --rawfile p "${PAYLOAD_FILE}" '{"jsonrpc": "2.0", "id": 1, "result": {"text": $p}}' \
        > "${BATS_TEST_TMPDIR}/expected.json"

    local rc=0
    create_response 1 "${result}" > "${BATS_TEST_TMPDIR}/got.json" || rc=$?
    assert_equal "${rc}" 0
    run cmp "${BATS_TEST_TMPDIR}/got.json" "${BATS_TEST_TMPDIR}/expected.json"
    assert_equal "${status}" 0
}

@test "create_error_response builds 1.1 MB data exactly" {
    _source_sdk
    local data
    data=$(jq -n -c --rawfile text "${PAYLOAD_FILE}" '{"text": $text}')
    jq -n -c --rawfile p "${PAYLOAD_FILE}" \
        '{"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "m", "data": {"text": $p}}}' \
        > "${BATS_TEST_TMPDIR}/expected.json"

    local rc=0
    create_error_response 1 -32603 m "${data}" > "${BATS_TEST_TMPDIR}/got.json" || rc=$?
    assert_equal "${rc}" 0
    run cmp "${BATS_TEST_TMPDIR}/got.json" "${BATS_TEST_TMPDIR}/expected.json"
    assert_equal "${status}" 0
}

@test "create_response fails with status 5 and nothing on stdout for an empty result" {
    _source_sdk
    run --separate-stderr create_response 1 ''
    assert_equal "${status}" 5
    assert_output ''
}

@test "create_response fails with status 5 and nothing on stdout for a two-document result" {
    _source_sdk
    run --separate-stderr create_response 1 $'{}\n{}'
    assert_equal "${status}" 5
    assert_output ''
}

@test "create_error_response fails with status 5 and nothing on stdout for two-document data" {
    _source_sdk
    run --separate-stderr create_error_response 1 -32603 m $'{}\n{}'
    assert_equal "${status}" 5
    assert_output ''
}

@test "validate_tool_arguments rejects arguments holding two JSON documents as not evaluable" {
    _source_sdk
    run validate_tool_arguments record_args '{"text": "aaa"} {"evil": "x"}'
    assert_equal "${status}" 1
    assert_output "Cannot validate arguments for record_args: they could not be evaluated against its schema."
}
