#!/usr/bin/env bats
# bats file_tags=mcp-core,standalone
# Pins this repository's boundary: mcpserver_core.sh is the whole SDK, it sources
# nothing, and a server needs no other file to serve the protocol. An edit that
# reaches for a helper living outside this repo fails here rather than in a
# consumer's vendored copy.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    # A minimal valid config: initialize reads it, and the defaults it leaves in
    # place are the values the standalone tests assert.
    cat > "${BATS_TEST_TMPDIR}/config.json" <<'JSON'
{}
JSON

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

    write_server "${BATS_TEST_TMPDIR}/server.sh" <<'BODY'
tool_greet() {
    local args="$1"
    local name
    name=$(printf '%s' "$args" | jq -r '.name')
    printf 'Hello, %s\n' "$name"
}
BODY
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
