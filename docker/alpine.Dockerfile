# Alpine image for the multi-distro test harness (issue #8).
# The musl/busybox portability probe: bash and jq only, everything else is busybox.
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE}

ARG JQ_VERSION=""

# One layer: install bash, resolve jq through busybox wget when JQ_VERSION is set.
RUN set -eux; \
    apk add --no-cache bash; \
    if [ -n "${JQ_VERSION}" ]; then \
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
        apk add --no-cache jq; \
    fi
