## Named-value assignments

- `project.stacks` =
  | Stack | Where | Toolchain |
  |---|---|---|
  | bash | `lib/mcpserver_core.sh`, `tests/**/*.bats`, `tests/test_helper/*.bash`, `.github/scripts/` | bash 4.0+ for the SDK and its tests; bash 3.2+ for `.github/scripts/` (runs on stock macOS); `jq`; ShellCheck v0.11.0 pinned in CI |

  No other stack is in play. The whole product is one bash file; everything else in the tree tests or ships it.
- `tests.frameworks` =
  | Stack | Framework | Test files | Run |
  |---|---|---|---|
  | bash | BATS — bats-core 1.13.0, bats-support 0.3.0, bats-assert 2.2.4; every file declares `bats_require_minimum_version 1.11.0` | `tests/*.bats` | `./.github/scripts/setup-bats.sh` once, then `.bats/bats-core/bin/bats -r tests/`; CI runs `bats --timing -r tests/` |
- `tests.fixture_sources` =
  - `tests/test_helper/common_setup.bash` — resolves `REPO_ROOT` by walking up from `BATS_TEST_DIRNAME` to the directory containing `.bats/`, then loads bats-support and bats-assert. `setup-bats.sh` must have run first: without `.bats/` the walk reaches `/` and every load fails from there.
  - Throwaway servers built in `setup()`: a `tools.json` and a `server.sh` heredoc in `BATS_TEST_TMPDIR` that exports the `MCP_*` variables, sources `${REPO_ROOT}/lib/mcpserver_core.sh`, and defines its `tool_<name>` functions — see `tests/core_standalone.bats` for the shape.

## Pre-Step-1

Place a new suite at `tests/<concern>.bats` and source the SDK as `${REPO_ROOT}/lib/mcpserver_core.sh`. Every change to `lib/mcpserver_core.sh` extends its suite in the same commit, and `tests/` is the only place the validator's diagnostic precedence (missing > unknown > type > pattern > range > items > enum) is pinned — a behavior change there needs its precedence cases updated, not just new happy paths.

## Pre-Step-4

Open an existing suite and copy its file header before writing a body: shebang, `# bats file_tags=mcp-core,<concern>`, a purpose comment naming what the suite pins, `bats_require_minimum_version 1.11.0`, then `load "${BATS_TEST_DIRNAME}/test_helper/common_setup"`.
