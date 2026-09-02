#!/usr/bin/env bats
# bats file_tags=mcp-core,standalone
# Pins this repository's boundary: mcpserver_core.sh is the whole SDK, it sources
# nothing, and a server needs no other file to serve the protocol. An edit that
# reaches for a helper living outside this repo fails here rather than in a
# consumer's vendored copy.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    cat > "${BATS_TEST_TMPDIR}/tools.json" <<'JSON'
{
  "tools": [
    {
      "name": "greet",
      "inputSchema": {
        "type": "object",
        "required": ["name"],
        "properties": {"name": {"type": "string", "pattern": "^[a-z]+$"}},
        "additionalProperties": false
      }
    }
  ]
}
JSON

    cat > "${BATS_TEST_TMPDIR}/server.sh" <<SERVER
#!/usr/bin/env bash
set -euo pipefail
export MCP_CONFIG_FILE="/dev/null"
export MCP_TOOLS_LIST_FILE="${BATS_TEST_TMPDIR}/tools.json"
export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
source "${CORE_SH}"
tool_greet() {
    local args="\$1"
    local name
    name=\$(printf '%s' "\$args" | jq -r '.name')
    printf 'Hello, %s\n' "\$name"
}
run_mcp_server
SERVER
}

# Drive the standalone server with one request, return its single response line.
_serve() {
    run bash -c "printf '%s\n' '$1' | bash '${BATS_TEST_TMPDIR}/server.sh'"
}

@test "a server sourcing only mcpserver_core.sh answers initialize" {
    _serve '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    assert_success
    assert_output '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"mcp-server","version":"1.0.0"},"capabilities":{"tools":{}}}}'
}

@test "a server sourcing only mcpserver_core.sh dispatches a valid tools/call" {
    _serve '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"name":"martin"}}}'
    assert_success
    assert_output '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Hello, martin"}],"isError":false}}'
}

@test "a server sourcing only mcpserver_core.sh rejects a schema violation" {
    _serve '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greet","arguments":{}}}'
    assert_success
    assert_output --partial 'Missing required parameter(s): name.'
}

@test "mcpserver_core.sh sources no other file" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]+' "${CORE_SH}"
    assert_failure
    assert_output ''
}
