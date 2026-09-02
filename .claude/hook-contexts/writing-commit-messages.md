## Pre-Step-8

Apply these project-specific type-detection rows after the universal decision tree in `references/type-detection.md`. They refine but do not replace the universal tree.

| Change | Type | Notes |
|--------|------|-------|
| New function, handled method, or enforced schema keyword in `lib/mcpserver_core.sh` | `feat` | Minor bump per the compatibility contract |
| Behavior correction in `lib/mcpserver_core.sh` | `fix` | Mark `!` when the contract calls it major (see indicators) |
| Function renamed, removed, or resignatured | `refactor` | Always breaking (`!`) |
| Only `tests/**` | `test` | |
| `.github/workflows/` or `.github/scripts/` | `ci` | |
| Only `README.md`, `AGENTS.md`, `CLAUDE.md`, `CHANGELOG.md`, or `LICENSE` | `docs` | |

Project-specific breaking-change indicators (mark `!`), from `AGENTS.md` §Compatibility contract:

- A function renamed or removed, or its argument order changed.
- What a function writes to stdout changed.
- The validator tightened — even when it closes a hole, arguments accepted today start returning `isError`.
- A consumer-set variable (`MCP_TOOLS_LIST_FILE`, `MCP_CONFIG_FILE`, `MCP_LOG_FILE`, `MCP_EXTRA_LOG_FILE`, `PROJECT_ROOT`) renamed, removed, or reinterpreted.

The following are NOT breaking:

- A new function, a new handled method, or a new schema keyword the validator enforces (minor).
- Test, CI, or documentation changes.

## Pre-Step-9

Override the universal scope inference default: this project does not use scopes. The SDK is one file, so a scope would restate the repository name. Omit the scope on every commit regardless of which files changed.
