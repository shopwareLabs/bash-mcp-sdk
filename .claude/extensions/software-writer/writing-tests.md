## Named-value assignments

- `project.stacks` =
  | Stack | Where | Toolchain |
  |---|---|---|
  | bash | `lib/mcpserver_core.sh`, `tests/**/*.bats`, `tests/test_helper/*.bash`, `scripts/`, `.github/scripts/` | bash 4.1+ for the SDK and its tests, enforced by the pre-flight guard when the file is sourced; bash 3.2+ for `.github/scripts/` and for the guard block itself (both run on stock macOS); `jq` 1.7+; ShellCheck v0.11.0 pinned in CI |

  No other stack is in play. The whole product is one bash file; everything else in the tree tests or ships it.
- `tests.frameworks` =
  | Stack | Framework | Test files | Run |
  |---|---|---|---|
  | bash | BATS — bats-core 1.13.0, bats-support 0.3.0, bats-assert 2.2.4; every file declares `bats_require_minimum_version 1.11.0` | `tests/*.bats` | `./.github/scripts/setup-bats.sh` once, then `.bats/bats-core/bin/bats -r tests/`; CI runs `bats --timing -r tests/` through `scripts/test-linux.sh` in the debian, alpine and `bash-<major>.<minor>` containers, each run under a per-test `BATS_TEST_TIMEOUT` (default 90 seconds); those containers run as root (`docker/alpine.Dockerfile` and `docker/debian.Dockerfile` set no `USER`), so a failure built from permission bits does not fail there |
- `tests.fixture_sources` =
  - `tests/test_helper/common_setup.bash` — resolves `REPO_ROOT` by walking up from `BATS_TEST_DIRNAME` to the directory containing `.bats/`, then loads bats-support and bats-assert. `setup-bats.sh` must have run first: without `.bats/` the walk reaches `/` and every load fails from there.
  - `tests/test_helper/write_server.bash` — `write_server <path>` writes a throwaway server script from a stdin body: shebang, `set -euo pipefail`, the `MCP_*` exports (defaulting to `config.json`, `tools.json` and `server.log` in `BATS_TEST_TMPDIR`; `write_fixture_files <tools-list-json>` writes the first two, with `{}` as the config and the required tools list), the `source` line, the body, and `run_mcp_server`. See `tests/core_standalone.bats` for the shape. `tests/fixtures/cancellation_server.sh` stays a static fixture.
  - `tests/test_helper/mcp_client.bash` — `mcp_start_server` starts a server on a FIFO and returns once it answers a ping; `mcp_send`, `mcp_wait_for_response`, `mcp_assert_no_response` and `mcp_stop_server` drive it. Call `run_mcp_server` only in such a server script or in a `( … )` subshell, never in the test shell: it replaces the EXIT trap bats reports through, so bats misreports the test (a spurious `not ok` at the `run_mcp_server` line, or a test-count mismatch).

## Pre-Step-1

Place a new suite at `tests/<concern>.bats` and source the SDK as `${REPO_ROOT}/lib/mcpserver_core.sh`. Every change to `lib/mcpserver_core.sh` extends its suite in the same commit, and `tests/` is the only place the validator's diagnostic precedence (missing > unknown > type > pattern > range > items > enum > oneOf) is pinned — a behavior change there needs its precedence cases updated, not just new happy paths.

## Pre-Step-4

Open an existing suite and copy its file header before writing a body: shebang, `# bats file_tags=mcp-core,<concern>`, a purpose comment naming what the suite pins, `bats_require_minimum_version 1.11.0`, then `load "${BATS_TEST_DIRNAME}/test_helper/common_setup"`.
