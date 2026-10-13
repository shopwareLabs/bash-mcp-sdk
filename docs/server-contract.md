# Server contract

This document owns the consumer contract of `lib/mcpserver_core.sh`: what a server script can rely on, and what it has to do in return. `README.md` owns installation, the API and configuration tables, the minimal server and the vendoring recipe. The runtime mechanism behind each contract is in `docs/architecture.md`.

## Dependencies and PATH

`ps` and `mkfifo` go unchecked. A host that lacks either fails later instead: `mkfifo` at startup, `ps` at the first tool call.

The floors in `README.md` §Requirements are checked when the file is sourced. `PATH` therefore has to be right at that point: after sourcing, a `PATH` fix is too late. In a server script, export the new directory above the `source` line:

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

## Configuration files and protocol handling

A missing or unparseable `MCP_CONFIG_FILE` or `MCP_TOOLS_LIST_FILE` is not read as an empty configuration; both files are effectively required. `initialize` and `tools/list` answer `-32603`, naming the file they could not read. That covers a file whose single document is not a JSON object. A `tools/call` whose tools list cannot be read is rejected with an `isError` result instead of being dispatched unvalidated.

A message whose `id` is present but is not a string or an integer is neither a request nor a notification. MCP requires a request id to be a string or an integer, and a notification carries no id. Such a message is answered `-32600` rather than dropped.

A request must be a single JSON object on a line of its own. A line that holds more than one JSON document, or that is not parseable JSON, is answered `-32700 Parse error` and not dispatched. A document that is valid JSON but not an object is answered `-32600` with a null `id`. That covers `[1,2]`, `"x"`, `5`, `true`, `false` and `null`.

A request whose `method` is absent or is not a string is answered `-32600 Invalid Request: method must be a string`, echoing its `id`. A request whose `id` is also invalid gets the `id` answer above instead. A notification whose `method` is absent or not a string gets no response; the server logs it and drops it.

Only an absent `params` is read as `{}`. A present `params` reaches the method's handler as sent, so a `tools/call` whose `params` is `null`, `false` or any other non-object is answered `-32602 Invalid params: expected an object`. A `tools/call` whose `name` is absent or is not a string is answered `-32602 Invalid params: name must be a string`. A string `name` that is not an identifier is answered `-32602 Invalid tool name: <name>`.

## Tool functions

`tools.json` decides which tools exist. A `tools/call` runs `tool_<name>` only when the list declares `<name>` and a shell function of that name is defined. A name the list does not declare answers `-32601`, even when a `tool_<name>` function is sourced. A declared name with no such function answers `-32601` too. An executable, alias or builtin named `tool_<name>` is never dispatched.

The same rule holds for a nested `handle_tools_call` or `process_request` made from inside a tool. A plain shell call such as `tool_greet "$args"` (the tool in `README.md` §Writing a server) is not a dispatch, so it runs whether or not the list declares the tool.

A tool may also define an optional `tool_<name>_cancel` hook, which the server calls when the call is cancelled. *Cancelling and shutting down* below gives its contract.

The hook is resolved by name, and only a shell function counts. A hook is not a tool: `tool_foo_cancel` is callable as tool `foo_cancel` only when `tools.json` declares `foo_cancel`. A declared tool named `foo_cancel` is still the cancellation hook of `foo`, and it is called when `foo` is cancelled. Do not declare a tool `<other>_cancel` unless that is what you mean.

Every `inputSchema` in `tools.json` is enforced before the tool function runs. The keywords are `required`, `properties`, `additionalProperties`, `type`, `pattern`, `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`, `items`, `enum`, and `oneOf`.

Each of these keywords must hold a value of its own type. `type` is a string or a non-empty array of strings. The four bounds are numbers. `pattern` is a string that compiles as a regular expression. `required` is an array of strings. `enum` is an array. `properties` is an object whose values are objects. `items` is an object. `additionalProperties` is a boolean or an object. `oneOf` is an array of objects. The `inputSchema` itself is an object. A present `null` counts as the wrong type, and so does `false` for every keyword except `additionalProperties`. A schema holding a keyword of the wrong type is not dispatched: the call returns an `isError` result, `Cannot validate arguments for <tool>: its inputSchema keyword(s) have the wrong type: <path> must be <shape>.`, naming each wrong-typed keyword the check reaches, for example `properties.x.required must be an array of strings`.

The check tests each keyword's JSON type, and that a `pattern` compiles, not whether any value can satisfy the schema. A `type` that names no JSON Schema type, such as `"int"`, an empty `enum` and an empty `oneOf` pass it. The validator then rejects every value given at that position as an argument error. A call that omits an optional property of that kind still runs the tool.

These keywords apply inside nested schemas too: a property's own schema, a schema given as `additionalProperties`, `items`, and each `oneOf` branch. `additionalProperties: false` rejects undeclared properties. A schema there checks each undeclared property's value. A nested defect names its path, such as `options.limit` or `tags[1]`.

A value satisfies `oneOf` when it passes exactly one branch. Matching no branch, or more than one, is a defect. Keywords next to `oneOf` are still checked.

The annotation keywords `title`, `description`, `default`, `examples`, `format`, `$schema`, `$id`, `$comment`, `deprecated`, `readOnly` and `writeOnly` are accepted and not checked. A schema using any other keyword, `minLength` or `anyOf` for example, is not dispatched. The call returns an `isError` result naming the path of each such keyword.

A `type` — on a property or on `items` — may be one name or a list of alternatives (e.g. `"type": ["integer", "string"]`). A value satisfies it by matching any member.

A range bound applies only to a number-valued argument. A string, boolean, or other non-number carries no bound. Only the numeric form of `exclusiveMinimum` and `exclusiveMaximum` is enforced. The JSON Schema draft-04 boolean form `"exclusiveMinimum": true` is a keyword of the wrong type.

Diagnostics report one class of defect, the first in this order that occurs anywhere in the arguments: missing parameter, unknown parameter, type, pattern, range, array item type or enum, enum, `oneOf`. Every defect of that class is listed.

A declared tool whose entry has no `inputSchema`, or a `null` one, is not dispatched. The call returns an `isError` result instead. A name `tools.json` declares more than once also returns an `isError` result.

A tool that exits non-zero returns its combined output as an `isError` result rather than killing the server.

Tool output that is not valid UTF-8 comes back with replacement characters, and can lose a byte that follows an invalid one.

> [!IMPORTANT]
> Stdout is the protocol channel. Sourcing the core keeps a private copy of the server's stdout, which `run_mcp_server` writes each response to, and points fd 1 at stderr. Output the server script writes to fd 1 after the `source` line goes to stderr. Output written before the `source` line still reaches the stream and corrupts it. A tool function's stdout becomes the tool result, so everything else a server wants to say goes through `log`. `log` writes each message as one line, with a newline or carriage return written as `\n` or `\r`, and a log file it cannot write leaves the server running with a note on stderr. A server that prints a response itself, such as the result of `create_response` or `create_error_response`, no longer reaches the client: the line goes to stderr.

Four properties of tool dispatch to write against:

- A tool function always runs with errexit disabled, on every dispatch path. That holds under `run_mcp_server` and from a direct call to `process_request` or `handle_tools_call` alike. A failing step does not end the tool. Check each step's status yourself and return non-zero to produce the `isError` result.
- A tool function runs with job control (`monitor`) off, so the commands it starts stay in the call's process group. Do not turn it on: under `set -m` each job gets a process group of its own, which cancellation and the end of the call do not reach.
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

## Running a step before every tool

Tools that share a per-call step, such as an authorization check, an audit line or a change of working directory, can define it once as `mcp_before_tool_call`. When a shell function of that name exists, every dispatched `tools/call` runs it before the tool function. An executable or alias of that name is never run.

It receives the tool name as `$1` and the call's `arguments` JSON as `$2`, exactly as the tool function receives it. It runs only for a call that passed the tools-list check and argument validation, so an undeclared tool or rejected arguments never reach it.

The hook and the tool function run in one shell, the call's own subshell. A global variable the hook assigns, an exported variable, a function it defines and a directory it changes to are what the tool sees. A variable the hook assigns does not change which tool function runs, the arguments it receives, or how the call is reported. The two also share one `EXIT` trap, so a `trap … EXIT` in the tool replaces one the hook installed. A function the hook defines reaches the tool function but not the SDK's own steps after the hook. Those steps use only `builtin`-prefixed shell builtins and plain redirections, so a function the hook defines and a `PATH` it changes do not affect them. A hook must not define a function named `builtin`: the SDK's steps call `builtin` by that name and would run the hook's function instead.

Shell options are the exception. Whatever the hook sets with `set` or `shopt` is put back once it returns, so the tool runs with the options it would have had without the hook, `errtrace` included. The server's `ERR` trap does not run inside the hook, and runs in the tool as it would without a hook. With `errtrace` on in the server script, an `ERR` trap the hook installs runs in the tool in place of the server's. With `errtrace` off, the tool does not run it.

A hook may turn on `set -euo pipefail` for its own body. A failing command that errexit acts on then stops the hook and ends the call, and that includes a failing last command: a hook ending in `[[ $1 == allowed ]]` is answered as a hook that ended the call, not as a refusal. A hook that returns non-zero any other way is answered as a refusal: through `return` with a non-zero status, or through a last command whose failure errexit does not act on, such as `[[ $1 == allowed ]] && true`. The exception is a hook that installed an `ERR` trap of its own (see below). The tool runs with errexit off either way.

A hook that returns 0 lets the tool run, and its stdout and stderr are discarded. A hook that returns non-zero stops the call. The tool does not run, and the call returns an `isError` result whose text is the hook's combined output, prefixed `Error executing <name>: ` as for a failing tool. The log records it as `before-tool hook refused tool <name> (status N)`, not as a tool failure.

Write the hook with `return`, not `exit`. An `exit` ends the call's shell instead of returning to it, so the tool does not run whatever status the hook exits with. The call returns an `isError` result that names the hook, followed — when the hook printed anything — by what it printed. `exit 0` gets that result too, rather than an empty success. A hook stopped by the errexit or nounset it turned on gets the same result. A hook that ends with a status above 128 gets a result naming that status and the signal it may stand for, `mcp_before_tool_call ended with status 141 before returning (signal 13, or a command that failed with that status)`, followed by what the hook printed. On Bash 4.4 and 5.3, errexit ends a hook with the status of the command it stopped at, so a hook killed by signal 13 and one stopped at a command that failed with 141 end alike, and the result cannot tell them apart. Bash 4.1 to 4.3 end a hook stopped by errexit with status 1. Each of these cases is logged at `ERROR`.

Bash ignores errexit inside a function called from an `if` condition, a `||` or `&&` list, or a `!` command. Called from such a context, `process_request` or `handle_tools_call` runs a hook whose errexit has no effect, so the hook runs past a failing command. BATS `run` is one such context. `run_mcp_server` calls `process_request` as a plain statement, so a call that comes in over the server loop honors the hook's errexit when the server script calls `run_mcp_server` as a plain statement too. A script that calls it as `run_mcp_server || exit 1` or `if ! run_mcp_server` puts the whole server loop in such a context, and the hook's errexit has no effect.

A hook that installs its own `ERR` trap and then returns non-zero with errexit on is answered as a hook that ended the call, not as a refusal. With errexit off, that trap also runs once where the SDK calls the hook when the hook returns non-zero, and what it prints appears in the refusal text. Both hold with `errtrace` on in the server script. With `errtrace` off, Bash 4.1 to 4.3 discard an `ERR` trap a function installs when the function returns, so on those versions the hook is answered as a refusal and the trap does not run.

The hook runs under the same dispatch properties as a tool function: errexit off, job control (`monitor`) off, stdin `/dev/null`, and inside the call's process group, so a cancellation stops a hook that blocks. A nested `handle_tools_call` or `process_request` made from inside a tool runs the hook again for the inner call.

## Per-call files

Each dispatched call gets a directory of its own, exported as `MCP_CALL_TMPDIR` to the before-tool hook, the tool function and every process the tool starts. It is created empty with mode `700`, and no other call shares it. Its path is absolute even when `TMPDIR` is relative.

It sits in the call's root, a directory `mcp-call.*` under `TMPDIR` (default `/tmp`) with mode `700`. The root also holds the files the server keeps for the call: its collected output and the server's own bookkeeping. They are not part of the contract, and a tool should write only inside `MCP_CALL_TMPDIR`.

The server removes the root, and `MCP_CALL_TMPDIR` with it, once the call's process group has exited or been killed. That happens when the tool returns, when it fails, when the call is cancelled, and when the server shuts down with the call in flight. It covers the `SIGKILL` a tool gets after ignoring `SIGTERM`, which no `EXIT` trap survives, so a file the call keeps there needs no cleanup of its own. A subdirectory the call left read-only, or with no permissions at all, is removed too. A server killed with `SIGKILL` is the exception (*Cancelling and shutting down* below). A removal that fails is logged at `WARN`. It neither ends the server nor changes the call's outcome: a call that gets a response still gets it, and a cancelled call still gets none.

A call whose root or `MCP_CALL_TMPDIR` cannot be created does not run. It returns an `isError` result instead, and the failure is logged at `ERROR`.

A nested dispatch inside a tool gets a directory of its own. Its `MCP_CALL_TMPDIR` applies only inside that inner call.

## Cancelling and shutting down

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

## Keeping the vendored copy current

> [!IMPORTANT]
> Renovate's own `postUpgradeTasks` looks like the natural place for step 4 of `README.md` §Vendoring. The commands it may run are gated by `allowedCommands`, which is self-hosted-only. On the Mend-hosted app the allowed set is undocumented and can change. Drive the re-vendor from CI instead.

## Why resources and prompts are not planned

This SDK targets servers that ship inside agent plugins, such as Claude Code or Codex distributions. In that setting Bash and jq are the only client-side requirements. Such a server runs next to a local coding agent, and that setting decides both features.

Resources duplicate what the agent already has. The agent reads local files itself. Any data the server can reach (a database schema, an API response) a tool returns on demand, parameterized and fresh after every change. An attached resource is a snapshot the model cannot refresh mid-task.

Prompts carry workflows to clients you do not control. A plugin has its own commands and skills for that, versioned next to the server. A server meant for broad distribution to arbitrary clients is the use case for an official SDK in a general-purpose language. It is not the use case for this one.
