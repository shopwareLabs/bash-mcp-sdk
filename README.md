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
| `validate_tool_arguments` | Check a call's arguments against the tool's `inputSchema`. Rejects a tool that the tools list does not declare exactly once with a non-null `inputSchema`. |
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

Defined by the server script and resolved as shell functions only:

| Function | Called |
|---|---|
| `tool_<name>` | For a `tools/call` naming `<name>`, when `tools.json` declares it. Receives the `arguments` JSON. |
| `tool_<name>_cancel` | Optional. When a call of `<name>` is cancelled, or the server shuts down with it in flight. |
| `mcp_before_tool_call` | Optional. Before every dispatched tool, with the tool name and the `arguments` JSON. |

Set by the SDK for a call, not by the consumer:

| Variable | Seen by | Meaning |
|---|---|---|
| `MCP_CALL_TMPDIR` | `mcp_before_tool_call`, the tool function and what it starts, `tool_<name>_cancel` | A directory private to the call, removed when the call ends. See *Per-call files* below. |

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

`tools.json` decides which tools exist. A `tools/call` runs `tool_<name>` only when the list declares `<name>` and a shell function of that name is defined. A name the list does not declare answers `-32601`, even when a `tool_<name>` function is sourced. A declared name with no such function answers `-32601` too. An executable, alias or builtin named `tool_<name>` is never dispatched.

The same rule holds for a nested `handle_tools_call` or `process_request` made from inside a tool. A plain shell call such as `tool_greet "$args"` is not a dispatch, so it runs whether or not the list declares the tool.

A tool may also define an optional `tool_<name>_cancel` hook, which the server calls when the call is cancelled. *Cancelling and shutting down* below gives its contract.

The hook is resolved by name, and only a shell function counts. A hook is not a tool: `tool_foo_cancel` is callable as tool `foo_cancel` only when `tools.json` declares `foo_cancel`. A declared tool named `foo_cancel` is still the cancellation hook of `foo`, and it is called when `foo` is cancelled. Do not declare a tool `<other>_cancel` unless that is what you mean.

Every `inputSchema` in `tools.json` is enforced before the tool function runs. The keywords are `required`, `additionalProperties: false`, `type`, `pattern`, `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`, array `items.type` / `items.enum`, and `enum`.

A `type` — on a property or on `items` — may be one name or a list of alternatives (e.g. `"type": ["integer", "string"]`). A value satisfies it by matching any member.

A range bound applies only to a number-valued argument. A string, boolean, or other non-number carries no bound. A bound that is not itself a number is left unenforced, which also covers the JSON Schema draft-04 boolean form `"exclusiveMinimum": true`.

Diagnostics report the most fundamental defect first, in that order.

A declared tool whose entry has no `inputSchema`, or a `null` one, is not dispatched. The call returns an `isError` result instead. A name `tools.json` declares more than once also returns an `isError` result.

A tool that exits non-zero returns its combined output as an `isError` result rather than killing the server.

> [!IMPORTANT]
> Stdout is the protocol channel. A tool function's stdout becomes the tool result, so everything else a server wants to say goes through `log`. A stray `echo` outside a tool corrupts the stream.

Three properties of tool dispatch to write against:

- A tool function always runs with errexit disabled, on every dispatch path. That holds under `run_mcp_server` and from a direct call to `process_request` or `handle_tools_call` alike. A failing step does not end the tool. Check each step's status yourself and return non-zero to produce the `isError` result.
- A tool function's stdin is `/dev/null`. A read returns EOF instead of blocking on the server's protocol stream or consuming bytes meant for it.
- A tool function may install a `trap … EXIT`. It runs when the tool returns, before the result is built, so anything it prints joins the tool result. It also runs when the `SIGTERM` step of a cancellation or a server shutdown ends the tool. It does not run when the call's process group is killed with `SIGKILL`, which is what a tool that ignores `SIGTERM` gets after the grace. A file that must not outlive the call belongs in `MCP_CALL_TMPDIR` (*Per-call files* below).

A tool cannot leave a value in a variable for a later call to read. Each call runs in its own subshell, so what a tool sets dies with that call (the boundary is in `docs/architecture.md` §Request lifecycle and §Tool containment). State that crosses calls travels through a file.

The server script creates that file above the `source` line and exports its path. Every tool subshell inherits the export, so all tools read and write the same path:

```bash
MYSERVER_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/myserver-state.XXXXXX")"
export MYSERVER_STATE_FILE
```

The name is the server's own, kept out of the library's `MCP_*` namespace.

Inside a tool, `$$` is the server's pid while `BASHPID` is the per-call subshell's pid. A filename keyed on `$$` is therefore shared by every call, and one keyed on `BASHPID` is not. A tool that detaches into a new session outlives its call, so it can still be writing the file while a later call runs.

Removing the file is the server script's job. *Cancelling and shutting down* below gives the traps `run_mcp_server` installs, the subshell the server script uses to keep its own, and what a `SIGKILL` leaves behind.

### Running a step before every tool

Tools that share a per-call step, such as an authorization check, an audit line or a change of working directory, can define it once as `mcp_before_tool_call`. When a shell function of that name exists, every dispatched `tools/call` runs it before the tool function. An executable or alias of that name is never run.

It receives the tool name as `$1` and the call's `arguments` JSON as `$2`, exactly as the tool function receives it. It runs only for a call that passed the tools-list check and argument validation, so an undeclared tool or rejected arguments never reach it.

The hook and the tool function run in one shell, the call's own subshell. A global variable the hook assigns, an exported variable, a function it defines and a directory it changes to are what the tool sees. The two also share one `EXIT` trap, so a `trap … EXIT` in the tool replaces one the hook installed. A function the hook defines reaches the tool function but not the SDK's own steps after the hook. Those steps use only `builtin`-prefixed shell builtins and plain redirections, so a function the hook defines and a `PATH` it changes do not affect them. A hook must not define a function named `builtin`: the SDK's steps call `builtin` by that name and would run the hook's function instead.

Shell options are the exception. Whatever the hook sets with `set` or `shopt` is put back once it returns, so the tool runs with the options it would have had without the hook. A hook may turn on `set -euo pipefail` for its own body, and the tool still runs with errexit off.

A hook that returns 0 lets the tool run, and its stdout and stderr are discarded. A hook that returns non-zero stops the call. The tool does not run, and the call returns an `isError` result whose text is the hook's combined output, prefixed `Error executing <name>: ` as for a failing tool. The log records it as `before-tool hook refused tool <name> (status N)`, not as a tool failure.

Write the hook with `return`, not `exit`. An `exit` ends the call's shell instead of returning to it, so the tool does not run whatever status the hook exits with. The call returns an `isError` result that names the hook, followed — when the hook printed anything — by what it printed. `exit 0` gets that result too, rather than an empty success. A hook killed by a signal also stops the call, and the result names the signal. Both cases are logged at `ERROR`.

The hook runs under the same dispatch properties as a tool function: errexit off, stdin `/dev/null`, and inside the call's process group, so a cancellation stops a hook that blocks. A nested `handle_tools_call` or `process_request` made from inside a tool runs the hook again for the inner call.

### Per-call files

Each dispatched call gets a directory of its own, exported as `MCP_CALL_TMPDIR` to the before-tool hook, the tool function and every process the tool starts. It is created empty with mode `700`, and no other call shares it. Its path is absolute even when `TMPDIR` is relative.

It sits in the call's root, a directory `mcp-call.*` under `TMPDIR` (default `/tmp`) with mode `700`. The root also holds the files the server keeps for the call: its collected output and the server's own bookkeeping. They are not part of the contract, and a tool should write only inside `MCP_CALL_TMPDIR`.

The server removes the root, and `MCP_CALL_TMPDIR` with it, once the call's process group has exited or been killed. That happens when the tool returns, when it fails, when the call is cancelled, and when the server shuts down with the call in flight. It covers the `SIGKILL` a tool gets after ignoring `SIGTERM`, which no `EXIT` trap survives, so a file the call keeps there needs no cleanup of its own. A subdirectory the call left read-only, or with no permissions at all, is removed too. A server killed with `SIGKILL` is the exception (*Cancelling and shutting down* below). A removal that fails is logged at `WARN`. It neither ends the server nor changes the call's outcome: a call that gets a response still gets it, and a cancelled call still gets none.

A call whose root or `MCP_CALL_TMPDIR` cannot be created does not run. It returns an `isError` result instead, and the failure is logged at `ERROR`.

A nested dispatch inside a tool gets a directory of its own. Its `MCP_CALL_TMPDIR` applies only inside that inner call.

### Cancelling and shutting down

A client cancels an in-flight call by sending `notifications/cancelled` with the request's id in `params.requestId`. The server stops the tool's process group with `SIGTERM`, then `SIGKILL` for whatever is left of it, and sends no response for that id. A cancellation that names nothing in flight is logged and dropped. A tool that dies on the `SIGTERM` is reaped at once rather than after the two-second grace (measured as in `docs/architecture.md` §Cancellation).

The tool's process group is the containment boundary. Anything the tool leaves running in it — a background child it never waits for — is killed when the call ends. That holds on success as much as on cancellation (the containment mechanism is in `docs/architecture.md` §Tool containment).

A tool that must outlive the call has to leave the group itself by detaching into a new session. Bash offers no builtin for that and macOS ships no `setsid(1)`, so such a tool needs its own double-fork.

A tool may define an optional `tool_<name>_cancel` hook. It runs with the call's original `arguments` JSON as its one argument. A signal that tears the server down passes an empty string instead: the in-flight record holds the tool's group and name, but no arguments.

The hook gets the call's `MCP_CALL_TMPDIR` on both routes, so it can read what the call recorded there, such as the path of a file the call created or the id of a job it started. The directory still exists while the hook runs.

The hook runs before the group is signalled, and each of the two steps gets its own two seconds. A hook that runs longer than two seconds is killed, and its exit status is logged rather than failing the call. A wedged hook followed by a group that ignores `SIGTERM` therefore holds a cancellation for about four seconds before the final `SIGKILL`.

`run_mcp_server` installs `EXIT`, `INT`, `TERM`, `HUP` and `PIPE` traps. The four signal traps replace any handler a consumer set on those signals, because a signal handler that expects the shell to keep running cannot be honored: the shell has to die by the signal. The `EXIT` trap is the server's own, and a consumer's `EXIT` handler is not lost with it: the server runs that handler as part of its teardown, after its own cleanup, on a clean exit and on a trapped signal alike.

A consumer's `EXIT` handler runs under these rules. Its stdout goes to stderr, because stdout is the protocol channel, and its stdin is `/dev/null` rather than the client's JSON-RPC stream, so a handler that read cannot consume protocol bytes. It runs without errexit, so it checks each step's status itself (the same shape as the tool-function rule above). A failure is logged, and it neither aborts the teardown nor changes the server's exit status. It gets the same two-second grace a cancel hook gets, and one that runs longer is killed and logged. It runs before `run_mcp_server` returns on a clean exit. It may run in a subshell, so it cannot count on a variable it sets or a directory it changes outliving it. And only a handler installed in the shell that calls `run_mcp_server` directly is chained: a trap installed inside a subshell that wraps the whole call, `source` and all, is still replaced and dropped.

`run_mcp_server` expects to be the last call in its process, so a server that needs its own `EXIT` trap afterwards calls it in a subshell. That wrap has a cost: a signal to the parent's pid alone finds no server trap there, so the SDK's teardown inside the subshell never runs for that signal. The parent's own `EXIT` trap still does — bash runs a shell's `EXIT` trap when the shell dies by an untrapped fatal signal, and the exit status still reports that signal. A signal to the process group, or a client that closes stdin, still reaches the server inside the subshell. A signal to the server's whole process group takes effect at once. One sent to the server's pid alone mid-call takes effect after that call returns, and lets it finish.

Both shapes stop the tool group before the server exits. A signal that arrives while a teardown is already running does not cut it short. That pass finishes, and the shell then dies by the signal.

A call that finishes that way may go unanswered. Bash runs a trap between commands, so the trap fires as soon as the dispatch returns (the mechanism is in `docs/architecture.md` §Shutdown). The response the dispatch built is still in a variable at that point, and the shell dies before the loop echoes it.

Kill the process group to stop a call and still see its result. To stop the server instead, signal its pid alone, and expect a call in flight to go unanswered.

Bash cannot install a handler for a signal that was ignored when the shell started. A non-interactive shell's plain `&` hands the background job `SIGINT` and `SIGQUIT` already ignored. A server backgrounded that way with job control off therefore has no `INT` trap at all. The `TERM` and `HUP` traps install normally.

A server killed with `SIGKILL` runs no trap, so a call it had in flight is stopped by the lifeline instead (the lifeline and its sentinel are in `docs/architecture.md` §The lifeline). That kill runs no cleanup, so small files under `TMPDIR` (default `/tmp`) can be left behind, and nothing removes them. The patterns are `mcp-inflight.*`, `mcp-lifeline.*`, `mcp-call.*`, `mcp-partial.*` and `mcp-shutdown.*`, where `mcp-call.*` is a call's root with its `MCP_CALL_TMPDIR` and whatever the call left in it. A server that goes down on a signal it can trap removes the in-flight call's root as part of its teardown.

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
