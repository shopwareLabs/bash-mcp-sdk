#!/usr/bin/env bats
# bats file_tags=mcp-core,extra-log
# Tests the shared mcpserver_core logging surface: _configure_extra_log_file()
# and log()'s dual write.
# Sources lib/mcpserver_core.sh directly. Consumers vendor that file verbatim, so
# this suite covers the module wherever it is vendored.
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
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE MCP_LOG_STDERR
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
    [[ -z "$stderr" ]]
}

@test "log: does not mirror to stderr when MCP_LOG_STDERR is 0" {
    MCP_LOG_STDERR=0
    run --separate-stderr log "INFO" "no mirror when zero"
    assert_success
    [[ -z "$stderr" ]]
}

@test "log: mirrors to stderr and still writes to MCP_LOG_FILE when MCP_LOG_STDERR is 1" {
    MCP_LOG_STDERR=1
    run --separate-stderr log "INFO" "mirror to stderr test"
    assert_success
    [[ "$stderr" == *"[INFO] mirror to stderr test"* ]]
    run grep "mirror to stderr test" "${BATS_TEST_TMPDIR}/server.log"
    assert_success
}

@test "log: does not mirror to stderr for a non-1 value like true" {
    MCP_LOG_STDERR=true
    run --separate-stderr log "INFO" "no mirror for true"
    assert_success
    [[ -z "$stderr" ]]
}

@test "log: does not mirror to stderr for a non-1 value like 2" {
    MCP_LOG_STDERR=2
    run --separate-stderr log "INFO" "no mirror for two"
    assert_success
    [[ -z "$stderr" ]]
}
