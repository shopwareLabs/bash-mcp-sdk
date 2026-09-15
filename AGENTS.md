# bash-mcp-sdk — Agent Guide

Source of truth for one file, `lib/mcpserver_core.sh`, the Bash MCP server framework. Consumers vendor the file and pin a tagged release. Nothing here is installed or executed in place. Human-facing documentation lives in `README.md`. Read the section a task touches rather than working from this file alone.

## Before editing

- Stdout carries the JSON-RPC stream. Only the response path writes to it; anything else corrupts the protocol (§Stdout discipline).
- Classify every change to a public name, argument order, or stdout shape before writing it (§Compatibility contract).
- `lib/mcpserver_core.sh` sources nothing and serves the protocol alone (§Scope).
- Every change to the file extends its BATS suite in the same commit (§Testing).
- The pre-flight block at the top of `lib/mcpserver_core.sh` must parse and run under every version it rejects (§Pre-flight guards).
- A public-surface change also updates the API and configuration tables (`README.md` §API) and gets a `CHANGELOG.md` entry classified per §Compatibility contract.

## Navigation

| Path | Role |
|---|---|
| `lib/mcpserver_core.sh` | The SDK — the only file consumers vendor; every unprefixed function is public API (`README.md` §API) |
| `tests/preflight.bats` | Pins the dependency guards: the Bash and `jq` floor comparisons, the refusals a missing, unrunnable or too-old dependency produces, the per-platform install hint, and that the block sits above the file's own `set -euo pipefail` so a refusal leaves the caller's shell options untouched |
| `tests/core_standalone.bats` | Pins the boundary: the file sources nothing, a server needs no other file |
| `tests/exit_trap_isolation.bats` | Pins that `run_mcp_server`'s EXIT trap stays with the shell that runs it: a caller that isolates the call in a subshell keeps its own EXIT trap, and that subshell is where the post-loop reset of `_MCP_IN_SERVER_LOOP` is observable |
| `tests/exit_trap_chaining.bats` | Pins that the teardown runs the EXIT handler a caller installed before `run_mcp_server`: on clean exit and on `SIGTERM`, a failing handler leaves the exit status alone, a `;`-joined handler runs whole, and the handler's stdout stays off the protocol stream |
| `tests/mcp_argument_validation.bats` | Pins the validator, including its diagnostic precedence |
| `tests/tools_call_params.bats` | Pins that a `tools/call` whose `params` is a number, a string or an array answers `-32602 Invalid params` without ending the server under `set -o posix` and without a jq diagnostic on stderr |
| `tests/error_response.bats` | Pins the error envelope builder, including its optional `data` argument |
| `tests/read_json_file.bats` | Pins `read_json_file`: one JSON object per file, and the `-32603` each handler answers with when its configuration file is missing, empty, multi-document, unparseable, or holds a document that is not a JSON object |
| `tests/extra_log_file.bats` | Pins the logging surface (`log`, `_configure_extra_log_file`) |
| `tests/cancellation.bats` | Pins cancellation: the in-flight kill, the absent response, ignored cancellations, the cancel hook, tool stdin, and the EOF drain |
| `tests/lifecycle.bats` | Pins server teardown: group and pid signals, the SIGKILL sentinel, and that no tool process outlives the server |
| `tests/client_harness.bats` | Pins the FIFO client harness: start a server, send one line, wait for a response, assert silence, tear down |
| `tests/fixtures/` | The fixture server (`cancellation_server.sh`) and tools list the cancellation and lifecycle suites drive over the real protocol |
| `tests/test_helper/common_setup.bash` | `REPO_ROOT` resolution; loads bats-support and bats-assert |
| `tests/test_helper/mcp_client.bash` | The client harness: the server's FIFO stdin, its capture files, and the per-start instance marker a suite scopes a process count with |
| `.github/scripts/setup-bats.sh` | Installs BATS into `.bats/` for local runs and every CI test job |
| `.github/workflows/ci.yml` | CI: a runner-native ShellCheck job over `lib`, `tests`, `scripts`, `.github/scripts`, and a Debian/Alpine container matrix running BATS through the script, images built with a GHCR cache |
| `docker/` | The per-distro test images, one Dockerfile each; the base image and jq version are build args |
| `scripts/test-linux.sh` | Runs the BATS suite in the distro containers and ShellCheck in the `koalaman/shellcheck-alpine` image, locally; CI calls it with `--no-build` |
| `.claude/extensions/software-writer/` | Project conventions delivered to the writing-code / writing-tests / writing-docs skills |
| `CHANGELOG.md` | Keep a Changelog record; an entry accompanies every released change |

## Scope

The repository carries the MCP protocol layer and nothing else. Config discovery, environment detection, and container command wrapping are consumer concerns and live in the consuming repositories. A change that needs a helper from outside `lib/mcpserver_core.sh` does not belong here — `tests/core_standalone.bats` fails when one is introduced.

## Compatibility contract

`lib/mcpserver_core.sh` is a public API. Consumers have vendored copies pinned to a tag, so:

- Renaming or removing a function, or changing its argument order, is a **major** bump.
- Changing what a function writes to stdout is a **major** bump — servers pipe that into tool results.
- Adding a function, a handled method, or a schema keyword the validator enforces is a **minor** bump.
- The variables consumers set — `MCP_TOOLS_LIST_FILE`, `MCP_CONFIG_FILE`, `MCP_LOG_FILE`, `MCP_EXTRA_LOG_FILE`, `MCP_LOG_STDERR`, `PROJECT_ROOT` — are part of that API. Names prefixed `_MCP_` are internal: they carry no guarantee and can change in any release.
- Sourcing the file with no other file present is guaranteed across majors.

Tightening the validator is a **major** bump even though it fixes a hole: arguments a consumer's clients send today start returning `isError` after the upgrade.

## Stdout discipline

Stdout carries the JSON-RPC stream. `run_mcp_server` captures each dispatch's stdout and echoes it, so only response construction writes there: `create_response`, `create_error_response`, and the deferred responses `handle_tools_call` replays for requests that arrived mid-call. Diagnostics go to `log`. `read_json_file` prints the parsed document, and every call site captures it in a command substitution, so that output never reaches the protocol stream. `_mcp_install_hint` prints its remediation lines to stdout so the function stays pure and directly testable; every call site redirects them to stderr with `>&2`, which keeps them off the protocol stream, and a new call site has to add that redirect. `validate_tool_arguments` is the one deliberate exception — it prints a human-readable message and returns 1, which `handle_tools_call` turns into an `isError` result. `run_mcp_server` also takes over the process's EXIT trap and expects to be that process's last call. The handler it displaces is not lost: `_server_teardown` runs it after the SDK's own cleanup, with its stdout redirected to stderr so it stays off the protocol stream. The consumer contract is stated in `README.md` §Cancelling and shutting down.

## Pre-flight guards

The top of `lib/mcpserver_core.sh` enforces the dependency floors in `README.md` §Requirements, before `set -euo pipefail` and before anything else runs.

Two constraints bind every edit to that block. It must parse and run under every version it rejects, so it uses no construct newer than Bash 3.2 — a rejected version that cannot parse the guard never reaches it. And its diagnostics go to stderr, both because stdout carries the protocol (§Stdout discipline) and because no protocol error is constructible there: `create_error_response` builds every envelope with `jq`.

Bash arithmetic and the `jq` version comparison sit in `_mcp_`-prefixed helpers that take their input as arguments, which is what makes them testable. `BASH_VERSINFO` is readonly, so a suite cannot fake a version in-process; the Bash arm is covered end to end only where the machine carries a Bash below 4.1, and `tests/preflight.bats` skips that case everywhere else. The CI matrix has no leg pinned to an old Bash — the Dockerfiles take a `JQ_VERSION` build arg and no Bash equivalent — so there only the comparison is covered, not the wiring around it.

## Testing

Setup and run commands live in `README.md` §Testing. On top of them, two conventions apply. Every change to `lib/mcpserver_core.sh` extends its suite in the same commit, and `tests/` is the only place the validator's diagnostic precedence (missing > unknown > type > pattern > range > items > enum) is pinned. Suites locate the repository through `tests/test_helper/common_setup.bash`, which walks up to the directory containing `.bats/`, so they work from any invocation directory but fail confusingly when `setup-bats.sh` has never run.

## Releasing

1. Land the change on `main` with tests.
2. Update `CHANGELOG.md`.
3. Tag `vX.Y.Z` per §Compatibility contract and publish a GitHub release — consumers' Renovate configs watch `github-releases`.
