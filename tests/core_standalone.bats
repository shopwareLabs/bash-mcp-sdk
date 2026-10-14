#!/usr/bin/env bats
# bats file_tags=mcp-core,standalone
# Pins this repository's boundary: mcpserver_core.sh is the whole SDK, it sources
# nothing, and a server needs no other file to serve the protocol. An edit that
# reaches for a helper living outside this repo fails here rather than in a
# consumer's vendored copy.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"
load "${BATS_TEST_DIRNAME}/test_helper/mcp_client"
load "${BATS_TEST_DIRNAME}/test_helper/write_server"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    # The server sources a copy of the core that sits alone in its directory, and
    # runs from that directory, so a source of any other repository file fails.
    STANDALONE_DIR="${BATS_TEST_TMPDIR}/standalone"
    mkdir -p "${STANDALONE_DIR}/lib"
    cp "${CORE_SH}" "${STANDALONE_DIR}/lib/mcpserver_core.sh"

    # config.json is `{}`: initialize reads it, and the defaults it leaves in
    # place are the values the initialize test asserts.
    write_fixture_files '{
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
}'

    # write_server sources ${REPO_ROOT}/lib/mcpserver_core.sh; pointing REPO_ROOT
    # at the standalone directory makes it source the lone copy.
    REPO_ROOT="${STANDALONE_DIR}" write_server "${BATS_TEST_TMPDIR}/server.sh" <<'BODY'
tool_greet() {
    local args="$1"
    local name
    name=$(printf '%s' "$args" | jq -r '.name')
    printf 'Hello, %s\n' "$name"
}
BODY
}

# Send one request line to the standalone server, run from the standalone
# directory, and capture its output.
_serve() {
    cd "${STANDALONE_DIR}" || return 1
    run bash "${BATS_TEST_TMPDIR}/server.sh" <<< "$1"
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

@test "a server sourcing only mcpserver_core.sh answers a schema violation with an isError result" {
    _serve '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greet","arguments":{}}}'
    assert_success
    mcp_assert_tool_result "${output}" 3 true "Missing required parameter(s): name."
}

@test "mcpserver_core.sh holds no source or . command in the forms the grep recognizes" {
    # A source or `.` at the start of a line, after &&, || or ;, or after then,
    # do, if, elif, while, until, `!`, builtin or eval. Past the line start a `.` counts only before a quote,
    # `$`, `/`, `~` or `.`, which keeps jq's identity filter (`then . else`) out.
    # It therefore misses a `.` followed by a bare relative file name after a keyword
    # or separator (`while . x.sh; do`), which jq filters (`. as $x`) look the same as,
    # and a `.` inside a quoted string (`eval '. lib/x.sh'`).
    local arg="(source[[:space:]]+|\\.[[:space:]]+[\"'\$/~.])"
    run grep -nE \
        -e '^[[:space:]]*(source|\.)[[:space:]]+' \
        -e "(&&|\\|\\||;)[[:space:]]*${arg}" \
        -e "(^|[^[:alnum:]_])(then|do|if|elif|while|until|!|builtin|eval)[[:space:]]+[\"']?${arg}" \
        "${CORE_SH}"
    assert_equal "${status}" 1
    assert_output ''
}
