# Alpine image for the multi-distro test harness (issue #8).
# The musl/busybox portability probe: bash and jq only, everything else is busybox.
ARG BASE_IMAGE=alpine:3.22
FROM ${BASE_IMAGE}

ARG JQ_VERSION=""

# One layer: install bash, resolve jq through busybox wget when JQ_VERSION is set.
RUN set -eux; \
    apk add --no-cache bash; \
    if [ -n "${JQ_VERSION}" ]; then \
        case "${JQ_VERSION}" in \
            v*) printf '%s\n' "JQ_VERSION must omit the leading v (for example 1.7.1)" >&2; exit 1 ;; \
        esac; \
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
    fi
