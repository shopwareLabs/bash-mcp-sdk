# bash-mcp-sdk

A Bash framework for writing [Model Context Protocol](https://modelcontextprotocol.io) servers. Handles the JSON-RPC 2.0 stdio loop, tool dispatch, argument validation against each tool's `inputSchema`, and logging.

One file, `lib/mcpserver_core.sh`. It sources nothing and depends on nothing but `jq`.

## 📌 Requirements

- Bash 4.0+
- `jq` 1.7+ — below that floor, jq parses every number to a double, so the validator's `integer` check cannot see a fraction the double rounded away.

> [!NOTE]
> macOS ships Bash 3.2. Install a current Bash (`brew install bash`) or run servers under one.

## 📦 Installation

There is no install step. Copy `lib/mcpserver_core.sh` into your project and `source` it. See [Vendoring](#-vendoring) for keeping the copy current.

## 🗜️ API

| Function | Purpose |
|---------------------------|-----------------------------------------------------------------------|
| `run_mcp_server`          | The stdio read loop. Call it last; it returns when stdin closes.      |
| `process_request`         | Parse and route one JSON-RPC line. Useful for testing a server.       |
| `validate_tool_arguments` | Check a call's arguments against the tool's `inputSchema`.            |
| `create_response`         | Build a JSON-RPC result envelope.                                     |
| `create_error_response`   | Build a JSON-RPC error envelope. Optional 4th arg `data` (JSON value) is included when non-empty. |
| `log`                     | Append to `MCP_LOG_FILE`, and to `MCP_EXTRA_LOG_FILE` when set.       |

Configured by environment variable before sourcing:

| Variable | Default | Meaning |
|-----------------------|---------------|---------------------------------------------------------|
| `MCP_TOOLS_LIST_FILE` | `tools.json`  | The tools the server advertises, and their schemas.     |
| `MCP_CONFIG_FILE`     | `config.json` | `protocolVersion`, `serverInfo`, `capabilities`.        |
| `MCP_LOG_FILE`        | `/dev/null`   | Where `log` writes.                                     |
| `MCP_EXTRA_LOG_FILE`  | unset         | Second log target; `PROJECT_ROOT` resolves a relative path. |

Methods handled: `initialize`, `tools/list`, `tools/call`, `notifications/initialized`, `ping`. Anything else returns `-32601`.

### Writing a server

Each tool is a Bash function named `tool_<name>`, receiving the call's `arguments` as one JSON string:

```bash
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MCP_TOOLS_LIST_FILE="${HERE}/tools.json"
export MCP_LOG_FILE="${HERE}/server.log"

source "${HERE}/mcpserver_core.sh"

tool_greet() {
    local args="$1"
    local name
    name=$(printf '%s' "$args" | jq -r '.name')
    printf 'Hello, %s\n' "$name"
}

run_mcp_server
```

Every `inputSchema` in `tools.json` is enforced before the tool function runs — `required`, `additionalProperties: false`, `type`, `pattern`, `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`, array `items.type` / `items.enum`, and `enum`. A `type` — on a property or on `items` — may be one name or a list of alternatives (e.g. `"type": ["integer", "string"]`). A value satisfies it by matching any member. A range bound applies only to a number-valued argument — a string, boolean, or other non-number carries no bound — and a bound that is not itself a number is left unenforced, which also covers the JSON Schema draft-04 boolean form `"exclusiveMinimum": true`. Diagnostics report the most fundamental defect first, in that order. A tool with no `inputSchema` is dispatched unvalidated.

A tool that exits non-zero returns its combined output as an `isError` result rather than killing the server.

> [!IMPORTANT]
> Stdout is the protocol channel. A tool function's stdout becomes the tool result, so everything else a server wants to say goes through `log`. A stray `echo` outside a tool corrupts the stream.

Two properties of tool dispatch to write against:

- A tool function runs with errexit disabled: dispatch tests the function's exit status, and Bash turns `set -e` off inside anything tested in a conditional. Check each step's status yourself and return non-zero to produce the `isError` result.
- A tool function inherits the server's stdin, which is the JSON-RPC pipe. A child process that reads stdin blocks on it forever, or consumes bytes meant for the server. Run anything that might prompt with `< /dev/null`.

## 🔗 Vendoring

Consumers copy `lib/mcpserver_core.sh` into their own tree and pin the release they copied from. The recommended shape:

1. A lock file recording the tag, e.g. `.mcp-sdk.lock` containing `version=v1.0.0`.
2. A vendor script that downloads that tag and writes the file to every consuming path, with a `--check` mode that re-vendors to a temp directory and diffs instead of writing.
3. A Renovate custom manager watching the lock file, so upgrades arrive as PRs:

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/^\\.mcp-sdk\\.lock$/"],
      "matchStrings": ["version=(?<currentValue>v\\d+\\.\\d+\\.\\d+)"],
      "depNameTemplate": "shopwareLabs/bash-mcp-sdk",
      "datasourceTemplate": "github-releases",
      "versioningTemplate": "semver"
    }
  ]
}
```

4. A CI job on the Renovate branch that runs the vendor script and pushes the refreshed file into the same PR, plus the `--check` mode as a gate on every build.

> [!IMPORTANT]
> Renovate's own `postUpgradeTasks` looks like the natural place for step 4, but the commands it may run are gated by `allowedCommands`, which is self-hosted-only. On the Mend-hosted app the allowed set is undocumented and can change. Drive the re-vendor from CI instead.

## 🧪 Testing

```bash
./.github/scripts/setup-bats.sh          # once, installs into .bats/
.bats/bats-core/bin/bats -r tests/
```

Lint with ShellCheck before pushing:

```bash
find lib tests .github/scripts -type f \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) \
  -exec shellcheck --shell=bash --format=gcc {} +
```

## 🚫 Not Supported

- MCP resources and prompts — tools only
- Transports other than stdio
- Concurrent request handling; the server loop is strictly sequential
- Running the tool command anywhere but the local shell. Container, VM, and remote execution are a consumer concern; this SDK dispatches to a Bash function and nothing more.

## ⚖️ License

[MIT](./LICENSE)
