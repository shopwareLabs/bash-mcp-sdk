#!/bin/bash
# Shared fixtures for the SDK test suites.

# Locate the repo root by walking up until .bats/ is found.
_get_repo_root() {
    local test_dir="${BATS_TEST_DIRNAME}"
    while [[ ! -d "${test_dir}/.bats" ]] && [[ "${test_dir}" != "/" ]]; do
        test_dir="$(dirname "$test_dir")"
    done
    printf '%s\n' "$test_dir"
}

REPO_ROOT="$(_get_repo_root)"

load "${REPO_ROOT}/.bats/bats-support/load"
load "${REPO_ROOT}/.bats/bats-assert/load"

# Export the MCP_* environment a suite's setup() hands the SDK: the log file and
# PROJECT_ROOT under BATS_TEST_TMPDIR, and the two files the suite picks. Both
# optional logging variables are unset so a caller's MCP_EXTRA_LOG_FILE or
# MCP_LOG_STDERR cannot reach the tests.
# Usage: mcp_test_env <config-file> <tools-list-file>
mcp_test_env() {
    if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
        printf 'usage: mcp_test_env <config-file> <tools-list-file>\n' >&2
        return 2
    fi
    export MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    export PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    export MCP_CONFIG_FILE="$1"
    export MCP_TOOLS_LIST_FILE="$2"
    unset MCP_EXTRA_LOG_FILE MCP_LOG_STDERR
}

# The per-test directory put_stub_on_path writes its stubs into.
stub_bin_dir() {
    printf '%s\n' "${BATS_TEST_TMPDIR}/bin"
}

# Write an executable named <name> into the per-test stub directory and put that
# directory to the front of PATH when it is not on PATH yet. A directory already on
# PATH stays where it is, so repeated calls in one test keep it first. <body> is the
# whole script after a `#!/bin/sh` line, so it is POSIX sh and needs no bash on PATH.
# Calling it again for another name adds to the same directory.
# Usage: put_stub_on_path <name> <body>
put_stub_on_path() {
    if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
        printf 'usage: put_stub_on_path <name> <body>\n' >&2
        return 2
    fi
    local bin_dir
    bin_dir="$(stub_bin_dir)"
    mkdir -p "${bin_dir}"
    printf '#!/bin/sh\n%s\n' "$2" > "${bin_dir}/$1"
    chmod +x "${bin_dir}/$1"
    case ":${PATH}:" in
        *":${bin_dir}:"*) ;;
        *) export PATH="${bin_dir}:${PATH}" ;;
    esac
}
