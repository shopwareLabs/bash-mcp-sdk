# Architecture

This document owns the cross-function runtime design of `lib/mcpserver_core.sh`. It covers the path of one request, the containment of a tool call, cancellation, shutdown, and the partial-line handoff.

`README.md` owns the consumer contract: writing a tool function, the cancel hook's contract, the environment-variable table, the `inputSchema` keywords, install and vendoring. The compatibility contract and the stdout discipline live in `AGENTS.md`. This document points at `AGENTS.md` §Compatibility contract and `AGENTS.md` §Stdout discipline rather than restating either.

## Request lifecycle

`run_mcp_server` owns the client's stdin. Each iteration reads one line, runs `process_request` in a command substitution, and prints a non-empty result. That substitution is a subshell, so no variable a dispatch sets reaches the loop. State that has to cross the boundary travels through files.

`process_request` closes its inherited lifeline descriptor first (§The lifeline). Four gates then run in a fixed order, ahead of any dispatch.

| Gate | What it tests | Answer when it fails |
|---|---|---|
| Parse | `jq -cs 'length'` over the line, which must be `1` | `-32700 Parse error`, null id |
| Object | the document's `type` is `object` | `-32600 Invalid Request`, null id |
| Version | `.jsonrpc` equals `2.0` | `-32600`, reflecting a valid id and null otherwise |
| Id type | the id is a JSON string or an integer | `-32600`, null id |

The parse gate refuses two different lines. A line jq cannot read fails the substitution. A line holding more than one document yields a count other than `1`. Each answers `-32700` with its own message.

`process_request` reads the id with `has("id")` and `tojson`, never with `//`. That operator maps an absent key and a present `null` to one output, which makes `"id": null` indistinguishable from a notification. `tojson` keeps the id's JSON type, so `7` stays an integer and `"7"` a string. An absent key leaves an empty string, which is the sentinel the notification gate reads.

The id-type gate accepts a JSON string, and a number that is whole in two readings. `floor` converts its input to an IEEE-754 double, and at or above 2^52 the double spacing reaches 1. A literal such as `4503599627370496.5` is therefore already whole as a double, and `floor` alone cannot see its fraction. `tojson` renders the number from the literal jq parsed, which still carries it.

`validate_tool_arguments` holds the same test for a declared `integer`. One gap survives both copies: a rendering that keeps an exponent falls back to the double-based verdict, so `1.5e-400` reads as an integer.

The notification arm sits between the version gate and the id-type gate. An empty id means the key was absent, so the message is a notification and none of the arms emits a response.

A `notifications/cancelled` that arrives here matches no call, because nothing is in flight between requests. `process_request` logs it and drops it. The cancellation that reaches a running call is read elsewhere (§Cancellation).

A valid id then routes by method. `initialize`, `tools/list` and `tools/call` go to their handlers, `ping` answers an empty result object, and any other method answers `-32601`.

## Tool containment

`handle_tools_call` gates its `params` to an object before it reads `.name` and `.arguments`, so neither extraction can fail on a non-object. A tool name that does not match `^[a-zA-Z_][a-zA-Z0-9_]*$` answers `-32602`. A name with no `tool_<name>` function answers `-32601`. `.arguments` is read with `has("arguments")`, so a present `null` or `false` reaches the validator instead of defaulting to `{}`.

The tool then runs in the background under `set -m`, which gives the job its own process group. `handle_tools_call` saves the shell's `monitor` setting and restores it after the spawn. The job is a wrapper subshell rather than the tool itself. That lets a second process sit in the tool's group and outlive the tool without outliving the group.

The wrapper redirects to the call's output file, merges stderr into it, and takes its stdin from `/dev/null`. An inherited stdin would be the client's JSON-RPC stream, and a tool reading it would consume protocol bytes. The wrapper inherits no lifeline descriptor either, because `process_request` closed the dispatch subshell's copy on the way in. Both the wrapper and the sentinel open the lifeline FIFO by path, read-only.

The process group is the containment boundary.

| Member | Enters the group | Leaves it |
|---|---|---|
| The wrapper subshell | `set -m` makes it the leader, and its pid is the group id | Exits when the tool function returns |
| The tool function | Runs inside the wrapper | Exits with the wrapper |
| The lifeline sentinel | The wrapper starts it before the tool | Waits on the lifeline, so it outlives the tool; the group SIGKILL reaps it |
| Anything the tool started and did not wait for | Inherits the group | The group SIGKILL reaps it |

`_kill_tool_group` runs after the wrapper is reaped and clears whatever is left. It signals only a group that still holds a live member, because an emptied group id can already belong to something else.

`_reset_tool_dispatch_state` runs inside the wrapper, immediately before the tool. It clears `_MCP_IN_SERVER_LOOP` and unsets the three file variables. A tool is free to call `process_request` or `handle_tools_call` for a nested dispatch of its own.

Without that reset, the nested dispatch would poll the tool's `/dev/null` stdin. It would read the instant EOF as a client closing the stream and set the shutdown flag. That stops the server as soon as the outer call returns. Only the wrapper subshell's copies change, so the outer call keeps its own state and its own in-flight record.

## The lifeline

No trap can cover a server killed with `SIGKILL`, or a shell that died with its dispatch in flight. The containment for that case is a file descriptor rather than a handler. `run_mcp_server` creates a FIFO in a temporary directory and opens it read-write. It never writes to it, and the read-write open never blocks.

Every dispatch subshell closes its inherited copy before a wrapper starts, so the main server shell is the only writer. `_lifeline_sentinel` blocks on a read of that FIFO. The read returns EOF exactly when the last server process holding the descriptor is gone. The sentinel then SIGKILLs the tool's process group.

Nothing is ever expected to arrive on that read. A byte would end the wait early and kill the group while the server is still alive. The only writer in this design never writes.

The wrapper opens its own reader before it starts the tool. A read-only open of a FIFO blocks until a writer exists, so a wrapper that reaches the lifeline after the server is already gone blocks there instead of starting its tool. No tool runs orphaned.

The sentinel takes its group id from a `ps` listing rather than from `$$`. Every subshell inherits the main shell's `$$`, and the sentinel shares the group of the wrapper that started it. Neither `$$` nor its own pid names the group it has to kill. It scans a full `ps -A -o` listing for its own `BASHPID`, because BusyBox `ps` has no `-p` selection.

The sentinel ignores `TERM`, `INT` and `HUP`. A cancellation TERMs the tool's whole group. A sentinel that died there would leave a TERM-immune tool group with nothing to kill it once the server itself is gone. The group SIGKILL that ends a cancellation reaps the sentinel with everything else.

## The in-flight record

The main shell cannot see into the command substitution a dispatch runs in. A signal trap therefore finds a running call through a file rather than a variable. `handle_tools_call` writes one line of three space-separated fields, `<pgid> <tool_name> <output_file>`. The output file's path exists nowhere else once the dispatch is gone.

The record is written after the spawn, and it is best effort. A teardown that lands in that gap finds nothing and leaves the call to the lifeline sentinel, which needs no record. The cost is that the trap path cannot name the tool there, so it skips the cancel hook. A caller driving `handle_tools_call` directly records nothing at all.

`_kill_tool_group` rewrites the record as its tombstone, and writes it before it empties the group.

| Field | Running call | Tombstone |
|---|---|---|
| pgid | the wrapper's pid, which is the group id it leads | `-` |
| tool name | the call's tool | unchanged |
| output file | the file the call's output is collected in | unchanged |

A pgid that an emptied group once held can be handed to another process group. A teardown reading a numeric id there would TERM and KILL a group that has nothing to do with this call. The tombstone takes that id out of the record while keeping the tool name and the output path, which a truncation would lose.

`_server_teardown` reads the pgid field first. A `-` means signal nothing, run no cancel hook, poll no grace, and release only the two named files. A numeric field means a call is still running.

The sentinel pid file is not in the record. `_sentinel_pid_file` derives it from the output file's path, since that path is the only handle a shutdown teardown has on the call.

## Cancellation

`_await_tool_call` polls the client's stdin while the tool child runs, with a 0.05-second read timeout. It tests every complete line against one jq program. A match needs `jsonrpc` `2.0`, no `id` key, the method `notifications/cancelled`, and a `params.requestId` equal to the in-flight id. The ids are compared as JSON values, so `1` does not match `"1"`.

The `requestId` presence guard precedes the comparison. An absent `requestId` reads as `null`, and a null in-flight id would then equal it and cancel an unrelated call.

A match runs `_teardown_tool_call` and returns without a response for that id. Every other line is queued verbatim and replayed through `process_request` after the call is answered.

`_teardown_tool_call` runs the cancel hook first, then signals. It TERMs the group, polls for a live member, and SIGKILLs whatever is still there when the grace runs out. The grace is 2 seconds, and `_run_cancel_hook` gets its own 2 seconds before the hook is abandoned. A wedged hook followed by a TERM-immune group therefore holds a cancellation about four seconds.

`_tool_group_has_live_member` decides when the grace loop ends. It reads a full `ps -A -o pgid=,pid=` listing and filters it in bash. Neither `pgrep -g` nor a `ps` selection flag can serve: BusyBox ships both binaries without group selection, and its usage error exits 1. That is the same status that means "no members", so a selecting call cannot tell an emptied group from a probe that never ran.

The sentinel is left out of that count. It waits on the lifeline rather than on the tool and ignores TERM, so counting it would hold every cancellation open for the full grace. A tool that dies on the first TERM is reaped at once instead.

A `ps` that fails is unknown liveness, not an empty group. The unknown case degrades to `kill -0` on the whole group, which counts the sentinel and costs the full grace. Read as empty it would end the grace loop immediately and skip the SIGKILL, leaving a TERM-immune tool alive. The degraded path delays a kill rather than dropping one.

`_run_cancel_hook` returns at once when the consumer defined no `tool_<name>_cancel`. Otherwise it runs the hook in a background group of its own, with stdin `/dev/null` and its output discarded. A hook still alive after the grace is SIGKILLed by group, and the kill is logged. A hook that exits non-zero is logged too, and neither outcome fails the call.

No tombstone is written for the hook's group. The record names the call's group, which is still live at that point and has to stay named.

## Shutdown

`run_mcp_server` installs `EXIT`, `INT`, `TERM`, `HUP` and `PIPE` traps. The four signal traps replace any handler already in place, and run `_mcp_teardown_on_signal` with the signal's own name. `EXIT` runs `_server_teardown`, which chains in the handler the caller had installed there rather than dropping it.

That handler is captured in `run_mcp_server`, immediately before the traps are installed, and only where `BASHPID` equals `$$`. The direct call is the only shape that captures: a caller that isolates the call in a subshell keeps its handler in the parent, and chaining it from the subshell would run it in both shells. The capture takes `trap -p EXIT` from a command substitution: a bash subshell inherits the parent's trap table, so `trap -p` reports the parent's handler until the subshell itself changes a trap, and the handler does not run there. The line comes back in re-input form, `trap -- '<handler>' EXIT`, so `eval "set -- ..."` recovers the handler as its third word. A shell that had installed no handler captures nothing; under `set -o posix` an unset trap reports `trap -- - EXIT`, whose `-` is not a handler, and that too stores nothing. A bash that someday resets subshell traps the way POSIX describes would make the capture come back empty — a handler missed, never one fired twice.

`_server_teardown` runs the stored handler after it has released the SDK's own files, and before it re-raises a signal a trap recorded. That is the one point both routes into the function reach with the cleanup done and the shell still alive: the end of the loop, and a trap. The pass is still marked in progress there, so a signal landing inside the handler is recorded rather than starting a second pass over the teardown. The handler runs in a background process group under the same grace a cancel hook gets, because bash defers a trapped signal until a foreground subshell finishes, so a handler that blocked would stall shutdown: the teardown polls `_MCP_CANCEL_GRACE_SECONDS`, then kills the group and logs the overrun. The group keeps a handler's variable assignments out of the teardown shell, and errexit is off inside it, so the handler checks each step's status itself. Its stdout goes to stderr, which is off the JSON-RPC stream, and its stdin is `/dev/null` rather than the client's stream, so a handler that read cannot consume protocol bytes. A handler that fails is logged and nothing else: a caller's broken cleanup cannot abort the pass or change the server's exit status. The stored handler is cleared after the one run: on a clean exit the loop's own teardown is that run, and the clearing is what keeps the `EXIT` trap's later pass from repeating it.

`_server_teardown` is idempotent, because every step is a no-op once its subject is gone. A `_MCP_TEARDOWN_RUNNING` flag keeps a second entry out while a pass is running. The flag is cleared on the way out, so a shell that runs a second server still tears that one down.

A pass stops the in-flight call, then releases files, then drops the lifeline. It removes the call's output file and sentinel pid file, the in-flight record, the shutdown flag, and the partial-line file. It closes the lifeline descriptor and removes the lifeline directory; dropping the last writer is what releases a sentinel still waiting. Each variable is cleared with the file it names, so a second pass cannot remove a path the shell has since given to something else.

A signal that arrives mid-pass is recorded rather than re-raised. `_mcp_teardown_on_signal` stores it in `_MCP_PENDING_SIGNAL` and returns. Re-raising there would end the shell before the pass reached its SIGKILL and its file removals. The finishing pass restores the signal's default disposition and re-raises it against `BASHPID`, so the shell still dies by the signal.

That re-raise runs at the end of every pass, whether or not a signal trap drove it. A signal recorded during a teardown from the `EXIT` trap, or from the end of the read loop, is the signal the shell then dies by.

Bash runs a trap only between foreground commands, and that sets the two signal shapes apart. A signal to the server's pid alone during a dispatch takes effect when that dispatch returns. The in-flight call finishes first, and the teardown then finds the tool already reaped.

A signal to the whole process group kills the dispatch subshell at once. The command substitution returns, and the trap reaps a tool group that is still alive.

A server killed with `SIGKILL` runs no teardown, so its temporary files stay under `TMPDIR`. Those are the in-flight record (`mcp-inflight.*`), the lifeline directory (`mcp-lifeline.*`), a running call's output file (`mcp-tool-output.*`) and sentinel pid file (`mcp-sentinel.*`), and the partial-line file (`mcp-partial.*`). The lifeline sentinel still kills the tool group; only the files are left behind.

## Partial-line handoff

A tool call can end while the client is halfway through writing the next line. `_await_tool_call` holds that fragment in a buffer and must not finish reading it. Completing the line there would hold back the response the call has already earned. The fragment leaves the dispatch through `_MCP_PARTIAL_FILE` instead, written with no trailing newline.

`run_mcp_server` reads that file after it has printed the dispatch's response, then truncates it. The file's content is the signal, not its existence. The next iteration joins the fragment to the front of the line it reads.

A fragment joins only a line whose read succeeded. A failed read leaves whatever it stored unterminated, so joining there would answer a line the client never finished writing. The EOF branch is the exception, and it tells the two cases apart by parsing the joined bytes.

The parse test is `jq empty`, not `jq -e '.'`. `jq -e` takes its exit status from the truthiness of its output. A fragment of `false` or `null` then read as a parse failure and was dropped.

`jq empty` exits zero on any input jq can read, including input that holds no document at all. A whitespace-only fragment therefore passes this gate and is answered `-32700`, which is the answer those same bytes get with a newline after them.

`_await_tool_call`'s EOF branch joins the buffer to the bytes the last read stored. A joined fragment that parses is the client's last request, written without a trailing newline that can now never arrive. It is handled like any other line. A fragment that does not parse is dropped, and only its length is logged, because the content is the client's.

The branch also sets `_MCP_EOF_DRAIN`. `handle_tools_call` then touches the shutdown flag, once the response and the deferred lines are written.

## Invariant index

| Invariant | Enforced by | Mechanism |
|---|---|---|
| One JSON-RPC line yields at most one response | `process_request` | §Request lifecycle |
| A notification never produces a response | `process_request` | §Request lifecycle |
| A request id is echoed back only when it is a string or an integer | `process_request` | §Request lifecycle |
| A tool function never reads the client's protocol stream | `handle_tools_call` | §Tool containment |
| A tool leaves nothing running once its call ends | `_kill_tool_group` | §Tool containment |
| A nested dispatch inside a tool cannot stop the server or overwrite the outer call's record | `_reset_tool_dispatch_state` | §Tool containment |
| A tool group dies even when the server could run no trap | `_lifeline_sentinel` | §The lifeline |
| A process group is signalled only while it still holds a live member | `_kill_tool_group`, `_tool_group_has_live_member` | §The in-flight record |
| A cancelled call gets no response for its id | `_await_tool_call` | §Cancellation |
| A cancellation stops only the call whose id it names | `_await_tool_call` | §Cancellation |
| A wedged tool or cancel hook cannot wedge the server | `_teardown_tool_call`, `_run_cancel_hook` | §Cancellation |
| A teardown pass runs alone and always finishes | `_server_teardown` | §Shutdown |
| A server that goes down on a trappable signal dies by that signal | `_mcp_teardown_on_signal` | §Shutdown |
| A line the client wrote in pieces is dispatched as the client wrote it | `_await_tool_call`, `run_mcp_server` | §Partial-line handoff |
