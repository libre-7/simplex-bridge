FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517

# OCI labels — also set at build time via docker/metadata-action for versioned tags
LABEL org.opencontainers.image.title="simplex-bridge"
LABEL org.opencontainers.image.description="SimpleX Chat bot daemon — WebSocket API for Hermes Agent and messaging bots"
LABEL org.opencontainers.image.vendor="libre-7"
LABEL org.opencontainers.image.licenses="GPL-3.0"
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
# SHA256 verification: download checksum file, filter for gosu-amd64,
# rewrite the path to match the actual binary location, then verify.
RUN set -eux; \
    curl -fsSLo /usr/local/bin/gosu \
      "https://github.com/tianon/gosu/releases/download/1.17/gosu-amd64"; \
    curl -fsSLo /tmp/gosu.SHA256SUMS \
      "https://github.com/tianon/gosu/releases/download/1.17/SHA256SUMS"; \
    grep 'gosu-amd64$' /tmp/gosu.SHA256SUMS | sed 's|  gosu-amd64$|  /usr/local/bin/gosu|' > /tmp/gosu-checksum.txt; \
    sha256sum -c /tmp/gosu-checksum.txt; \
    rm -f /tmp/gosu.SHA256SUMS /tmp/gosu-checksum.txt; \
    chmod +x /usr/local/bin/gosu

# Create generic user — UID/GID are overridden at runtime via PUID/PGID
# Use GID 911 as the build-time default (GID 1000 is taken on Ubuntu 24.04)
RUN groupadd --system --gid 911 simplex && \
    useradd --system --no-log-init --gid simplex --uid 911 --create-home simplex

VOLUME ["/data"]

# Install simplex-chat CLI binary (static Haskell binary, ~72MB, x86_64 only)
# NOTE: Only linux/amd64 is supported — no ARM binary is published upstream.
# SHA256 from: https://github.com/simplex-chat/simplex-chat/releases/tag/v7.0.1
RUN set -eux; \
    curl -fsSL -o /usr/local/bin/simplex-chat \
        "https://github.com/simplex-chat/simplex-chat/releases/download/v7.0.1/simplex-chat-ubuntu-24_04-x86_64"; \
    echo "85272a558cd69059f0dfa99634b2c5cedb17f374460c9cec44d9777af10050c1  /usr/local/bin/simplex-chat" | sha256sum -c -; \
    chmod +x /usr/local/bin/simplex-chat && \
    simplex-chat --version

EXPOSE 5225

ENV SIMPLEX_DISPLAY_NAME="Simplex Bridge" \
    SIMPLEX_AUTO_ACCEPT=true \
    SIMPLEX_FILES_ENABLED=true \
    SIMPLEX_MARK_READ=true \
    SIMPLEX_TOR=false \
    SIMPLEX_SOCAT_PORT="" \
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
