#!/usr/bin/env bats
# bats file_tags=mcp-core,preflight
# Pins the pre-flight dependency guards: the two version-floor predicates
# (_mcp_bash_meets_floor, _mcp_jq_meets_floor), the refusals sourcing raises
# when jq is missing, cannot be run or is too old, the remediation hint's
# per-platform branches, that a refusal writes nothing to stdout, and that a
# refusal precedes the file's own `set -euo pipefail` so it leaves the calling
# shell's options untouched.
# The bash arm is driven end to end through a genuinely old Bash where the
# machine carries one; BASH_VERSINFO is readonly, so a suite cannot fake a
# version in-process and that case skips where no such Bash is present. The
# predicate behind the arm is covered from a table as well.
bats_require_minimum_version 1.11.0

load "${BATS_TEST_DIRNAME}/test_helper/common_setup"

CORE_SH="${REPO_ROOT}/lib/mcpserver_core.sh"

setup() {
    MCP_LOG_FILE="${BATS_TEST_TMPDIR}/server.log"
    MCP_EXTRA_LOG_FILE=""
    PROJECT_ROOT="${BATS_TEST_TMPDIR}"
    MCP_CONFIG_FILE="/dev/null"
    MCP_TOOLS_LIST_FILE="/dev/null"
    export MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE
    # The guards pass on any machine that can run this suite, so sourcing here
    # is what makes the two predicates callable directly.
    source "${REPO_ROOT}/lib/mcpserver_core.sh"
}

teardown() {
    unset MCP_LOG_FILE MCP_EXTRA_LOG_FILE PROJECT_ROOT MCP_CONFIG_FILE MCP_TOOLS_LIST_FILE
}

# Write an executable stand-in for a command into "$dir", with "$body" as its
# whole script. Shims are built per test under BATS_TEST_TMPDIR; nothing here is
# committed.
_make_shim() {
    local dir="$1"
    local name="$2"
    local body="$3"
    mkdir -p "${dir}"
    {
        printf '#!/bin/sh\n'
        printf '%s\n' "${body}"
    } > "${dir}/${name}"
    chmod +x "${dir}/${name}"
}

# Source the SDK in a fresh shell whose PATH is exactly "$1", with stdout and
# stderr captured apart so a refusal's stdout silence is assertable.
# "${BASH}" is the shell running this suite, which by definition meets the bash
# floor; "env" is resolved through this test's own PATH before the swap.
_source_core_with_path() {
    local path_value="$1"
    run --separate-stderr env "PATH=${path_value}" "${BASH}" -c "source '${CORE_SH}'"
}

# Source the SDK under an arbitrary interpreter "$1", with stdout and stderr
# captured apart. A sibling of _source_core_with_path rather than a
# generalization: that one always drives "${BASH}", the shell running this
# suite, and only the old-Bash case below needs a different interpreter.
_source_core_with() {
    local interpreter="$1"
    run --separate-stderr "${interpreter}" -c "source '${CORE_SH}'"
}

# The first absolute-path Bash on this machine that reports a version below the
# 4.1 floor, or nothing when every candidate meets it. Each candidate is run and
# its own BASH_VERSINFO read, never the predicate under test: a defect in that
# predicate must not decide which interpreter the end-to-end case drives.
_find_bash_below_floor() {
    local candidate
    for candidate in /bin/bash /usr/bin/bash /usr/local/bin/bash; do
        [[ -x "${candidate}" ]] || continue
        local reported
        # shellcheck disable=SC2016 # the quoted script is executed by the candidate shell, so its expansions must stay literal here.
        reported=$("${candidate}" -c 'printf "%s %s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null) || continue
        local major="${reported%% *}"
        local minor="${reported##* }"
        case "${major}" in ''|*[!0-9]*) continue ;; esac
        case "${minor}" in ''|*[!0-9]*) continue ;; esac
        if (( 10#${major} < 4 || (10#${major} == 4 && 10#${minor} < 1) )); then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

# bats-assert 2.2.4 ships no stderr assertion, and `run --separate-stderr` is
# the only way to assert stdout emptiness on its own, so stderr substrings are
# checked here.
_assert_stderr_contains() {
    local needle="$1"
    [[ "${stderr}" == *"${needle}"* ]] \
        || fail "stderr does not contain '${needle}'; stderr was: ${stderr}"
}

# Assert a predicate returns exactly 1 — not merely any non-zero status.
# `refute <cmd>` treats every non-zero status as falsy, so a bare refute passes
# vacuously when the command does not exist and the shell answers 127: the
# refute-only predicate cases stayed green with the whole guard deleted. Driving
# the call through `run` and checking the exact status makes a missing function
# (127) fail the case, so the assertion pins the predicate rather than its
# absence.
_assert_predicate_returns_1() {
    run "$@"
    [[ "${status}" -eq 1 ]] \
        || fail "expected status 1 from '$*'; got ${status}"
}

# --- _mcp_bash_meets_floor ---

@test "_mcp_bash_meets_floor: 4.1 and above meet the floor" {
    assert _mcp_bash_meets_floor 4 1
    assert _mcp_bash_meets_floor 4 9
    assert _mcp_bash_meets_floor 5 0
    # Numeric, not lexical: "10" sorts below "4" as a string.
    assert _mcp_bash_meets_floor 10 0
}

@test "_mcp_bash_meets_floor: below 4.1 does not meet the floor" {
    # 3.2 is stock macOS /bin/bash, the version this guard exists to refuse.
    _assert_predicate_returns_1 _mcp_bash_meets_floor 3 2
    _assert_predicate_returns_1 _mcp_bash_meets_floor 4 0
}

@test "_mcp_bash_meets_floor: an empty or non-numeric component is below the floor" {
    _assert_predicate_returns_1 _mcp_bash_meets_floor "" ""
    _assert_predicate_returns_1 _mcp_bash_meets_floor 4 ""
    _assert_predicate_returns_1 _mcp_bash_meets_floor "x" "y"
    _assert_predicate_returns_1 _mcp_bash_meets_floor 4 "1a"
}

@test "_mcp_bash_meets_floor: a leading zero compares in base 10, not octal" {
    # The digit guards admit "08", and a leading zero in an arithmetic context
    # means octal, where 08 is not a number: without the 10# prefix bash writes
    # its own complaint to stderr and the predicate answers below the floor.
    assert _mcp_bash_meets_floor 4 08
    assert _mcp_bash_meets_floor 08 0
    _assert_predicate_returns_1 _mcp_bash_meets_floor 04 00
}

# --- _mcp_jq_meets_floor ---

@test "_mcp_jq_meets_floor: 1.7 and above meet the floor" {
    assert _mcp_jq_meets_floor "jq-1.7"
    assert _mcp_jq_meets_floor "jq-1.7.1"
    assert _mcp_jq_meets_floor "jq-1.8.2"
    # A distro suffix trails the patch component and must not block the parse.
    assert _mcp_jq_meets_floor "jq-1.7.1-Debian-1"
    # A distro suffix attached straight to the minor, with no patch component
    # between them, must not be read as a non-numeric minor.
    assert _mcp_jq_meets_floor "jq-1.7-Debian-1"
    assert _mcp_jq_meets_floor "jq-1.8-1"
    # The lexical-comparison trap: "1.10" sorts below "1.7" as a string.
    assert _mcp_jq_meets_floor "jq-1.10"
    assert _mcp_jq_meets_floor "jq-2.0"
}

@test "_mcp_jq_meets_floor: below 1.7 does not meet the floor" {
    _assert_predicate_returns_1 _mcp_jq_meets_floor "jq-1.5"
    _assert_predicate_returns_1 _mcp_jq_meets_floor "jq-1.6"
}

@test "_mcp_jq_meets_floor: a prerelease of 1.7 does not meet the floor" {
    # A release candidate is not evidence of released 1.7 number-literal
    # handling, so it is refused rather than read as 1.7.
    _assert_predicate_returns_1 _mcp_jq_meets_floor "jq-1.7rc1"
}

@test "_mcp_jq_meets_floor: an unparseable version string is below the floor" {
    _assert_predicate_returns_1 _mcp_jq_meets_floor "jq"
    _assert_predicate_returns_1 _mcp_jq_meets_floor ""
    _assert_predicate_returns_1 _mcp_jq_meets_floor "garbage"
    _assert_predicate_returns_1 _mcp_jq_meets_floor "1.8.2"
}

@test "_mcp_jq_meets_floor: a leading zero compares in base 10, not octal" {
    # Same octal trap as the bash predicate: "jq-1.08" reaches the comparison
    # because 08 is all digits, and without 10# the arithmetic errors out.
    assert _mcp_jq_meets_floor "jq-1.08"
    _assert_predicate_returns_1 _mcp_jq_meets_floor "jq-1.06"
}

# --- sourcing refusals ---

@test "sourcing refuses a jq below the 1.7 floor and names the version found" {
    local shim="${BATS_TEST_TMPDIR}/old-jq"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'

    _source_core_with_path "${shim}:${PATH}"
    assert_failure
    _assert_stderr_contains "bash-mcp-sdk"
    _assert_stderr_contains "1.7"
    _assert_stderr_contains "jq-1.6"
}

@test "sourcing refuses a jq below the floor without writing to stdout" {
    local shim="${BATS_TEST_TMPDIR}/old-jq"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'

    _source_core_with_path "${shim}:${PATH}"
    # The refusal is asserted here too, not only in the test above: without it
    # this case passes against a file carrying no guard at all, because an
    # untroubled source writes nothing to stdout either.
    assert_failure
    _assert_stderr_contains "jq 1.7 or newer is required"
    # Stdout carries the JSON-RPC stream; a refusal must not put a byte in it.
    assert_output ''
}

@test "sourcing refuses when jq is absent from PATH" {
    # An empty PATH removes uname as well, so this also covers the hint falling
    # back to its generic line when the platform cannot be determined.
    local empty="${BATS_TEST_TMPDIR}/empty"
    mkdir -p "${empty}"

    _source_core_with_path "${empty}"
    assert_failure
    assert_output ''
    _assert_stderr_contains "bash-mcp-sdk"
    _assert_stderr_contains "jq was not found on PATH"
    _assert_stderr_contains "package manager"
}

@test "the distro-package warning is specific to the below-floor refusal" {
    # A bookworm box ships jq 1.6, so `apt-get install jq` reports it already
    # newest and the refusal repeats. The operator has to be told the distro
    # package can itself be the problem — but only on the floor refusal, where
    # that is true, not on the absent one, where installing is the fix.
    local old="${BATS_TEST_TMPDIR}/old-jq"
    _make_shim "${old}" "jq" 'printf "jq-1.6\n"'
    _source_core_with_path "${old}:${PATH}"
    assert_failure
    _assert_stderr_contains "a distribution package may itself sit below the floor"

    local empty="${BATS_TEST_TMPDIR}/empty-absent"
    mkdir -p "${empty}"
    _source_core_with_path "${empty}"
    assert_failure
    [[ "${stderr}" != *"may itself sit below the floor"* ]] \
        || fail "the jq-absent refusal warned about a distro package; stderr was: ${stderr}"
}

@test "sourcing a jq that is on PATH but cannot run names the broken binary" {
    # `command -v jq` succeeds for a jq that exists but cannot execute — the
    # wrong architecture, a missing shared library. `jq --version` then leaves
    # the version empty, and the below-floor message would misdirect the
    # operator to upgrade a package that is already current.
    local shim="${BATS_TEST_TMPDIR}/broken-jq"
    _make_shim "${shim}" "jq" 'exit 126'

    _source_core_with_path "${shim}:${PATH}"
    assert_failure
    _assert_stderr_contains "bash-mcp-sdk"
    _assert_stderr_contains "could not be run"
    # The path `command -v jq` resolved, so the operator can see which binary
    # on PATH did not answer.
    _assert_stderr_contains "${shim}/jq"
    # The distro-package line belongs to the below-floor refusal, where it is
    # true; on a broken binary the package is not below the floor.
    [[ "${stderr}" != *"may itself sit below the floor"* ]] \
        || fail "the broken-jq refusal warned about a distro package; stderr was: ${stderr}"
}

# --- _mcp_install_hint branches, driven through a refusal ---

@test "the hint names brew on Darwin" {
    local shim="${BATS_TEST_TMPDIR}/darwin"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'
    _make_shim "${shim}" "uname" 'printf "Darwin\n"'
    _make_shim "${shim}" "brew" 'exit 0'

    _source_core_with_path "${shim}"
    assert_failure
    _assert_stderr_contains "brew install jq"
}

@test "the hint falls back to the generic line on Darwin without brew" {
    local shim="${BATS_TEST_TMPDIR}/darwin-no-brew"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'
    _make_shim "${shim}" "uname" 'printf "Darwin\n"'

    _source_core_with_path "${shim}"
    assert_failure
    _assert_stderr_contains "install jq 1.7 or newer with your platform's package manager"
    [[ "${stderr}" != *"brew"* ]] \
        || fail "the Darwin hint named brew with no brew on PATH; stderr was: ${stderr}"
}

@test "the hint for bash on Darwin names brew and the PATH ordering" {
    # Called directly rather than through a refusal: the sourcing cases here run
    # the suite's own Bash, which meets the floor, so they fail at the jq guard
    # and the hint is never called with "bash" there; the end-to-end old-Bash
    # case runs against whatever platform the machine reports. Calling the pure
    # helper pins the Darwin branch and its PATH-ordering clause anywhere.
    local shim="${BATS_TEST_TMPDIR}/darwin-bash"
    _make_shim "${shim}" "uname" 'printf "Darwin\n"'
    _make_shim "${shim}" "brew" 'exit 0'

    local out
    out="$(PATH="${shim}" _mcp_install_hint bash)"
    [[ "${out}" == *"brew install bash"* ]] \
        || fail "hint does not name 'brew install bash'; hint was: ${out}"
    # The ordering instruction itself, not just the mention of /usr/bin: the
    # clause that unblocks a macOS operator is that the new bash has to come
    # before /usr/bin on the PATH a GUI-launched MCP host reads no profile for.
    [[ "${out}" == *"before /usr/bin in the PATH"* ]] \
        || fail "hint lacks the PATH ordering clause; hint was: ${out}"
}

@test "the hint for bash on Darwin orders PATH even with no brew present" {
    # A GUI-launched host hands the server a PATH with no brew on it, which is
    # the ordinary macOS case and the one where the fix is a PATH fix — so the
    # ordering clause cannot sit inside the brew probe.
    local shim="${BATS_TEST_TMPDIR}/darwin-bash-no-brew"
    _make_shim "${shim}" "uname" 'printf "Darwin\n"'

    local out
    out="$(PATH="${shim}" _mcp_install_hint bash)"
    [[ "${out}" == *"install bash 4.1 or newer with your platform's package manager"* ]] \
        || fail "hint lacks the generic install line; hint was: ${out}"
    [[ "${out}" == *"before /usr/bin in the PATH"* ]] \
        || fail "hint lacks the PATH ordering clause; hint was: ${out}"
    [[ "${out}" != *"brew"* ]] \
        || fail "the hint named brew with no brew on PATH; hint was: ${out}"
}

@test "the hint names the package manager found on a Linux PATH" {
    local shim="${BATS_TEST_TMPDIR}/linux"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'
    _make_shim "${shim}" "uname" 'printf "Linux\n"'
    _make_shim "${shim}" "apt-get" 'exit 0'

    _source_core_with_path "${shim}"
    assert_failure
    _assert_stderr_contains "apt-get install jq"
}

@test "the hint names apk when that is the Linux package manager present" {
    local shim="${BATS_TEST_TMPDIR}/linux-apk"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'
    _make_shim "${shim}" "uname" 'printf "Linux\n"'
    _make_shim "${shim}" "apk" 'exit 0'

    _source_core_with_path "${shim}"
    assert_failure
    _assert_stderr_contains "apk add jq"
}

@test "the hint names dnf when that is the Linux package manager present" {
    local shim="${BATS_TEST_TMPDIR}/linux-dnf"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'
    _make_shim "${shim}" "uname" 'printf "Linux\n"'
    _make_shim "${shim}" "dnf" 'exit 0'

    _source_core_with_path "${shim}"
    assert_failure
    _assert_stderr_contains "dnf install jq"
}

@test "the hint falls back to a generic line on an unrecognized platform" {
    local shim="${BATS_TEST_TMPDIR}/unknown"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'
    _make_shim "${shim}" "uname" 'printf "Plan9\n"'

    _source_core_with_path "${shim}"
    assert_failure
    # The whole generic line, not a fragment of it: "jq 1.7 or newer" alone is
    # already in the refusal above it, so it would pass with the hint silent.
    _assert_stderr_contains "install jq 1.7 or newer with your platform's package manager"
}

# --- end-to-end bash refusal (needs a genuinely old Bash on the machine) ---

@test "sourcing under a genuinely old Bash refuses end to end" {
    local old_bash
    old_bash="$(_find_bash_below_floor)" || old_bash=""
    if [[ -z "${old_bash}" ]]; then
        skip "no Bash below 4.1 on this machine; this arm is covered end to end only where one is present"
    fi

    local old_version
    # shellcheck disable=SC2016 # "${BASH_VERSION}" must expand in the old shell, not in this test.
    old_version="$("${old_bash}" -c 'printf "%s" "${BASH_VERSION}"')"

    _source_core_with "${old_bash}"
    assert_failure
    assert_output ''
    _assert_stderr_contains "bash-mcp-sdk"
    _assert_stderr_contains "4.1"
    _assert_stderr_contains "${old_version}"
}

# --- guard placement relative to the file's own `set -euo pipefail` ---

@test "a refusal leaves the calling shell's errexit setting untouched" {
    # The block sits above `set -euo pipefail` so a refusal returns non-zero
    # without touching the calling shell's options. Moved below that line, the
    # refusal would leave errexit active in a caller that never set it — which
    # is why `$-` is what this pins. The sourcing shell here has errexit off,
    # and `|| true` keeps it alive to report its options whether or not the
    # block leaked `set -e`.
    local shim="${BATS_TEST_TMPDIR}/old-jq-errexit"
    _make_shim "${shim}" "jq" 'printf "jq-1.6\n"'

    local probe
    probe="source '${CORE_SH}' || true
case \"\$-\" in *e*) printf 'errexit on\n' ;; *) printf 'errexit off\n' ;; esac"

    # stderr is captured apart so the refusal's own lines do not land in
    # `output` alongside the option report.
    run --separate-stderr env "PATH=${shim}:${PATH}" "${BASH}" -c "${probe}"
    assert_output 'errexit off'
    _assert_stderr_contains "jq 1.7 or newer is required"
}

@test "a successful source adopts the file's own shell options" {
    # The counterpart to the refusal case above. The file runs `set -euo
    # pipefail` below the guard, and a sourced file changes the sourcing shell,
    # so a caller that sources successfully ends with errexit on. The guard
    # returning before that line is what leaves only the refusal path's options
    # as it found them.
    local probe
    probe="source '${CORE_SH}'
case \"\$-\" in *e*) printf 'errexit on\n' ;; *) printf 'errexit off\n' ;; esac"

    run env "PATH=${PATH}" "${BASH}" -c "${probe}"
    assert_success
    assert_output 'errexit on'
}

# --- happy path ---

@test "sourcing under a satisfied environment is silent and succeeds" {
    _source_core_with_path "${PATH}"
    assert_success
    assert_output ''
    assert_equal "${stderr}" ''
}
