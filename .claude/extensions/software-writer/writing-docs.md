## Named-value assignments

- `docs.surfaces` =
  | Surface | Owns | Shape | Single-owner |
  |---|---|---|---|
  | `README.md` | Pitch, requirements, install, the API and configuration-variable tables, the writing-a-server guide, the vendoring recipe, test commands, the not-supported list, license pointer | Emoji-prefixed H2s | enforced |
  | `AGENTS.md` | Agent routing (Before-editing pointers, the Navigation table), the scope boundary, the compatibility contract, the stdout discipline, testing conventions, the release procedure | Orientation line, `## Before editing`, `## Navigation`, then the machine-owned H2 sections; never inlines `README.md` — it points into it by `§Heading` | enforced |
  | `SECURITY.md` | Vulnerability reporting, the DevSec baseline, the consumer-code clarification | H2 sections separated by rules | enforced |
  | `CLAUDE.md` | Nothing of its own | A single `@AGENTS.md` line | exempt — a committed include, never carries content |
  | `CHANGELOG.md` | The per-version record of what changed | Keep a Changelog: `## [Unreleased]`, then `## [X.Y.Z] - YYYY-MM-DD` with `### Added` / `### Changed` / `### Fixed` | exempt — a version entry necessarily restates what the other surfaces describe as current behavior |
- `docs.pointer_file` = `AGENTS.md`. It owns all pointer content; the committed `CLAUDE.md` is its one-line `@AGENTS.md` companion and never carries content of its own.
- `docs.jargon_home` = `AGENTS.md` (repository root). It defines the compatibility contract, the stdout discipline, and the scope boundary; `README.md` owns the consumer-facing vendoring vocabulary (consumer, lock file, tagged release). No other surface re-defines either set.
- `docs.changelog` = `CHANGELOG.md`, Keep a Changelog with Semantic Versioning as scoped by `AGENTS.md` §Compatibility contract. Entries describe consumer-observable change; releases are tags `vX.Y.Z` with a GitHub release, which consumers' Renovate configs watch.
- `docs.diagrams` = Table-first everywhere: layout and routing use tables (`AGENTS.md` §Navigation); add a diagram only when a table cannot express the relationship.

## Pre-Step-1

This project is documented as independent: consumers state their relationship to it, never the other way around. Never describe the SDK as extracted from, split out of, or belonging to any other repository, on any surface.

STOP when the path is `CLAUDE.md` — it is a one-line include, not a surface to write on. STOP when the path is an untracked working document under `docs/superpowers/plans/**` or `docs/superpowers/specs/**`.

## Post-Step-5

When the documented change alters the public surface — a function, its stdout, a consumer-set variable, a handled method, or an enforced schema keyword — update `README.md`'s API and configuration tables and add the `CHANGELOG.md` entry classified per `AGENTS.md` §Compatibility contract in the same change.
