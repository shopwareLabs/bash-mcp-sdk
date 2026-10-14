#!/usr/bin/env bats
# bats file_tags=mcp-core,exit-trap-isolation
# Pins the reset of _MCP_IN_SERVER_LOOP that run_mcp_server performs after its
# loop exits. The call runs in a subshell: run_mcp_server takes over the EXIT
# trap and its teardown runs the handler it displaced, so called in the bats
# test shell it would run bats' own reporting trap and make bats misreport the
# test (a spurious `not ok` at the run_mcp_server line, or a test-count
# mismatch).
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    # The loop reads no request, so neither file is opened.
    mcp_test_env /dev/null /dev/null
}

@test "run_mcp_server resets _MCP_IN_SERVER_LOOP to 0 after its loop exits" {
    # shellcheck source=../lib/mcpserver_core.sh
    source "${CORE_SH}"

    # The reset is observable only inside the isolating subshell: the loop and
    # the read share it, so the flag reads 1 up to the loop's exit and 0 after
    # the reset. Read in this shell instead, the variable is unset either way,
    # which passes against a library that never reset it.
    output=$( ( run_mcp_server </dev/null; printf '%s' "${_MCP_IN_SERVER_LOOP}" ) )

    assert_equal "${output}" "0"
}
