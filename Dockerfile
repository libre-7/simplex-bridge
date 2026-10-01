FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

# OCI labels — also set at build time via docker/metadata-action for versioned tags
LABEL org.opencontainers.image.title="simplex-bridge"
LABEL org.opencontainers.image.description="SimpleX Chat bot daemon — WebSocket API for Hermes Agent and messaging bots"
LABEL org.opencontainers.image.vendor="libre-7"
# This image REDISTRIBUTES the simplex-chat and simplexmq binaries, both of
# which are AGPL-3.0. The label must describe the terms the shipped artifact
# is actually under, not just this repo's own source license (GPL-3.0).
# See the "Bundled third-party components" section in README.md.
LABEL org.opencontainers.image.licenses="AGPL-3.0"
LABEL org.opencontainers.image.url="https://github.com/libre-7/simplex-bridge"
LABEL org.opencontainers.image.source="https://github.com/libre-7/simplex-bridge"
LABEL org.opencontainers.image.documentation="https://github.com/libre-7/simplex-bridge#readme"

# SimpleX Chat uses the SMP protocol — no persistent user IDs, fully private
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl iproute2 python3 python3-pip socat tzdata && \
    pip3 install --no-cache-dir --break-system-packages websockets==17.0.1 && \
    rm -rf /var/lib/apt/lists/*

# Install gosu — Ubuntu equivalent of Alpine's su-exec (static Go binary)
# 1.19 updates for Go vuln GO-2025-3956 (github.com/moby/sys/user).
# Multi-arch: gosu publishes one static binary per arch. TARGETARCH is set
# automatically by BuildKit; the local fallbacks keep plain `docker build`
# working on a native host (it leaves TARGETARCH empty).
# SHA256 verification: download the checksum file, filter for the arch we
# actually fetched, rewrite the path to the install location, then verify.
# The `test -s` guard is load-bearing — an empty grep result would make
# `sha256sum -c` succeed on zero entries, i.e. verify nothing.
ARG TARGETARCH
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64)  arch=amd64 ;; \
        aarch64) arch=arm64 ;; \
        *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    gosu_bin="gosu-${arch}"; \
    curl -fsSLo /usr/local/bin/gosu \
      "https://github.com/tianon/gosu/releases/download/1.19/${gosu_bin}"; \
    curl -fsSLo /tmp/gosu.SHA256SUMS \
      "https://github.com/tianon/gosu/releases/download/1.19/SHA256SUMS"; \
    # `grep ... | sed ... > file` would exit 0 on an empty grep result under
    # dash, which has no `set -o pipefail` (Ubuntu's /bin/sh). Split it: grep
    # first so its failure is visible, and require a non-empty match before
    # rewriting. An empty checksum file would make `sha256sum -c` succeed on
    # zero entries — i.e. verify nothing.
    grep "  ${gosu_bin}\$" /tmp/gosu.SHA256SUMS > /tmp/gosu.line; \
    test -s /tmp/gosu.line; \
    sed "s|  ${gosu_bin}\$|  /usr/local/bin/gosu|" /tmp/gosu.line > /tmp/gosu-checksum.txt; \
    sha256sum -c /tmp/gosu-checksum.txt; \
    rm -f /tmp/gosu.SHA256SUMS /tmp/gosu-checksum.txt /tmp/gosu.line; \
    chmod +x /usr/local/bin/gosu

# Create generic user — UID/GID are overridden at runtime via PUID/PGID
# Use GID 911 as the build-time default (GID 1000 is taken on Ubuntu 24.04)
RUN groupadd --system --gid 911 simplex && \
    useradd --system --no-log-init --gid simplex --uid 911 --create-home simplex

VOLUME ["/data"]

# Install simplex-chat CLI binary (static Haskell binary, ~80MB)
# Multi-arch: upstream publishes simplex-chat-ubuntu-24_04-{x86_64,aarch64}.
# Each arch has its own SHA256 in the v7.0.2 release notes, so the checksum is
# selected alongside the asset — never reuse one arch's digest for another.
# Bump SIMPLEX_VERSION + both digests together; base-refresh.yml only tracks
# the ubuntu digest, so this pin is maintained by hand.
ARG SIMPLEX_VERSION=v7.0.2
ARG TARGETARCH
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64)  arch=amd64 ;; \
        aarch64) arch=arm64 ;; \
        *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "$arch" in \
      amd64) \
        asset="simplex-chat-ubuntu-24_04-x86_64"; \
        sha="895fb14cfaa662d1c0947f2f871141fc89680fe3e70bff64c366cbe9e59aa4f0" ;; \
      arm64) \
        asset="simplex-chat-ubuntu-24_04-aarch64"; \
        sha="2d2e62351f11bc51ae659618584722b38ea5a6796b806c9a388ee6e3124c90ac" ;; \
      *) echo "no simplex-chat binary for arch '$arch'" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/simplex-chat \
      "https://github.com/simplex-chat/simplex-chat/releases/download/${SIMPLEX_VERSION}/${asset}"; \
    echo "${sha}  /usr/local/bin/simplex-chat" | sha256sum -c -; \
    chmod +x /usr/local/bin/simplex-chat && \
    simplex-chat --version

EXPOSE 5225

ENV SIMPLEX_DISPLAY_NAME="Simplex Bridge" \
    SIMPLEX_AUTO_ACCEPT=true \
    SIMPLEX_FILES_ENABLED=true \
    SIMPLEX_MARK_READ=true \
    SIMPLEX_TOR=false \
    SIMPLEX_SOCAT_PORT="" \
    SIMPLEX_STARTUP_TIMEOUT=15 \
    PUID=99 \
    PGID=100 \
    TZ=UTC

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.py /healthcheck.py
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

STOPSIGNAL SIGTERM

# Health check: verify WebSocket daemon is alive by connecting and
# sending a valid API command. Any response (including error) confirms
# the process is live and accepting connections.
# Falls back to TCP port check if Python websockets is unavailable.
HEALTHCHECK --start-period=10s --interval=30s --timeout=10s --retries=3 \
  CMD python3 /healthcheck.py
