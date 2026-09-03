# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as scoped by the compatibility contract in `AGENTS.md`.

## [Unreleased]

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
