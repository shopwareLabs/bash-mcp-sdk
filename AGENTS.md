# bash-mcp-sdk — Agent Guide

Source of truth for one file, `lib/mcpserver_core.sh`, the Bash MCP server framework. Consumers vendor the file and pin a tagged release. Nothing here is installed or executed in place. Human-facing documentation lives in `README.md`. Read the section a task touches rather than working from this file alone.

## Before editing

- Stdout carries the JSON-RPC stream. Anything written outside `create_response` / `create_error_response` corrupts the protocol (§Stdout discipline).
- Classify every change to a public name, argument order, or stdout shape before writing it (§Compatibility contract).
- `lib/mcpserver_core.sh` sources nothing and serves the protocol alone (§Scope).
- Every change to the file extends its BATS suite in the same commit (§Testing).
- A public-surface change also updates the API and configuration tables (`README.md` §API) and gets a `CHANGELOG.md` entry classified per §Compatibility contract.

## Navigation

| Path | Role |
|---|---|
| `lib/mcpserver_core.sh` | The SDK — the only file consumers vendor; every unprefixed function is public API (`README.md` §API) |
| `tests/core_standalone.bats` | Pins the boundary: the file sources nothing, a server needs no other file |
| `tests/mcp_argument_validation.bats` | Pins the validator, including its diagnostic precedence |
| `tests/extra_log_file.bats` | Pins the logging surface (`log`, `_configure_extra_log_file`) |
| `tests/test_helper/common_setup.bash` | `REPO_ROOT` resolution; loads bats-support and bats-assert |
| `.github/scripts/setup-bats.sh` | One-time local BATS install into `.bats/` |
| `.github/workflows/ci.yml` | CI: ShellCheck v0.11.0 and BATS over `lib`, `tests`, `.github/scripts` |
| `.claude/extensions/software-writer/` | Project conventions delivered to the writing-code / writing-tests / writing-docs skills |
| `CHANGELOG.md` | Keep a Changelog record; an entry accompanies every released change |

## Scope

The repository carries the MCP protocol layer and nothing else. Config discovery, environment detection, and container command wrapping are consumer concerns and live in the consuming repositories. A change that needs a helper from outside `lib/mcpserver_core.sh` does not belong here — `tests/core_standalone.bats` fails when one is introduced.

## Compatibility contract

`lib/mcpserver_core.sh` is a public API. Consumers have vendored copies pinned to a tag, so:

- Renaming or removing a function, or changing its argument order, is a **major** bump.
- Changing what a function writes to stdout is a **major** bump — servers pipe that into tool results.
- Adding a function, a handled method, or a schema keyword the validator enforces is a **minor** bump.
- The variables consumers set — `MCP_TOOLS_LIST_FILE`, `MCP_CONFIG_FILE`, `MCP_LOG_FILE`, `MCP_EXTRA_LOG_FILE`, `PROJECT_ROOT` — are part of that API.
- Sourcing the file with no other file present is guaranteed across majors.

Tightening the validator is a **major** bump even though it fixes a hole: arguments a consumer's clients send today start returning `isError` after the upgrade.

## Stdout discipline

Stdout carries the JSON-RPC stream. Anything written outside `create_response` / `create_error_response` corrupts the protocol. Diagnostics go to `log`. `validate_tool_arguments` is the one deliberate exception — it prints a human-readable message and returns 1, which `handle_tools_call` turns into an `isError` result.

## Testing

Setup and run commands live in `README.md` §Testing. On top of them, two conventions apply. Every change to `lib/mcpserver_core.sh` extends its suite in the same commit, and `tests/` is the only place the validator's diagnostic precedence (missing > unknown > type > pattern > items > enum) is pinned. Suites locate the repository through `tests/test_helper/common_setup.bash`, which walks up to the directory containing `.bats/`, so they work from any invocation directory but fail confusingly when `setup-bats.sh` has never run.

## Releasing

1. Land the change on `main` with tests.
2. Update `CHANGELOG.md`.
3. Tag `vX.Y.Z` per §Compatibility contract and publish a GitHub release — consumers' Renovate configs watch `github-releases`.
