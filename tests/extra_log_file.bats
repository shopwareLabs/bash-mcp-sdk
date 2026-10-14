#!/usr/bin/env bats
# bats file_tags=mcp-core,extra-log
# Tests the shared mcpserver_core logging surface: _configure_extra_log_file(),
# log()'s dual write, a failed log write that leaves the server running, and
# the escaping of line breaks in a logged message.
# Sources lib/mcpserver_core.sh directly. Consumers vendor that file verbatim, so
# this suite covers the module wherever it is vendored.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

setup() {
    mcp_test_env /dev/null /dev/null
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    mcp_stop_server
}

# --- _configure_extra_log_file ---

@test "_configure_extra_log_file: empty path is a no-op" {
    _configure_extra_log_file ""
    [[ -z "$MCP_EXTRA_LOG_FILE" ]]
}

@test "_configure_extra_log_file: relative path resolves against PROJECT_ROOT" {
    mkdir -p "${BATS_TEST_TMPDIR}/subdir"
    _configure_extra_log_file "subdir/debug.log"
    [[ "$MCP_EXTRA_LOG_FILE" == "${BATS_TEST_TMPDIR}/subdir/debug.log" ]]
}

@test "_configure_extra_log_file: absolute path used as-is" {
    _configure_extra_log_file "/tmp/bats-test-mcp.log"
    [[ "$MCP_EXTRA_LOG_FILE" == "/tmp/bats-test-mcp.log" ]]
}

@test "_configure_extra_log_file: non-existent parent dir warns and skips" {
    _configure_extra_log_file "nonexistent/debug.log"
    [[ -z "$MCP_EXTRA_LOG_FILE" ]]
    run grep "WARN" "${BATS_TEST_TMPDIR}/server.log"
    assert_success
    assert_output --partial "log_file parent directory does not exist"
}

# --- log() dual-write ---

@test "log: writes to both files when extra log configured" {
    local extra="${BATS_TEST_TMPDIR}/extra.log"
    MCP_EXTRA_LOG_FILE="$extra"
    log "INFO" "dual write test"
    run grep "dual write test" "${BATS_TEST_TMPDIR}/server.log"
    assert_success
    run grep "dual write test" "$extra"
    assert_success
}

@test "log: writes only to MCP_LOG_FILE when no extra log" {
    local extra="${BATS_TEST_TMPDIR}/extra.log"
    MCP_EXTRA_LOG_FILE=""
    log "INFO" "single write test"
    run grep "single write test" "${BATS_TEST_TMPDIR}/server.log"
    assert_success
    [[ ! -f "$extra" ]]
}

# --- log() stderr mirror ---

@test "log: does not mirror to stderr by default" {
    run --separate-stderr log "INFO" "no mirror by default"
    assert_success
    assert_stderr ''
}

@test "log: does not mirror to stderr when MCP_LOG_STDERR is 0" {
    MCP_LOG_STDERR=0
    run --separate-stderr log "INFO" "no mirror when zero"
    assert_success
    assert_stderr ''
}

@test "log: mirrors to stderr and still writes to MCP_LOG_FILE when MCP_LOG_STDERR is 1" {
    MCP_LOG_STDERR=1
    run --separate-stderr log "INFO" "mirror to stderr test"
    assert_success
    assert_stderr --partial "[INFO] mirror to stderr test"
    run grep "mirror to stderr test" "${BATS_TEST_TMPDIR}/server.log"
    assert_success
}

@test "log: does not mirror to stderr for a non-1 value like true" {
    MCP_LOG_STDERR=true
    run --separate-stderr log "INFO" "no mirror for true"
    assert_success
    assert_stderr ''
}

@test "log: does not mirror to stderr for a non-1 value like 2" {
    MCP_LOG_STDERR=2
    run --separate-stderr log "INFO" "no mirror for two"
    assert_success
    assert_stderr ''
}

# --- a failed log write leaves the server running ---

# Write the server script and the files it reads into BATS_TEST_TMPDIR; the
# body on stdin runs between `source` and `run_mcp_server`.
_write_logging_server() {
    write_fixture_files '{"tools": []}'
    write_server "${BATS_TEST_TMPDIR}/server.sh"
}

# Feed two pings to the server script, then EOF, and capture stdout and stderr.
_run_two_pings() {
    local input="${BATS_TEST_TMPDIR}/input.jsonl"
    {
        jq -nc '{jsonrpc: "2.0", id: 1, method: "ping"}'
        jq -nc '{jsonrpc: "2.0", id: 2, method: "ping"}'
    } > "$input"
    run --separate-stderr "${BATS_TEST_TMPDIR}/server.sh" < "$input"
}

@test "log: an unwritable MCP_LOG_FILE leaves the server answering and exiting 0" {
    local missing="${BATS_TEST_TMPDIR}/no-such-dir/server.log"
    _write_logging_server <<BODY
export MCP_LOG_FILE="${missing}"
BODY
    _run_two_pings
    assert_equal "$status" 0
    assert_equal "$(printf '%s\n' "$output" | jq -c '.id' | paste -sd, -)" "1,2"
    assert_stderr --partial "mcp: cannot write log file ${missing}"
    refute_stderr --partial "No such file or directory"
}

@test "log: an unwritable MCP_EXTRA_LOG_FILE leaves the server answering and exiting 0" {
    local missing="${BATS_TEST_TMPDIR}/no-such-dir/extra.log"
    _write_logging_server <<BODY
export MCP_EXTRA_LOG_FILE="${missing}"
BODY
    _run_two_pings
    assert_equal "$status" 0
    assert_equal "$(printf '%s\n' "$output" | jq -c '.id' | paste -sd, -)" "1,2"
    assert_stderr --partial "mcp: cannot write log file ${missing}"
    refute_stderr --partial "No such file or directory"
    run grep -c '\[INFO\]' "${BATS_TEST_TMPDIR}/server.log"
    assert_success
}

@test "log: a log file that becomes unwritable mid-run does not stop the server" {
    _write_logging_server <<'BODY'
BODY
    : > "${BATS_TEST_TMPDIR}/server.log"
    mcp_start_server "${BATS_TEST_TMPDIR}/server.sh"

    mcp_send "$(jq -nc '{jsonrpc: "2.0", id: 1, method: "initialize", params: {}}')"
    run mcp_wait_for_response 1
    assert_success
    # A directory in the file's place fails the append for root too, where chmod 444 would not.
    rm "${BATS_TEST_TMPDIR}/server.log"
    mkdir "${BATS_TEST_TMPDIR}/server.log"

    mcp_send "$(jq -nc '{jsonrpc: "2.0", id: 2, method: "ping"}')"
    run mcp_wait_for_response 2
    assert_success
    mcp_close_stdin
    local server_status=0
    wait "${MCP_SERVER_PID}" || server_status=$?
    assert_equal "$server_status" 0
    run grep -F "mcp: cannot write log file ${BATS_TEST_TMPDIR}/server.log" "${MCP_SERVER_ERR}"
    assert_success
    run grep -F "Is a directory" "${MCP_SERVER_ERR}"
    assert_equal "$status" 1
}

@test "log: MCP_LOG_STDERR=1 still mirrors the line when the file write fails" {
    local missing="${BATS_TEST_TMPDIR}/no-such-dir/server.log"
    _write_logging_server <<BODY
export MCP_LOG_FILE="${missing}"
export MCP_LOG_STDERR=1
BODY
    _run_two_pings
    assert_equal "$status" 0
    assert_stderr --partial "mcp: cannot write log file ${missing}"
    refute_stderr --partial "No such file or directory"
    assert_stderr --partial "] [INFO] "
}

# --- log() escapes line breaks in the message ---

@test "log: a method with a line break cannot forge a log line" {
    _write_logging_server <<'BODY'
BODY
    local method=$'x\n[2026-10-12 00:00:00] [ERROR] forged entry'
    jq -nc --arg m "$method" '{jsonrpc: "2.0", id: 1, method: $m}' > "${BATS_TEST_TMPDIR}/input.jsonl"
    run --separate-stderr "${BATS_TEST_TMPDIR}/server.sh" < "${BATS_TEST_TMPDIR}/input.jsonl"
    assert_equal "$status" 0
    run grep -c '^\[2026-10-12 00:00:00\]' "${BATS_TEST_TMPDIR}/server.log"
    assert_output "0"
    run grep -F 'Unknown method: x\n[2026-10-12 00:00:00] [ERROR] forged entry' "${BATS_TEST_TMPDIR}/server.log"
    assert_success
}

@test "log: a carriage return in the message is written as \\r on one line" {
    log "INFO" $'a\rb'
    assert_equal "$(wc -l < "${BATS_TEST_TMPDIR}/server.log" | tr -d ' ')" 1
    run grep -F 'a\rb' "${BATS_TEST_TMPDIR}/server.log"
    assert_success
}

@test "log: a failed write with stderr closed does not end a set -e shell" {
    run bash -ec 'source "$1"; export MCP_LOG_FILE="$2" MCP_LOG_STDERR=1; log INFO x 2>&-; echo survived' _ \
        "${REPO_ROOT}/lib/mcpserver_core.sh" "${BATS_TEST_TMPDIR}/no-such-dir/server.log"
    assert_equal "$status" 0
    assert_output --partial "survived"
}
