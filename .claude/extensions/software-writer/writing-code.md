## Named-value assignments

- `project.stacks` =
  | Stack | Where | Toolchain |
  |---|---|---|
  | bash | `lib/mcpserver_core.sh`, `tests/**/*.bats`, `tests/test_helper/*.bash`, `.github/scripts/` | bash 4.0+ for the SDK and its tests; bash 3.2+ for `.github/scripts/` (runs on stock macOS); `jq`; ShellCheck v0.11.0 pinned in CI |

  No other stack is in play. The whole product is one bash file; everything else in the tree tests or ships it.
- `code.primitives` =
  | Call shape | Reach for | In-repo helper | Reason the wrapper exists |
  |---|---|---|---|
  | Read a JSON file the server owns | `cat "$file"` | `read_json_file` (`lib/mcpserver_core.sh`) | A missing file logs an ERROR and yields `{}` rather than emitting nothing into a `jq` pipeline. |
  | Emit a JSON-RPC result or error | building the JSON string by hand | `create_response`, `create_error_response` (`lib/mcpserver_core.sh`) | `jq -n -c` does the escaping, and the JSON-RPC 2.0 envelope is written once. |
  | Record a diagnostic | `echo … >> "$logfile"` | `log` (`lib/mcpserver_core.sh`) | Adds the timestamp and level, dual-writes to `MCP_EXTRA_LOG_FILE` when set, and always returns 0 so a log call cannot trip `set -e`. |
  | Check a call's arguments against a schema | ad-hoc `jq` at the call site | `validate_tool_arguments` (`lib/mcpserver_core.sh`) | Enforces the whole `inputSchema` with diagnostics in precedence order missing > unknown > type > pattern > range > items > enum, and treats a jq failure as a rejection, never a skip. |
  | Drive one request in a test | spawning the stdio loop | `process_request` (`lib/mcpserver_core.sh`) | Parses and routes a single JSON-RPC line, so a suite exercises a server without `run_mcp_server`'s read loop. |
- `code.di_pattern` = A consumer's server script is the composition root: it sets and exports the module inputs (`MCP_CONFIG_FILE`, `MCP_TOOLS_LIST_FILE`, `MCP_LOG_FILE`, `MCP_EXTRA_LOG_FILE`, `PROJECT_ROOT`), defines its `tool_<name>` functions, sources `mcpserver_core.sh`, and calls `run_mcp_server`. The module reads its inputs from those exported variables and discovers nothing itself. Inside this repository there is no composition root — the BATS suites build throwaway server scripts in `BATS_TEST_TMPDIR` to play that role.
- `code.export_conventions` = A leading `_` marks an internal function (`_configure_extra_log_file`); every unprefixed function, its argument order, what it writes to stdout, and the consumer-set variables are public API governed by `AGENTS.md` §Compatibility contract. Classify every surface change against that contract before writing it: rename, argument-order, or stdout change is a major bump; a new function, handled method, or enforced schema keyword is a minor bump; tightening the validator is a major bump even though it fixes a hole. A consumer exports a tool by doing both: defining `tool_<name>` and adding a `tools.json` entry with an `inputSchema` — an entry without a schema is dispatched unvalidated.
- `code.footgun_additions` =
  - **Stdout is the JSON-RPC stream.** Anything written to stdout outside `create_response` / `create_error_response` corrupts the protocol. `validate_tool_arguments` is the one deliberate exception: it prints a human-readable diagnostic and returns 1, which `handle_tools_call` captures into an `isError` result.
  - A tool function is dispatched as `output=$("$func_name" "$arguments" 2>&1) || exit_code=$?`. Three consequences: errexit is disabled inside every tool function (Bash turns `set -e` off in a tested command), so each step's status must be checked explicitly; stderr is merged into the result the client sees, not discarded; and the function inherits the server's stdin — the client's JSON-RPC pipe — so a stdin-reading child blocks forever or consumes protocol bytes.
  - jq's `//` treats a present `null` and a present `false` as absent. `handle_tools_call` derives arguments with `has("arguments")` for exactly this reason; keep that shape wherever the null/false distinction matters.
  - A jq `as` binding over zero outputs skips its entire body. The validator's `items` checks read `.type`/`.enum` by plain field access instead of `// empty` because of it — `// empty` on an absent key would silently discard every element, including violations of the constraint that was declared.
  - `lib/mcpserver_core.sh` sources nothing, and `tests/core_standalone.bats` fails when a dependency is introduced. A change that needs a helper from outside the file does not belong in this repository.
  - Two ShellCheck configs are in force. Root `.shellcheckrc` disables SC1091 (computed source paths); `tests/.shellcheckrc` additionally disables SC2329, SC2034, SC2030, and SC2031, so an unused variable or a lost subshell mutation in a test is silent. CI lints `.bats` and `.bash` files on the same terms as `.sh`.
- `comments.preserve_patterns` = `# shellcheck disable=`, `# shellcheck source=`, `# bats file_tags=`. Each reads as a comment and is tool input — deleting one changes lint or test-filter behavior. Every ShellCheck disable is per-line with a trailing rationale naming why the check does not apply; write a new one the same way and never widen one to file scope.
- `todo.ticket_format` = `TODO(#<issue>): <what is deferred, and the condition that clears it>`, with `FIXME` taking the same shape. The tracking reference is a GitHub issue number in this repository.
- `domain.terms` =
  - Consumer vocabulary, defined in `README.md` and `AGENTS.md`: consumer, vendoring, lock file, tagged release. Consumers copy the file and pin a tag — never "template", "sync", or "byte-identical", which describe a different distribution model.
  - **tool function** means a `tool_<name>` bash function a consumer defines; **tool result** means the `content`/`isError` object the dispatcher builds from it.
  - **compatibility contract** and **stdout discipline** name the two `AGENTS.md` sections; use those exact phrases.
  - **diagnostic precedence** means the validator's fixed order: missing > unknown > type > pattern > range > items > enum.
- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Pitch, requirements, install, the API and configuration-variable tables, the writing-a-server guide, the vendoring recipe, test commands, the not-supported list, license pointer | Emoji-prefixed H2s | enforced |
  | `AGENTS.md` | Agent routing (Before-editing pointers, the Navigation table), the scope boundary, the compatibility contract, the stdout discipline, testing conventions, the release procedure | Orientation line, `## Before editing`, `## Navigation`, then the machine-owned H2 sections; never inlines `README.md` — it points into it by `§Heading` | enforced |
  | `SECURITY.md` | Vulnerability reporting, the DevSec baseline, the consumer-code clarification | H2 sections separated by rules | enforced |
  | `CLAUDE.md` | Nothing of its own | A single `@AGENTS.md` line | exempt — a committed include, never carries content |
  | `CHANGELOG.md` | The per-version record of what changed | Keep a Changelog: `## [Unreleased]`, then `## [X.Y.Z] - YYYY-MM-DD` with `### Added` / `### Changed` / `### Fixed` | exempt — a version entry necessarily restates what the other surfaces describe as current behavior |

## Pre-Step-3

Before changing any unprefixed function's name, argument order, or stdout, a handled method, an enforced schema keyword, or a consumer-set variable, read `AGENTS.md` §Compatibility contract and classify the bump the change requires. Every change to `lib/mcpserver_core.sh` extends its BATS suite in the same commit.
