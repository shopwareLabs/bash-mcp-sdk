# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as scoped by the compatibility contract in `AGENTS.md`.

## [Unreleased]

### Added

- `lib/mcpserver_core.sh` — JSON-RPC 2.0 stdio loop, tool dispatch, `inputSchema` argument validation, dual-target logging.
- BATS suites covering the validator, the logging surface, and the guarantee that the file sources nothing and serves the protocol on its own.
- ShellCheck and BATS in CI.
