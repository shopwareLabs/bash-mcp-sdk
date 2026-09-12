# bash-mcp-sdk

A Bash framework for writing [Model Context Protocol](https://modelcontextprotocol.io) servers. Handles the JSON-RPC 2.0 stdio loop, tool dispatch, argument validation against each tool's `inputSchema`, and logging.

One file, `lib/mcpserver_core.sh`. It sources nothing and needs `jq`, plus `ps` and `mkfifo` for the tool lifecycle.

## 📌 Requirements

- Bash 4.1+ — the file allocates file descriptors with `{var}` redirection, which arrived in 4.1.
- `jq` 1.7+ — below that floor, jq parses every number to a double, so the validator's `integer` check cannot see a fraction the double rounded away.
- `ps` and `mkfifo` — the tool lifecycle. `run_mcp_server` creates the lifeline with `mkfifo`; the sentinel that kills a tool's process group once the server is gone, and the cancellation path that tells a live group from an emptied one, both read a full `ps -A -o` listing (`pid` and `pgid` columns) and filter it in Bash rather than selecting by pid or group. That shape is common to procps, BSD/macOS, and BusyBox `ps`, so BusyBox is enough and Alpine consumers need no procps.

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
| `read_json_file`          | Read one JSON document from a file. Prints it; returns 1 on a missing file or one that is not exactly one JSON document. |

Configured by environment variable before sourcing:

| Variable | Default | Meaning |
|-----------------------|---------------|---------------------------------------------------------|
| `MCP_TOOLS_LIST_FILE` | `tools.json`  | The tools the server advertises, and their schemas.     |
| `MCP_CONFIG_FILE`     | `config.json` | `protocolVersion`, `serverInfo`, `capabilities`.        |
| `MCP_LOG_FILE`        | `/dev/null`   | Where `log` writes.                                     |
| `MCP_EXTRA_LOG_FILE`  | unset         | Second log target; `PROJECT_ROOT` resolves a relative path. |
| `MCP_LOG_STDERR`      | `0`           | Set to `1` to also mirror each log line to stderr.       |

A missing or unparseable `MCP_CONFIG_FILE` or `MCP_TOOLS_LIST_FILE` is not read as an empty configuration. `initialize` and `tools/list` answer `-32603` naming the file they could not read, and a `tools/call` whose tools list cannot be read is rejected with an `isError` result instead of being dispatched unvalidated. Both files are effectively required.

Methods handled: `initialize`, `tools/list`, `tools/call` and `ping`; the notifications `notifications/initialized` and `notifications/cancelled`. A request for any other method returns `-32601`; a notification for one is logged and ignored.

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

The hook is resolved by name, so a tool whose own name ends in `_cancel` is also the cancellation hook of whatever precedes that suffix: a tool named `foo_cancel` is dispatched as a tool and is called when `foo` is cancelled. Do not name a tool `<other>_cancel` unless that is what you mean.

Every `inputSchema` in `tools.json` is enforced before the tool function runs — `required`, `additionalProperties: false`, `type`, `pattern`, `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`, array `items.type` / `items.enum`, and `enum`. A `type` — on a property or on `items` — may be one name or a list of alternatives (e.g. `"type": ["integer", "string"]`). A value satisfies it by matching any member. A range bound applies only to a number-valued argument — a string, boolean, or other non-number carries no bound — and a bound that is not itself a number is left unenforced, which also covers the JSON Schema draft-04 boolean form `"exclusiveMinimum": true`. Diagnostics report the most fundamental defect first, in that order. A tool with no `inputSchema` is dispatched unvalidated.

A tool that exits non-zero returns its combined output as an `isError` result rather than killing the server.

> [!IMPORTANT]
> Stdout is the protocol channel. A tool function's stdout becomes the tool result, so everything else a server wants to say goes through `log`. A stray `echo` outside a tool corrupts the stream.

Two properties of tool dispatch to write against:

- A tool function always runs with errexit disabled, on every dispatch path — under `run_mcp_server` and from a direct call to `process_request` or `handle_tools_call` alike. A failing step does not end the tool. Check each step's status yourself and return non-zero to produce the `isError` result.
- A tool function's stdin is `/dev/null`. A read returns EOF instead of blocking on the server's protocol stream or consuming bytes meant for it.

### Cancelling and shutting down

A client cancels an in-flight call by sending `notifications/cancelled` with the request's id in `params.requestId`. The server stops the tool's process group — `SIGTERM`, then `SIGKILL` for whatever is left of it — and sends no response for that id. A cancellation that names nothing in flight is logged and dropped. A tool that dies on the `SIGTERM` is reaped at once rather than after the two-second grace: the sentinel that guards the group outlives the tool by design, so it is not counted as a live member when the grace is measured. The grace is measured against a full `ps` listing of the group's members; when `ps` cannot answer, the group's raw liveness is the measure, which counts the sentinel, and such a cancellation waits the full grace.

The tool's process group is the containment boundary. Anything the tool leaves running in it — a background child it never waits for — is killed when the call ends, on success as much as on cancellation. A tool that must outlive the call has to leave the group itself by detaching into a new session. Bash offers no builtin for that and macOS ships no `setsid(1)`, so such a tool needs its own double-fork.

A tool may define an optional `tool_<name>_cancel` hook. It runs with the call's original `arguments` JSON as its one argument, and with an empty string when a signal tears the server down, because the in-flight record holds the tool's group and name and no arguments. A hook that runs longer than two seconds is killed, and its exit status is logged rather than failing the call. The hook runs before the group is signalled, and each of the two steps gets its own two seconds, so a wedged hook followed by a group that ignores `SIGTERM` holds a cancellation for about four seconds before the final `SIGKILL`.

`run_mcp_server` installs `EXIT`, `INT`, `TERM`, `HUP` and `PIPE` traps, replacing any handler a consumer set on those signals. A signal to the server's whole process group takes effect at once, while one sent to the server's pid alone mid-call takes effect after that call returns and lets it finish. Both shapes stop the tool group before the server exits, and a signal that arrives while a teardown is already running does not cut it short: that pass finishes, and the shell then dies by the signal.

A call that finishes that way may go unanswered. Bash runs a trap between commands, so the trap fires as soon as the dispatch returns — the response the dispatch built is still in a variable at that point, and the shell dies before the loop echoes it. Kill the process group to stop a call and still see its result; signal the pid alone to stop the server, and expect a call in flight to go unanswered.

Bash cannot install a handler for a signal that was ignored when the shell started, and a non-interactive shell's plain `&` hands the background job `SIGINT` and `SIGQUIT` already ignored. A server backgrounded that way with job control off therefore has no `INT` trap at all; the `TERM` and `HUP` traps install normally.

A sentinel in the tool's process group covers a server killed with `SIGKILL`, which can run no trap: it waits on a pipe the server holds open, and kills that group once the last process holding the pipe is gone. It ignores `SIGTERM`, so the group `TERM` a cancellation sends leaves it in place and the group's final `SIGKILL` is what reaps it — a server killed before that `SIGKILL` lands is still covered, a tool that is itself ignoring `SIGTERM` included (the grace then runs its full two seconds). That kill runs no cleanup, so small files under `TMPDIR` (default `/tmp`) can be left behind — the in-flight record (`mcp-inflight.*`), the lifeline directory (`mcp-lifeline.*`), an in-flight call's output file (`mcp-tool-output.*`) with the sentinel pid recorded beside it (`mcp-sentinel.*`), and the partial-line handoff file (`mcp-partial.*`). A server that goes down on a signal it can trap removes the in-flight call's output file as part of its teardown.

A client that closes stdin mid-call still gets that call's response: the server finishes the call, answers it, and then exits. Requests that arrived during the call are answered after it, in order. A fragment left by that EOF is discarded, and only its length reaches the log — unless the bytes already parse as JSON, which is a request the client finished writing without a trailing newline, and which is answered like any other line. A line the client had begun but left incomplete when the call ends is carried out of the dispatch through a file and joined to the next line the read loop takes in, so the call's response reaches the client as soon as the dispatch returns rather than waiting on that line. The request the completed line forms is answered behind the response already sent; a client that never finishes the line delays only the next request, exactly as one that stalls between requests. If the client closes stdin while such a line is still open, the joined fragment is answerable on the same terms: it is answered when it parses as JSON, and discarded with only its length logged when it does not.

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

Or run it in containers, which need Docker:

```bash
./scripts/test-linux.sh            # ShellCheck, then Debian and Alpine
./scripts/test-linux.sh debian     # one distro: no ShellCheck
```

Set `BASE_IMAGE_DEBIAN` or `BASE_IMAGE_ALPINE` to override that build's base image; set `JQ_VERSION` to install that upstream static jq release instead of the distro package.

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

This SDK targets servers that ship inside agent plugins, such as Claude Code or Codex distributions, where Bash and jq are the only client-side requirements. Such a server runs next to a local coding agent, and that setting decides both features.

Resources duplicate what the agent already has. The agent reads local files itself, and any data the server can reach (a database schema, an API response) a tool returns on demand, parameterized and fresh after every change. An attached resource is a snapshot the model cannot refresh mid-task.

Prompts carry workflows to clients you do not control. A plugin has its own commands and skills for that, versioned next to the server. A server meant for broad distribution to arbitrary clients is the use case for an official SDK in a general-purpose language, not for this one.

## ⚖️ License

[MIT](./LICENSE)
