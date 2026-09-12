# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as scoped by the compatibility contract in `AGENTS.md`.

## [Unreleased]

## [4.0.0] - 2026-09-12

### Added

- `create_error_response` takes an optional fourth `data` argument, a JSON value carried into the error object's `data` field. Omitted or empty, the envelope is unchanged.
- `MCP_LOG_STDERR` (default `0`). Set to `1` and `log` mirrors each formatted line to stderr, on top of its existing file targets. stdout still carries only the JSON-RPC stream.
- `notifications/cancelled` is handled. A cancellation naming an in-flight `tools/call` stops that call, and no response is sent for its id. A cancellation naming nothing in flight is logged and dropped.
- A tool may define an optional `tool_<name>_cancel` hook, which runs when its call is cancelled. It receives the call's original `arguments` JSON, or an empty string when a signal tears the server down and the in-flight record holds the tool's group and name and no arguments. A hook gets two seconds before it is killed; its exit status is logged rather than failing the call.

### Changed

- **Major**: a tool now runs in its own process group, and that group is killed when the call ends. A child the tool leaves running behind it no longer survives the call, on success as much as on cancellation. A tool that must outlive its call has to detach into its own session.
- **Major**: a tool's stdin is `/dev/null`. It previously inherited the server's stdin, the JSON-RPC pipe.
- **Major**: a cancelled call's tool group is stopped with `SIGTERM`, then `SIGKILL` for any member still running two seconds later, and no response is sent for that id. A tool that dies on the `SIGTERM` is reaped at once: the sentinel that guards the group outlives the tool by design, and the grace period is measured against the group's members other than the sentinel. `notifications/cancelled` was previously ignored, so the call ran to completion and its response arrived.
- A tool function runs with errexit disabled on every dispatch path, a direct call to `handle_tools_call` or `process_request` included. This matches 3.0.0 and is not a compatibility change.
- The grace a cancellation measures reads `pgrep` where the system has it. Its exit status is the answer — members, none, or a failure the check cannot use — and a failure falls back to the group's raw liveness, which counts the sentinel the tool shares its group with, so the grace then runs its full two seconds before the `SIGKILL`. That is the slower direction and never drops the kill. `pgrep` is not a new requirement: macOS and standard Linux ship it.
- A signal that arrives while the shutdown teardown is already running is recorded rather than re-raised, so the pass finishes — the cancel hook, the group `SIGKILL`, the removal of the in-flight call's files — and the shell then dies by that signal.
- **Major**: an id-carrying `notifications/initialized` now returns `-32601 Method not found`. The method is handled as the notification its name and its id-less form say it is, so a message carrying an id is an ordinary request for a method the server does not implement. 3.0.0 listed the method in its dispatch table and answered nothing for either form.
- **Major**: `run_mcp_server` installs `EXIT`, `INT`, `TERM`, `HUP` and `PIPE` traps, replacing any handler a consumer set on those signals. A signal to the server's whole process group takes effect at once; one sent to its pid alone mid-call takes effect after that call returns.
- **Major**: a tool can no longer outlive the server, however the server dies. The server's main shell is the only writer on the lifeline — a dispatch closes its inherited copy before a tool starts — so a sentinel in the tool's process group fires whether the server was killed with a signal to its pid alone or to its whole process group, `SIGKILL` included. A wrapper that reaches the lifeline after the last writer is gone blocks on the open instead of starting its tool, so no tool runs orphaned. The sentinel ignores `SIGTERM`, so the group `TERM` a cancellation sends cannot remove it before the server dies. That kill runs no cleanup, so the in-flight record, the lifeline directory, the partial-line handoff file, and an in-flight call's output file with the sentinel pid recorded beside it can remain under `TMPDIR`; a server that goes down on a signal it can trap removes the output file and the sentinel pid file beside it as part of its teardown.
- A partial line left on stdin when a client closes it mid-call is discarded, and only its length is logged — unless the joined bytes already parse as JSON, which is the client's last request written without a trailing newline, and which is answered rather than discarded. An unterminated line that does not parse was previously parsed as a request and answered with a `-32700` parse error. The in-flight call's response still arrives first, and the server then exits. A line left incomplete when the call ends is carried out of the dispatch through a file and joined to the next line the read loop takes in, so the call's response reaches the client as soon as the dispatch returns rather than waiting on that line; the request the completed line forms is answered when its remaining bytes arrive. The join needs a line, so a fragment the loop is holding when only an unterminated tail follows and stdin closes is dropped with that tail rather than dispatched — nothing else can ever terminate it. A call that arrived mid-call and is replayed after it runs to completion without a cancellation window of its own, which keeps that replay from reading the client's stream.
- **Major**: `lib/mcpserver_core.sh` requires Bash 4.1+, where it previously stated 4.0+. The file allocates file descriptors with `{var}` redirection, a 4.1 feature.

## [3.0.0] - 2026-09-03

### Changed

- `validate_tool_arguments` now enforces `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` against number-valued arguments. It previously read no range keyword, so a schema declaring `minimum: 1` accepted an out-of-range value like `-1` and let it reach the tool function. **Major**: arguments that violate a declared bound now return an `isError` result instead of reaching the tool. Consumers should review every range declaration in their tools list — `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` alike — against the values their clients send before bumping their pin.
- `validate_tool_arguments` now decides a declared `integer` from the number as jq renders it as well as from its value. It previously tested `val == (val | floor)` alone, and `floor` works in IEEE-754 doubles: at or above 2^52 (4503599627370496) the double spacing reaches 1, so a fractional argument like `4503599627370496.5` was already whole before the comparison and reached the tool function with its fraction intact. **Major**: a fractional argument at or above that threshold against an `integer`-typed property, `items.type`, or union member now returns an `isError` result. Values that are integers under JSON Schema stay accepted, including `1.0`, `1e2` and `1.5e3`. One gap remains: a value jq renders with an exponent keeps the old double-based verdict, so a fractional value below the smallest subnormal double (`1.5e-400`) is still accepted as an integer.
- Documented the `jq` version this behavior depends on: 1.7+. Below that floor, jq parses every number to a double and the rendered literal no longer preserves a fraction the double rounded away. This states an existing dependency; it does not add one.

## [2.0.0] - 2026-09-02

### Changed

- `validate_tool_arguments` now enforces a `type` declared as a list of alternatives (`"type": ["integer", "string"]`), on a property and on `items.type` alike. It previously treated a list-valued `type` as no constraint, so any value passed. **Major**: arguments a union-typed property accepted before this change can now be rejected with `isError`. Consumers should review before bumping their pin.

## [1.0.0] - 2026-09-02

### Added

- `lib/mcpserver_core.sh` — JSON-RPC 2.0 stdio loop, tool dispatch, `inputSchema` argument validation, dual-target logging.
- BATS suites covering the validator, the logging surface, and the guarantee that the file sources nothing and serves the protocol on its own.
- ShellCheck and BATS in CI.
