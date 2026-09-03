# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as scoped by the compatibility contract in `AGENTS.md`.

## [Unreleased]

### Changed

- `validate_tool_arguments` now enforces `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` against number-valued arguments. It previously read no range keyword, so a schema declaring `minimum: 1` accepted an out-of-range value like `-1` and let it reach the tool function. **Major**: arguments that violate a declared bound now return an `isError` result instead of reaching the tool. Consumers should review every range declaration in their tools list — `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` alike — against the values their clients send before bumping their pin.

## [2.0.0] - 2026-09-02

### Changed

- `validate_tool_arguments` now enforces a `type` declared as a list of alternatives (`"type": ["integer", "string"]`), on a property and on `items.type` alike. It previously treated a list-valued `type` as no constraint, so any value passed. **Major**: arguments a union-typed property accepted before this change can now be rejected with `isError`. Consumers should review before bumping their pin.

## [1.0.0] - 2026-09-02

### Added

- `lib/mcpserver_core.sh` — JSON-RPC 2.0 stdio loop, tool dispatch, `inputSchema` argument validation, dual-target logging.
- BATS suites covering the validator, the logging surface, and the guarantee that the file sources nothing and serves the protocol on its own.
- ShellCheck and BATS in CI.
