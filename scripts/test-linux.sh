#!/usr/bin/env bash
# Multi-distro test runner: ShellCheck plus the BATS suites in Docker images.
# CI calls this too, so the CLI is a contract: --no-build, then distro names.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
SHELLCHECK_IMAGE="koalaman/shellcheck-alpine:v0.11.0"

STAGE_NAMES=()
STAGE_RESULTS=()

usage() {
    printf '%s\n' "usage: scripts/test-linux.sh [--no-build] [debian|alpine ...]" >&2
}

fail() {
    printf '%s\n' "error: $1" >&2
    exit 1
}

record_stage() {
    STAGE_NAMES+=("$1")
    STAGE_RESULTS+=("$2")
}

base_image_for() {
    case "$1" in
        debian) printf '%s' "${BASE_IMAGE_DEBIAN:-}" ;;
        alpine) printf '%s' "${BASE_IMAGE_ALPINE:-}" ;;
        *) return 1 ;;
    esac
}

build_image() {
    local distro="$1"
    local base_image
    local -a args=(build)

    args+=(-f "${REPO_ROOT}/docker/${distro}.Dockerfile")
    args+=(-t "bash-mcp-sdk-test:${distro}")
    base_image="$(base_image_for "${distro}")"
    if [[ -n "${base_image}" ]]; then
        args+=(--build-arg "BASE_IMAGE=${base_image}")
    fi
    if [[ -n "${JQ_VERSION:-}" ]]; then
        args+=(--build-arg "JQ_VERSION=${JQ_VERSION}")
    fi
    args+=("${REPO_ROOT}/docker")

    docker "${args[@]}"
}

run_shellcheck_stage() {
    printf '%s\n' "==> ShellCheck (${SHELLCHECK_IMAGE})"
    # The inner command is the find invocation CI runs; single-quoted for the container shell.
    docker run --rm \
        -v "${REPO_ROOT}:/repo:ro" \
        -w /repo \
        "${SHELLCHECK_IMAGE}" \
        sh -c "find lib tests scripts .github/scripts -type f \( -name '*.sh' -o -name '*.bats' -o -name '*.bash' \) -exec shellcheck --shell=bash --format=gcc {} +"
}

run_distro_stage() {
    local distro="$1"

    if [[ "${no_build}" -eq 0 ]]; then
        printf '%s\n' "==> Build bash-mcp-sdk-test:${distro}"
        build_image "${distro}" || return 1
    fi

    printf '%s\n' "==> Test bash-mcp-sdk-test:${distro}"
    docker run --rm --init \
        -v "${REPO_ROOT}:/repo:ro" \
        -w /repo \
        "bash-mcp-sdk-test:${distro}" \
        /repo/.bats/bats-core/bin/bats --timing -r tests/
}

no_build=0
distros=()

for arg in "$@"; do
    case "${arg}" in
        --no-build) no_build=1 ;;
        debian|alpine) distros+=("${arg}") ;;
        -*)
            printf '%s\n' "error: unknown flag: ${arg}" >&2
            usage
            exit 2
            ;;
        *)
            printf '%s\n' "error: unknown distro: ${arg}" >&2
            usage
            exit 2
            ;;
    esac
done

command -v docker > /dev/null 2>&1 || fail "docker is not on PATH"

if [[ ! -d "${REPO_ROOT}/.bats" ]]; then
    printf '%s\n' "==> Installing BATS into ${REPO_ROOT}/.bats"
    if ! "${REPO_ROOT}/.github/scripts/setup-bats.sh"; then
        fail "setup-bats.sh failed"
    fi
fi

if [[ "${#distros[@]}" -eq 0 ]]; then
    distros=(debian alpine)
    if ! run_shellcheck_stage; then
        record_stage shellcheck FAIL
    else
        record_stage shellcheck PASS
    fi
fi

for distro in "${distros[@]}"; do
    if ! run_distro_stage "${distro}"; then
        record_stage "${distro}" FAIL
    else
        record_stage "${distro}" PASS
    fi
done

failed=0
printf '\n%s\n' "==> Summary"
for i in "${!STAGE_NAMES[@]}"; do
    printf '%s  %s\n' "${STAGE_RESULTS[$i]}" "${STAGE_NAMES[$i]}"
    if [[ "${STAGE_RESULTS[$i]}" != "PASS" ]]; then
        failed=1
    fi
done
exit "${failed}"
