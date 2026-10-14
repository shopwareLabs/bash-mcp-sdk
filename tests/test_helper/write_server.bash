#!/bin/bash
# Write a throwaway MCP server script at <path>, taking the consumer's own
# script lines from stdin. The generated file is a shebang, `set -euo pipefail`,
# the MCP_* paths a suite's setup() created, a `source` of the SDK, the stdin
# body, and the `run_mcp_server` call; the path is made executable.
#
# The body lands after `source`, so it can install traps or define tool
# functions ahead of `run_mcp_server`, and it is inserted verbatim. A caller
# whose body must have a suite variable expanded writes the heredoc unquoted; a
# caller whose body carries shell syntax of its own writes it quoted.
#
# tests/fixtures/cancellation_server.sh is deliberately not built this way. It
# is a static fixture that the cancellation and lifecycle suites drive as a
# contract, so it stays a file on disk rather than being generated per test.
#
# The MCP_* paths default to ${BATS_TEST_TMPDIR}, where write_fixture_files
# writes config.json and tools.json. Args: $1 = target path.
write_server() {
    local path="$1"
    local body
    body="$(cat)"

    cat > "${path}" <<SERVER
#!/usr/bin/env bash
set -euo pipefail
export MCP_CONFIG_FILE="${BATS_TEST_TMPDIR}/config.json"
export MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
source "${REPO_ROOT}/lib/mcpserver_core.sh"
${body}
run_mcp_server
SERVER
    chmod +x "${path}"
}

# Write the two files a server reads into BATS_TEST_TMPDIR: config.json holding
# an empty object, and tools.json holding <tools-list-json>, the paths
# write_server exports and suites hand to mcp_test_env. The tools list has no
# default: a caller that wants none passes '{"tools": []}'. Calling it again
# replaces both files.
# Usage: write_fixture_files <tools-list-json>
write_fixture_files() {
    if [[ $# -ne 1 || -z "$1" ]]; then
        printf 'usage: write_fixture_files <tools-list-json>\n' >&2
        return 2
    fi
    printf '%s\n' '{}' > "${BATS_TEST_TMPDIR}/config.json"
    printf '%s\n' "$1" > "${BATS_TEST_TMPDIR}/tools.json"
}
