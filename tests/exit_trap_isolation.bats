#!/usr/bin/env bats
# bats file_tags=mcp-core,standalone
# Pins run_mcp_server's ownership of the process EXIT trap and the reset of
# _MCP_IN_SERVER_LOOP it performs after the loop exits. run_mcp_server sets
# its own EXIT trap, replacing whatever handler the shell already had; a caller
# that runs it in a subshell keeps its own trap, so a suite calling it in the
# test shell must isolate it there or lose bats' reporting trap and drop the
# test silently when the body later aborts.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    : > "${MCP_LOG_FILE}"
}

@test "run_mcp_server isolated in a subshell leaves the caller's EXIT trap armed" {
    # shellcheck source=../lib/mcpserver_core.sh
    source "${CORE_SH}"
    _caller_exit_trap() {
        printf 'caller trap ran\n'
    }
    trap '_caller_exit_trap' EXIT

    # The isolated shape: run_mcp_server's EXIT trap lives and dies in the
    # subshell, leaving this shell's trap as the assertion below expects.
    ( run_mcp_server </dev/null )

    run trap -p EXIT
    assert_success
    assert_output "trap -- '_caller_exit_trap' EXIT"
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
