#!/usr/bin/env bats
# bats file_tags=mcp-core,client-harness
# Validates tests/test_helper/mcp_client.bash against the server's current
# behavior: start a fixture server, drive one request at a time over the FIFO,
# wait for its response, assert silence for an id that was never sent and fail
# for one that was answered, and tear the server down; that a start, or a
# send, fails loudly when the server exits or writes during startup or is gone;
# and that the tools/call result assertions accept one response with a result
# and no error key and refuse an error key, even a null one, and a response
# whose first of several documents is wrong.
# Cancellation behavior is covered by cancellation.bats, which uses these
# helpers to drive the in-flight request stream.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CANCELLATION_SERVER="${REPO_ROOT}/tests/fixtures/cancellation_server.sh"

setup() {
    # Keep the fixture's log out of mktemp's directory and inside the test's.
    # The fixture exports its own config and tools list over these two paths.
    mcp_test_env "${REPO_ROOT}/tests/fixtures/cancellation_config.json" \
        "${REPO_ROOT}/tests/fixtures/cancellation_tools_list.json"
    mcp_start_server "${CANCELLATION_SERVER}"
}

teardown() {
    mcp_stop_server
}

@test "mcp_start_server: the server answers initialize with the request id" {
    mcp_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

    run mcp_wait_for_response 1
    assert_success
    local response="${output}"

    run jq -e 'has("result") and (has("error") | not)' <<< "${response}"
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

@test "mcp_assert_no_response: fails naming the response for an id the server answered" {
    mcp_send '{"jsonrpc":"2.0","id":9,"method":"ping"}'
    run mcp_wait_for_response 9 5
    assert_success

    run mcp_assert_no_response 9 0.5

    assert_equal "${status}" 1
    assert_output 'mcp_assert_no_response: unexpected response for id 9: {"jsonrpc":"2.0","id":9,"result":{}}'
}

@test "mcp_assert_tool_result: passes for one response with a result and no error key" {
    run mcp_assert_tool_result \
        '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}' \
        4 false 'done'

    assert_equal "${status}" 0
}

@test "mcp_assert_tool_result: fails for a response carrying an error key with a null value" {
    run mcp_assert_tool_result \
        '{"jsonrpc":"2.0","id":4,"error":null,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}' \
        4 false 'done'

    assert_equal "${status}" 1
    assert_output --partial 'mcp_assert_tool_result: the response does not match'
}

@test "mcp_assert_tool_result: fails when a wrong response for the id precedes the right one" {
    local wrong='{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"other"}],"isError":false}}'
    local right='{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}'

    run mcp_assert_tool_result "$(printf '%s\n%s' "${wrong}" "${right}")" 4 false 'done'

    assert_equal "${status}" 1
    assert_output --partial 'mcp_assert_tool_result: the response does not match'
}

@test "mcp_assert_tool_result_file: passes for one response with a result and no error key" {
    printf 'done' > "${BATS_TEST_TMPDIR}/expected.txt"

    run mcp_assert_tool_result_file \
        '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}' \
        4 false "${BATS_TEST_TMPDIR}/expected.txt"

    assert_equal "${status}" 0
}

@test "mcp_assert_tool_result_file: fails for a response carrying an error key with a null value" {
    printf 'done' > "${BATS_TEST_TMPDIR}/expected.txt"

    run mcp_assert_tool_result_file \
        '{"jsonrpc":"2.0","id":4,"error":null,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}' \
        4 false "${BATS_TEST_TMPDIR}/expected.txt"

    assert_equal "${status}" 1
    assert_output --partial 'mcp_assert_tool_result_file: the response does not match'
}

@test "mcp_assert_tool_result_file: fails when a wrong response for the id precedes the right one" {
    local wrong='{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"other"}],"isError":false}}'
    local right='{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}'
    printf 'done' > "${BATS_TEST_TMPDIR}/expected.txt"

    run mcp_assert_tool_result_file "$(printf '%s\n%s' "${wrong}" "${right}")" 4 false "${BATS_TEST_TMPDIR}/expected.txt"

    assert_equal "${status}" 1
    assert_output --partial 'mcp_assert_tool_result_file: the response does not match'
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

# Except where a test uses the fixture server from setup, the tests below stop
# it and start their own.

@test "mcp_start_server: returns only after the server has finished its startup" {
    # The body is the server's startup work: a delay between sourcing the core
    # and run_mcp_server, then a marker. A start that returned after a fixed
    # short wait would return before the marker exists.
    mcp_stop_server
    write_fixture_files '{"tools": []}'
    write_server "${BATS_TEST_TMPDIR}/slow_start.sh" <<BODY
sleep 1
touch "${BATS_TEST_TMPDIR}/startup.done"
BODY

    mcp_start_server "${BATS_TEST_TMPDIR}/slow_start.sh"

    [[ -f "${BATS_TEST_TMPDIR}/startup.done" ]]
}

@test "mcp_start_server: fails when the server writes to the protocol stream during startup" {
    mcp_stop_server
    write_fixture_files '{"tools": []}'
    write_server "${BATS_TEST_TMPDIR}/noisy.sh" <<'BODY'
printf 'startup noise\n' >&"${_MCP_PROTOCOL_FD}"
BODY

    run mcp_start_server "${BATS_TEST_TMPDIR}/noisy.sh"

    assert_equal "${status}" 1
    assert_output --regexp 'server [0-9]+ wrote to the protocol stream during startup'
    assert_output --partial 'startup noise'
}

@test "mcp_start_server: leaves the capture file empty after a clean start" {
    run wc -c < "${MCP_SERVER_OUT}"
    assert_success
    assert_output --regexp '^[[:space:]]*0$'
}

@test "mcp_start_server: a response written after the start is the first line in the output" {
    # The harness empties the capture file after the readiness ping while the
    # server still holds it; a server writing at its old offset would leave NUL
    # bytes ahead of this line.
    mcp_send '{"jsonrpc":"2.0","id":7,"method":"ping"}'

    run mcp_wait_for_response 7
    assert_success
    # Compared byte for byte: command substitution would drop the NUL bytes.
    run cmp - "${MCP_SERVER_OUT}" <<< '{"jsonrpc":"2.0","id":7,"result":{}}'
    assert_success
}

@test "mcp_start_server: fails with the server's stderr when the server exits before serving" {
    mcp_stop_server
    write_fixture_files '{"tools": []}'
    write_server "${BATS_TEST_TMPDIR}/dies.sh" <<< 'echo "startup refused" >&2; exit 1'

    run mcp_start_server "${BATS_TEST_TMPDIR}/dies.sh"

    assert_equal "${status}" 1
    assert_output --regexp 'server [0-9]+ exited during startup'
    assert_output --partial 'startup refused'
}

@test "mcp_send: fails with the server's pid when the server is gone" {
    kill -KILL "${MCP_SERVER_PID}"
    wait "${MCP_SERVER_PID}" || true

    run mcp_send '{"jsonrpc":"2.0","id":8,"method":"ping"}'

    assert_equal "${status}" 1
    assert_output "mcp_send: write failed; the server is not reading its stdin (pid ${MCP_SERVER_PID})"
}
