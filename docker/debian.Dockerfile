# Debian image for the multi-distro test harness (issue #8).
# The glibc side: distro jq by default, upstream static jq when JQ_VERSION is set.
ARG BASE_IMAGE=debian:stable-slim
FROM ${BASE_IMAGE}

ARG JQ_VERSION=""

# One layer: install procps, resolve jq, drop apt lists.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends procps; \
    if [ -n "${JQ_VERSION}" ]; then \
        case "${JQ_VERSION}" in \
            v*) printf '%s\n' "JQ_VERSION must omit the leading v (for example 1.7.1)" >&2; exit 1 ;; \
        esac; \
        apt-get install -y --no-install-recommends wget ca-certificates; \
        arch="$(uname -m)"; \
        case "${arch}" in \
            x86_64) jq_arch="amd64" ;; \
            aarch64) jq_arch="arm64" ;; \
            *) printf '%s\n' "unsupported architecture: ${arch}" >&2; exit 1 ;; \
        esac; \
        wget -q -O /usr/local/bin/jq \
            "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${jq_arch}"; \
        chmod +x /usr/local/bin/jq; \
        installed="$(jq --version)"; \
        if [ "${installed}" != "jq-${JQ_VERSION}" ]; then \
            printf '%s\n' "jq version mismatch: expected jq-${JQ_VERSION}, got ${installed}" >&2; \
            exit 1; \
        fi; \
    else \
        apt-get install -y --no-install-recommends jq; \
    fi; \
    installed="$(jq --version)"; \
    version="${installed#jq-}"; \
    major="${version%%.*}"; \
    minor_and_patch="${version#*.}"; \
    case "${version}" in *.*) ;; *) printf '%s\n' "invalid jq version: ${installed}" >&2; exit 1 ;; esac; \
    case "${minor_and_patch}" in \
        *.*) minor="${minor_and_patch%%.*}"; patch="${minor_and_patch#*.}"; case "${patch}" in ''|*.*|*[!0-9]*) printf '%s\n' "invalid jq version: ${installed}" >&2; exit 1 ;; esac ;; \
        *) minor="${minor_and_patch}" ;; \
    esac; \
    case "${major}:${minor}" in *[!0-9:]*|:*|*:) printf '%s\n' "invalid jq version: ${installed}" >&2; exit 1 ;; esac; \
    if [ "${major}" -lt 1 ] || { [ "${major}" -eq 1 ] && [ "${minor}" -lt 7 ]; }; then \
        printf '%s\n' "jq 1.7+ required, got ${installed}" >&2; \
        exit 1; \
    fi; \
    rm -rf /var/lib/apt/lists/*
