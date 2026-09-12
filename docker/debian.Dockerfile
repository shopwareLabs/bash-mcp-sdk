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
    rm -rf /var/lib/apt/lists/*
