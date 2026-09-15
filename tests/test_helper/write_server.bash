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
# The MCP_* paths default to ${BATS_TEST_TMPDIR}, which a suite's setup() fills
# with config.json and tools.json. Args: $1 = target path.
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
