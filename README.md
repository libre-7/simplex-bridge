# simplex-bridge

**SimpleX Chat bot daemon — WebSocket API for Hermes Agent and messaging bots**

[![Docker](https://github.com/libre-7/simplex-bridge/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/libre-7/simplex-bridge/actions/workflows/docker-publish.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/libre7/simplex-bridge?label=Docker%20Hub)](https://hub.docker.com/r/libre7/simplex-bridge)
[![GHCR](https://img.shields.io/badge/GHCR-libre--7%2Fsimplex--bridge-blue?logo=github)](https://ghcr.io/libre-7/simplex-bridge)
[![License](https://img.shields.io/github/license/libre-7/simplex-bridge)](LICENSE)

---

Run a SimpleX Chat bot as a Docker container. On first start it creates a bot profile and connection address. Connect your [Hermes Agent](https://github.com/nousresearch/hermes-agent) or custom bot framework via WebSocket.

🧪 **Compatibility note**: This version (`v0.1.0`) was tested with **Hermes Agent v0.15.2 (v2026.5.29.2)**. Work for Hermes Agent v0.16.0+ is on the [`feat/hermes-v0.16.0`](https://github.com/libre-7/simplex-bridge/tree/feat/hermes-v0.16.0) branch.

| Registry | Pull Command |
|----------|-------------|
| **GitHub Container Registry** (primary) | `docker pull ghcr.io/libre-7/simplex-bridge:latest` |
| **Docker Hub** | `docker pull libre7/simplex-bridge:latest` |

## What is SimpleX Chat?


SimpleX Chat is a fully private, decentralised messaging network. Unlike Signal, Telegram, or WhatsApp, it has **no persistent user identifiers** — no phone numbers, usernames, or IDs. Every connection uses unique, ephemeral queues. Even the servers cannot determine who is talking to whom.

This container runs the [SimpleX Chat CLI](https://github.com/simplex-chat/simplex-chat) in WebSocket server mode (`-p 5225`), giving your bot framework a JSON-based API to send and receive messages.

## Quick Start

```bash
docker run -d \
  --name simplex-bridge \
  --network host \
  -v simplex-data:/data \
  libre7/simplex-bridge:latest

# Get the bot address to share with contacts
cat $(docker volume inspect simplex-data --format '{{.Mountpoint}}')/bot_address.txt
```

## Images

| Registry | Pull URL | Latest Tag |
|----------|----------|------------|
| **Docker Hub** | `docker pull libre7/simplex-bridge` | `latest`, `sha-<commit>` |
| **GitHub Container Registry** | `docker pull ghcr.io/libre-7/simplex-bridge` | `latest`, `sha-<commit>`, `v*` |

Tags are automatically built and pushed on every push to `main`:
- **`latest`** — most recent commit on `main`
- **`sha-<7char>`** — immutable commit hash (use this for pinning in production)
- **`vX.Y.Z`** — Git tag releases

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SIMPLEX_DISPLAY_NAME` | `Simplex Bridge` | Name shown to contacts connecting to your bot |
| `SIMPLEX_AUTO_ACCEPT` | `true` | Auto-accept incoming contact requests |
| `SIMPLEX_FILES_ENABLED` | `true` | Allow file transfers from contacts |
| `SIMPLEX_MARK_READ` | `true` | Auto-mark received messages as read |
| `SIMPLEX_TOR` | `false` | Route through Tor SOCKS5 proxy (requires Tor on port 9050) |
| `SIMPLEX_SOCAT_PORT` | (empty) | Set to `5225` to expose WebSocket on all interfaces via socat bridge |
| `PUID` | `99` | User ID for file permissions (Unraid: 99) |
| `PGID` | `100` | Group ID for file permissions (Unraid: 100) |
| `TZ` | `UTC` | Container timezone |

### Network Configuration

The daemon binds to `127.0.0.1:5225` only (security by design). **Both containers need host networking** — simplex-bridge **and** Hermes Agent must use `--network host` (or `network_mode: host` in Compose) so they share the same loopback interface and Hermes can reach `ws://127.0.0.1:5225`.

The Unraid template defaults to host networking for simplex-bridge.

**Bridge networking via socat** (under investigation): Set `SIMPLEX_SOCAT_PORT=5225` to start a socat proxy that exposes `0.0.0.0:5225`. When using bridge, change the network type to `bridge` and map `-p 5225:5225`. Note: this is not yet confirmed working in testing.

### Tagging & Pinning

For production stability, pin to a SHA tag (immutable):

```yaml
# docker-compose.yml
image: ghcr.io/libre-7/simplex-bridge:sha-a1b2c3d
```

SHA tags never change — the same commit always produces the same binary. The `latest` tag follows `main`.

## Integration with Hermes Agent

Two scripts are provided for different Hermes Agent versions:

- **Hermes Agent v0.16.0+ (v2026.6.5+)** → `install-websockets.sh`
- **Hermes Agent v0.15.2 (v2026.5.29.2) or older** → `patch-hermes-simplex.sh` (tagged as [`v0.1.0`](https://github.com/libre-7/simplex-bridge/releases/tag/v0.1.0))

Choose the one that matches your Hermes version:

### v0.16.0+: install-websockets.sh

The Simplex adapter works out of the box. Only the `websockets` Python package needs installing:

```bash
curl -fsSL https://raw.githubusercontent.com/libre-7/simplex-bridge/main/install-websockets.sh | bash
docker exec hermes-webui /app/venv/bin/hermes gateway restart
```

No adapter code patches or `plugin.yaml` copies are needed.

### v0.15.2 and older: patch-hermes-simplex.sh

```bash
curl -fsSL https://raw.githubusercontent.com/libre-7/simplex-bridge/main/patch-hermes-simplex.sh | bash
docker exec hermes-webui /app/venv/bin/hermes gateway restart
```

The script installs `websockets` and copies the `plugin.yaml` file from source to site-packages (the build process drops non-.py files from the installed wheel). No adapter code patches are applied.

### Environment variables

Set these on the Hermes WebUI container:

```
SIMPLEX_WS_URL=ws://127.0.0.1:5225
SIMPLEX_ALLOW_ALL_USERS=true
SIMPLEX_HOME_CHANNEL=1
```

Host networking is required for both containers so Hermes can reach the simplex daemon via loopback.

### Share your bot address

```bash
docker logs simplex-bridge | grep "Bot address"
```

Or read `/mnt/user/appdata/simplex-bridge/bot_address.txt`.

## Docker Compose

Both containers require host networking — simplex-bridge **and** Hermes Agent must share the loopback interface.

```yaml
services:
  simplex-bridge:
    image: ghcr.io/libre-7/simplex-bridge:latest
    container_name: simplex-bridge
    network_mode: host
    volumes:
      - simplex-data:/data
    environment:
      SIMPLEX_DISPLAY_NAME: "My Bot"
      SIMPLEX_AUTO_ACCEPT: "true"
    restart: unless-stopped

volumes:
  simplex-data:
```

## Unraid / Community Applications

**⚠️ Not yet available on Community Apps.** The template must be installed manually.

1. Add container from **Docker** → **Add Container**
2. Set these **Config** fields:

| Key | Value |
|-----|-------|
| Name | `simplex-bridge` |
| Repository | `ghcr.io/libre-7/simplex-bridge:latest` |
| Network Type | **Host** |
| Post Arguments | (leave blank) |

3. Add the following **Variables** and **Path** entries via the **Show more settings...** toggle:

| Type | Name | Key | Value |
|------|------|-----|-------|
| Variable | Display Name | `SIMPLEX_DISPLAY_NAME` | `Simplex Bridge` |
| Variable | Auto Accept | `SIMPLEX_AUTO_ACCEPT` | `true` |
| Path | Appdata | `/mnt/user/appdata/simplex-bridge` → `/data` |

4. Start the container
5. Read bot address from `/mnt/user/appdata/simplex-bridge/bot_address.txt`

The Unraid template:
- **Requires host networking** (simplex binds to 127.0.0.1; Hermes also needs host networking)
- Persists database to `/mnt/user/appdata/simplex-bridge`
- Runs as `PUID=99 PGID=100` (Unraid defaults)

## Bot Address Format

```
simplex:/contact#/?v=2-7&smp=smp%3A%2F%2F...%3D%40smp4.simplex.im%2F...
```

Share this once with each contact via any other channel (email, another messenger, QR code). Each use creates a permanent end-to-end encrypted connection.

## FAQ

**Q: Can I use this without Hermes Agent?**
Yes — any program that speaks WebSocket JSON can use the API. See the [SimpleX Bot API docs](https://github.com/simplex-chat/simplex-chat/blob/stable/bots/README.md).

**Q: What platforms does this support?**
`linux/amd64` only. The `simplex-chat` upstream binary is distributed as an x86_64 Ubuntu executable — no ARM64 build is published.

**Q: How is this different from a Telegram/Discord bot?**
SimpleX has no central servers that know who users are. No phone numbers, no usernames, no IPs logged. Your bot exists on a peer-to-peer network where only your contacts know it exists.

**Q: What port does this use?**
Port 5225 for the WebSocket API. Host networking is required — no port mapping is needed (both containers share loopback).

**Q: Can I run multiple bots?**
Yes — use separate data directories and ports.

## Building from Source

```bash
docker build -t simplex-bridge .
docker run --rm --network host -v $PWD/data:/data simplex-bridge
```

## License

GNU General Public License v3.0

## Tags Reference

| Tag | When | Stability |
|-----|------|-----------|
| `latest` | Every push to `main` | Rolling |
| `sha-<commit>` | Every push to `main` | ✅ Immutable |
| `vX.Y.Z` | Git tag pushed | ✅ Immutable, versioned |
