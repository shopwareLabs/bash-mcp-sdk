# Security

## Reporting Vulnerabilities

To report a security vulnerability in this project, please open a [GitHub issue](https://github.com/shopwareLabs/bash-mcp-sdk/issues/new) with the label `security`. For sensitive disclosures, contact the Shopware Labs team directly via the Shopware GitHub organization.

We aim to acknowledge reports within 5 business days and will coordinate a fix and disclosure timeline with the reporter.

---

## DevSec Confirmation

This section documents the security baseline for this repository, as required for legal and compliance review.

**No automatic outbound network calls**
The SDK operates locally: it reads JSON-RPC from stdin, writes responses to stdout, and invokes `jq`. It makes no outbound network calls, telemetry uploads, crash reports, or update checks. The only network access in the repository is developer-initiated and version-pinned: `.github/scripts/setup-bats.sh` clones the BATS repositories from GitHub, and CI downloads ShellCheck.

**No hardcoded credentials or tokens**
The repository contains no hardcoded API keys, tokens, passwords, or credentials. No `.env` files or credential files are committed.

**No personal or test data in repository or git history**
The repository (including full git history) contains no personal data, real user data, or test data containing personally identifiable information. All content is source code, markdown documentation, JSON test fixtures, or bash scripts.

---

## Consumer Code Clarification

The SDK dispatches tool calls exclusively to `tool_<name>` bash functions that the consuming server defines. It executes no other code, bundles no third-party binaries, and makes no calls to external services. What a consumer's tool functions execute, and which services they contact, is determined solely by the consumer; Shopware Labs does not determine the technical means of any processing performed by consumer-authored tool functions.
