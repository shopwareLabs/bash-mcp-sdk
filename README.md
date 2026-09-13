# bash-mcp-sdk

A Bash framework for writing [Model Context Protocol](https://modelcontextprotocol.io) servers. It handles the JSON-RPC 2.0 stdio loop, tool dispatch, argument validation against each tool's `inputSchema`, and logging.

One file, `lib/mcpserver_core.sh`. It sources nothing and needs `jq`, plus `ps` and `mkfifo` for the tool lifecycle. The runtime mechanism behind the contracts below is in [`docs/architecture.md`](./docs/architecture.md).

## 📌 Requirements

- Bash 4.1+ — the file allocates file descriptors with `{var}` redirection, which arrived in 4.1.
- `jq` 1.7+ — below that floor, jq parses every number to a double. The validator's `integer` check then cannot see a fraction the double rounded away.
- `ps` and `mkfifo` — the tool lifecycle. `run_mcp_server` creates the lifeline with `mkfifo` as it starts, and `ps` is reached only once a tool runs. BusyBox ships both, so an Alpine consumer needs no procps (why the code reads a full `ps` listing is in `docs/architecture.md` §Cancellation).

Sourcing the file checks the first two floors. A Bash below 4.1, a `jq` that is missing or cannot run, or a `jq` below 1.7 is refused on stderr. The refusal names the requirement and, where there is one, the version found. It adds remediation for the platform: its package manager's command where one can be determined, and a generic line otherwise.

`ps` and `mkfifo` go unchecked. A host that lacks either fails later instead: `mkfifo` at startup, `ps` at the first tool call.

> [!NOTE]
> macOS ships Bash 3.2. Install a current Bash (`brew install bash`) or run servers under one. An MCP host launched from the desktop does not read your shell profile. The newer Bash therefore has to sit on the PATH that host starts the server with.

The floors are checked when the file is sourced. `PATH` therefore has to be right at that point: after sourcing, a `PATH` fix is too late. In a server script, export the new directory above the `source` line:

```bash
export PATH="/opt/homebrew/bin:${PATH}"
source "/path/to/mcpserver_core.sh"
```

An operator who cannot edit the script sets it in the host manifest's launch command instead:

```json
"command": "bash",
"args": ["-c", "export PATH=/opt/homebrew/bin:$PATH; exec /path/to/server.sh"]
```

That route also selects the Bash the server runs under, not only `jq`. The outer shell runs only `export` and `exec`, which Bash 3.2 handles. The inner script's `#!/usr/bin/env bash` shebang then resolves through the repaired `PATH`. One manifest change therefore fixes both floors on a Mac whose only Bash is 3.2.

## 📦 Installation

There is no install step. Copy `lib/mcpserver_core.sh` into your project and `source` it. See [Vendoring](#-vendoring) for keeping the copy current.

## 🗜️ API

| Function | Purpose |
|---------------------------|-----------------------------------------------------------------------|
| `run_mcp_server`          | The stdio read loop. Call it last; it returns when stdin closes.      |
| `process_request`         | Parse and route one JSON-RPC line. Useful for testing a server.       |
| `handle_initialize`       | The `initialize` handler `process_request` routes to. Answers `protocolVersion`, `serverInfo` and `capabilities`. |
| `handle_tools_list`       | The `tools/list` handler `process_request` routes to. Answers the `tools` array. |
| `handle_tools_call`       | The `tools/call` handler `process_request` routes to. A consumer can drive it directly to dispatch one call without the read loop. |
| `validate_tool_arguments` | Check a call's arguments against the tool's `inputSchema`.            |
| `create_response`         | Build a JSON-RPC result envelope.                                     |
| `create_error_response`   | Build a JSON-RPC error envelope. Optional 4th arg `data` (JSON value) is included when non-empty. |
| `log`                     | Append to `MCP_LOG_FILE`, and to `MCP_EXTRA_LOG_FILE` when set.       |
| `read_json_file`          | Read one JSON document from a file. Prints it when it is a JSON object; returns 1 on a missing file or one that does not hold exactly one JSON object. |

Configured by environment variable before sourcing:

| Variable | Default | Meaning |
|-----------------------|---------------|---------------------------------------------------------|
| `MCP_TOOLS_LIST_FILE` | `tools.json`  | The tools the server advertises, and their schemas.     |
| `MCP_CONFIG_FILE`     | `config.json` | `protocolVersion`, `serverInfo`, `capabilities`.        |
| `MCP_LOG_FILE`        | `/dev/null`   | Where `log` writes.                                     |
| `MCP_EXTRA_LOG_FILE`  | unset         | Second log target; `PROJECT_ROOT` resolves a relative path. |
| `MCP_LOG_STDERR`      | `0`           | Set to `1` to also mirror each log line to stderr.       |

A missing or unparseable `MCP_CONFIG_FILE` or `MCP_TOOLS_LIST_FILE` is not read as an empty configuration; both files are effectively required. `initialize` and `tools/list` answer `-32603`, naming the file they could not read. That covers a file whose single document is not a JSON object. A `tools/call` whose tools list cannot be read is rejected with an `isError` result instead of being dispatched unvalidated.

Methods handled: `initialize`, `tools/list`, `tools/call` and `ping`; the notifications `notifications/initialized` and `notifications/cancelled`. A request for any other method returns `-32601`; a notification for one is logged and ignored.

A message whose `id` is present but is not a string or an integer is neither a request nor a notification. MCP requires a request id to be a string or an integer, and a notification carries no id. Such a message is answered `-32600` rather than dropped.

A request must be a single JSON object on a line of its own. A line that holds more than one JSON document, or that is not parseable JSON, is answered `-32700 Parse error` and not dispatched. A document that is valid JSON but not an object is answered `-32600` with a null `id`. That covers `[1,2]`, `"x"`, `5`, `true`, `false` and `null`.

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

A tool may also define an optional `tool_<name>_cancel` hook, which the server calls when the call is cancelled. *Cancelling and shutting down* below gives its contract.

The hook is resolved by name. A tool whose own name ends in `_cancel` is therefore also the cancellation hook of whatever precedes that suffix. A tool named `foo_cancel` is dispatched as a tool, and it is called when `foo` is cancelled. Do not name a tool `<other>_cancel` unless that is what you mean.

Every `inputSchema` in `tools.json` is enforced before the tool function runs. The keywords are `required`, `additionalProperties: false`, `type`, `pattern`, `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`, array `items.type` / `items.enum`, and `enum`.

A `type` — on a property or on `items` — may be one name or a list of alternatives (e.g. `"type": ["integer", "string"]`). A value satisfies it by matching any member.

A range bound applies only to a number-valued argument. A string, boolean, or other non-number carries no bound. A bound that is not itself a number is left unenforced, which also covers the JSON Schema draft-04 boolean form `"exclusiveMinimum": true`.

Diagnostics report the most fundamental defect first, in that order. A tool with no `inputSchema` is dispatched unvalidated.

A tool that exits non-zero returns its combined output as an `isError` result rather than killing the server.

> [!IMPORTANT]
> Stdout is the protocol channel. A tool function's stdout becomes the tool result, so everything else a server wants to say goes through `log`. A stray `echo` outside a tool corrupts the stream.

Two properties of tool dispatch to write against:

- A tool function always runs with errexit disabled, on every dispatch path. That holds under `run_mcp_server` and from a direct call to `process_request` or `handle_tools_call` alike. A failing step does not end the tool. Check each step's status yourself and return non-zero to produce the `isError` result.
- A tool function's stdin is `/dev/null`. A read returns EOF instead of blocking on the server's protocol stream or consuming bytes meant for it.

### Cancelling and shutting down

A client cancels an in-flight call by sending `notifications/cancelled` with the request's id in `params.requestId`. The server stops the tool's process group with `SIGTERM`, then `SIGKILL` for whatever is left of it, and sends no response for that id. A cancellation that names nothing in flight is logged and dropped. A tool that dies on the `SIGTERM` is reaped at once rather than after the two-second grace (measured as in `docs/architecture.md` §Cancellation).

The tool's process group is the containment boundary. Anything the tool leaves running in it — a background child it never waits for — is killed when the call ends. That holds on success as much as on cancellation (the containment mechanism is in `docs/architecture.md` §Tool containment).

A tool that must outlive the call has to leave the group itself by detaching into a new session. Bash offers no builtin for that and macOS ships no `setsid(1)`, so such a tool needs its own double-fork.

A tool may define an optional `tool_<name>_cancel` hook. It runs with the call's original `arguments` JSON as its one argument. A signal that tears the server down passes an empty string instead: the in-flight record holds the tool's group and name, but no arguments.

The hook runs before the group is signalled, and each of the two steps gets its own two seconds. A hook that runs longer than two seconds is killed, and its exit status is logged rather than failing the call. A wedged hook followed by a group that ignores `SIGTERM` therefore holds a cancellation for about four seconds before the final `SIGKILL`.

`run_mcp_server` installs `EXIT`, `INT`, `TERM`, `HUP` and `PIPE` traps, replacing any handler a consumer set on those signals. It expects to be the last call in its process; a server that needs its own `EXIT` trap afterwards calls `run_mcp_server` in a subshell. A signal to the server's whole process group takes effect at once. One sent to the server's pid alone mid-call takes effect after that call returns, and lets it finish.

Both shapes stop the tool group before the server exits. A signal that arrives while a teardown is already running does not cut it short. That pass finishes, and the shell then dies by the signal.

A call that finishes that way may go unanswered. Bash runs a trap between commands, so the trap fires as soon as the dispatch returns (the mechanism is in `docs/architecture.md` §Shutdown). The response the dispatch built is still in a variable at that point, and the shell dies before the loop echoes it.

Kill the process group to stop a call and still see its result. To stop the server instead, signal its pid alone, and expect a call in flight to go unanswered.

Bash cannot install a handler for a signal that was ignored when the shell started. A non-interactive shell's plain `&` hands the background job `SIGINT` and `SIGQUIT` already ignored. A server backgrounded that way with job control off therefore has no `INT` trap at all. The `TERM` and `HUP` traps install normally.

A server killed with `SIGKILL` runs no trap, so a call it had in flight is stopped by the lifeline instead (the lifeline and its sentinel are in `docs/architecture.md` §The lifeline). That kill runs no cleanup, so small files under `TMPDIR` (default `/tmp`) can be left behind, and nothing removes them. The patterns are `mcp-inflight.*`, `mcp-lifeline.*`, `mcp-tool-output.*`, `mcp-sentinel.*` and `mcp-partial.*`. A server that goes down on a signal it can trap removes the in-flight call's output file as part of its teardown.

A client that closes stdin mid-call still gets that call's response. The server finishes the call, answers it, and then exits. Requests that arrived during the call are answered after it, in order.

A line the client had begun but left incomplete when the call ends is carried out of the dispatch. The read loop joins it to the next line it takes in (the handoff is in `docs/architecture.md` §Partial-line handoff). The call's response therefore reaches the client as soon as the dispatch returns, rather than waiting on that line.

The request the completed line forms is answered behind the response already sent. A client that never finishes the line therefore delays only the next request, exactly as one that stalls between requests.

A fragment the server still holds when the client closes stdin is answerable on the same terms. It is answered when it parses as JSON, which is a request the client finished writing without a trailing newline. It is discarded with only its length logged when it does not parse.

## 🔗 Vendoring

Consumers copy `lib/mcpserver_core.sh` into their own tree and pin the release they copied from. The recommended shape:

1. A lock file recording the tag, e.g. `.mcp-sdk.lock` containing `version=v1.0.0`.
2. A vendor script that downloads that tag and writes the file to every consuming path. A `--check` mode re-vendors to a temp directory and diffs instead of writing.
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

4. A CI job on the Renovate branch. It runs the vendor script, pushes the refreshed file into the same PR, and gates every build on `--check`.

> [!IMPORTANT]
> Renovate's own `postUpgradeTasks` looks like the natural place for step 4. The commands it may run are gated by `allowedCommands`, which is self-hosted-only. On the Mend-hosted app the allowed set is undocumented and can change. Drive the re-vendor from CI instead.

## 🧪 Testing

```bash
./.github/scripts/setup-bats.sh          # once, installs into .bats/
.bats/bats-core/bin/bats -r tests/
```

Or run it in containers, which need Docker:

```bash
./scripts/test-linux.sh            # ShellCheck, then Debian and Alpine
./scripts/test-linux.sh debian     # one distro: no ShellCheck
```

Set `BASE_IMAGE_DEBIAN` or `BASE_IMAGE_ALPINE` to override that build's base image. Set `JQ_VERSION` to install that upstream static jq release instead of the distro package.

Debian is the glibc/GNU run. Alpine adds only Bash and jq to musl/busybox, so a suite that leans on a tool the dev machine happens to carry fails there.

Both suites gate, in bare and named runs alike.

Lint with ShellCheck before pushing:

```bash
find lib tests scripts .github/scripts -type f \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) \
  -exec shellcheck --shell=bash --format=gcc {} +
```

## 🚫 Not Supported

- MCP resources and prompts — tools only
- Transports other than stdio
- Concurrent request handling; the server loop is strictly sequential
- Running the tool command anywhere but the local shell. Container, VM, and remote execution are a consumer concern; this SDK dispatches to a Bash function and nothing more.

### Why resources and prompts are not planned

This SDK targets servers that ship inside agent plugins, such as Claude Code or Codex distributions. In that setting Bash and jq are the only client-side requirements. Such a server runs next to a local coding agent, and that setting decides both features.

Resources duplicate what the agent already has. The agent reads local files itself. Any data the server can reach (a database schema, an API response) a tool returns on demand, parameterized and fresh after every change. An attached resource is a snapshot the model cannot refresh mid-task.

Prompts carry workflows to clients you do not control. A plugin has its own commands and skills for that, versioned next to the server. A server meant for broad distribution to arbitrary clients is the use case for an official SDK in a general-purpose language. It is not the use case for this one.

## ⚖️ License

[MIT](./LICENSE)
