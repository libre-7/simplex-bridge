# simplex-bridge

**SimpleX Chat bot daemon — WebSocket API for Hermes Agent and messaging bots**

[![Docker](https://github.com/libre-7/simplex-bridge/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/libre-7/simplex-bridge/actions/workflows/docker-publish.yml)
[![Docker Hub](https://img.shields.io/docker/pulls/libre7/simplex-bridge?label=Docker%20Hub)](https://hub.docker.com/r/libre7/simplex-bridge)
[![GHCR](https://img.shields.io/badge/GHCR-libre--7%2Fsimplex--bridge-blue?logo=github)](https://ghcr.io/libre-7/simplex-bridge)
[![License](https://img.shields.io/github/license/libre-7/simplex-bridge)](LICENSE)

---

Run a SimpleX Chat bot as a Docker container. On first start it creates a bot profile and connection address. Connect your [Hermes Agent](https://github.com/nousresearch/hermes-agent) or custom bot framework via WebSocket.

📌 **Compatibility note**: `main` targets **Hermes Agent v0.20.0+ (v2026.8.3+)**. That version ships the SimpleX DM send fix natively (`/_send <target> json …`), which this image requires — `install-websockets.sh` verifies it and will exit non-zero on an older adapter rather than patching it. For older Hermes Agent versions (v0.14.x–v0.19.x), use the [`compat-v0.14`](https://github.com/libre-7/simplex-bridge/tree/compat-v0.14) branch.

The latest release is **v1.3.1** — multi-arch (`linux/amd64` + `linux/arm64`) plus two code-review remediation passes. v1.3.1 fixes two defects that made the bridge fail *silently*: `install-websockets.sh` installed `websockets` into the system Python, which the gateway venv cannot import (so the script reported success over a platform that would not load), and the startup readiness gates matched any port *containing* `5225`. See the [CHANGELOG](CHANGELOG.md) for the complete list.

> **Upgrading from v1.3.0 or earlier? Re-run `install-websockets.sh`.** The earlier script installed the dependency into the wrong Python, so an install performed before v1.3.1 leaves a broken SimpleX platform in place even on the fixed image. Verify with:
> `docker exec <container> /app/venv/bin/python3 -c "import websockets; print(websockets.__version__)"`

v1.1.0 and earlier shipped a `cap_drop: ALL` / no-`cap_add` combination that aborted the container at startup; upgrade to v1.2.0 or later.

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

| Registry | Pull URL | Tags published |
|----------|----------|----------------|
| **GitHub Container Registry** (primary) | `docker pull ghcr.io/libre-7/simplex-bridge` | `latest`, `sha-<commit>`, `vX.Y.Z`, `X.Y`, `X.Y.Z` |
| **Docker Hub** | `docker pull libre7/simplex-bridge` | `latest`, `sha-<commit>`, `vX.Y.Z`, `X.Y`, `X.Y.Z` |

Both registries receive the full tag set on every push to `main` and on every `v*` tag push, and both carry the same **multi-arch** platform set (`linux/amd64`, `linux/arm64`). Docker Hub is mirrored with `buildx imagetools create` so the manifest list — not just the runner's own architecture — is copied; CI asserts both platforms are present on both registries.

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
| `SIMPLEX_TOR` | `false` | Route through a local SOCKS5 proxy at `:9050` (e.g. Tor). See caveat below |
| `SIMPLEX_SOCAT_PORT` | (empty) | Set to e.g. `5226` to expose WebSocket on all interfaces via socat bridge (must differ from 5225). ⚠️ **Unauthenticated** — trusted networks only |
| `SIMPLEX_STARTUP_TIMEOUT` | `15` | Seconds to wait for the daemon to bind port 5225 before failing. Raise on slow/emulated ARM |
| `PUID` | `99` | User ID for file permissions (Unraid: 99) |
| `PGID` | `100` | Group ID for file permissions (Unraid: 100) |
| `TZ` | `UTC` | Container timezone |

> ⚠️ **`SIMPLEX_TOR` caveat:** it passes simplex-chat's `-x`, which selects a **local SOCKS5 proxy at `:9050`** — it does not itself start or configure Tor. It only routes over Tor if that SOCKS5 proxy is a Tor instance. Onion-only server routing additionally requires simplex-chat's `--socks-mode`/`--host-mode` options, which this image does not set. Verify your traffic is actually onion-routed before relying on it.

### Network Configuration

The daemon binds to `127.0.0.1:5225` only (security by design). **Both containers need host networking** — simplex-bridge **and** Hermes Agent must use `--network host` (or `network_mode: host` in Compose) so they share the same loopback interface and Hermes can reach `ws://127.0.0.1:5225`.

The Unraid template defaults to host networking for simplex-bridge.

**Bridge networking via socat**: Set `SIMPLEX_SOCAT_PORT=<port>` to start a socat proxy that exposes `0.0.0.0:<port>` → `127.0.0.1:5225`. **The port must be anything other than `5225`** — the daemon already binds `127.0.0.1:5225`, so socat's bind of the same port fails with "Address already in use" (use `5226`, for example). Then switch to bridge networking and publish that port: change the network type to `bridge` and map `-p <port>:<port>` (e.g. `-p 5226:5226`).

> ⚠️ The WebSocket API has no authentication. Exposing it on `0.0.0.0` makes it reachable from any IP that can reach the container — only do this on trusted networks or behind a firewall. Prefer host networking when both containers run on the same host.

#### Securing the socat port

Both recipes below were verified live against a **v1.0.1** image; the socat bridge and its options are unchanged since, but they have not been re-run against the current multi-arch image. A plain WebSocket upgrade request (`HTTP/1.1 101`) succeeds through each mitigation, and unauthorized paths are blocked. Re-verify with the `curl` commands shown if you depend on them.

**Option A — loopback-only publish + firewall allowlist (recommended, no extra software)**

Publish socat's port bound to loopback only, then open it selectively with a firewall rule. Even with no firewall configured, binding to `127.0.0.1` already prevents any other host from reaching the port (verified: connection refused from the host's LAN IP):

```bash
# Bind publish to loopback only — unreachable from other hosts by construction
docker run -d --name simplex-bridge \
  -p 127.0.0.1:5226:5226 \
  -e SIMPLEX_SOCAT_PORT=5226 \
  ghcr.io/libre-7/simplex-bridge:latest

# Verify only loopback answers (expect HTTP/1.1 101):
curl -i -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  http://127.0.0.1:5226/

# If remote clients DO need access, add an iptables allowlist instead of
# publishing on 0.0.0.0 (Docker's DOCKER-USER chain survives restarts):
sudo iptables -I DOCKER-USER -p tcp --dport 5226 ! -s 192.168.1.0/24 -j DROP
```

On Unraid, the equivalent is to leave the container's Network Type on `bridge`, keep the published port mapped as above (`127.0.0.1` in the custom mapping), or keep host networking and use Settings → Network Services / firewall rules to restrict port 5225/5226 to trusted subnets. On a Tailscale/WireGuard tailnet, publish on `127.0.0.1` and let clients reach the port through a tailscale serve forward (`tailscale serve --bg --tcp 5226 tcp://127.0.0.1:5226`) so only tailnet peers can connect.

**Option B — nginx basic-auth reverse proxy (auth front for untrusted networks)**

An nginx sidecar adds HTTP Basic auth in front of the WebSocket while preserving the upgrade handshake (both verified below):

```bash
# Shared network so nginx can resolve the bot container by name
docker network create simplex-net

# Bot: socat exposed ONLY inside the shared network (no -p publish at all)
docker run -d --name simplex-bridge --network simplex-net \
  -e SIMPLEX_SOCAT_PORT=5226 \
  ghcr.io/libre-7/simplex-bridge:latest

mkdir -p ./secnginx && cd ./secnginx
printf 'botuser:%s\n' "$(openssl passwd -apr1 'CHANGE-ME')" > .htpasswd
```

`nginx.conf`:

```nginx
worker_processes 1;
events {}
http {
  map $http_upgrade $connection_upgrade { default upgrade; "" close; }
  include /etc/nginx/mime.types;
  include /etc/nginx/conf.d/*.conf;
}
```

`conf.d/default.conf`:

```nginx
server {
  listen 8080;
  location / {
    auth_basic "SimpleX Bot";
    auth_basic_user_file /etc/nginx/.htpasswd;
    proxy_pass http://simplex-bridge:5226;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;   # long-lived bot socket
  }
}
```

Start and verify:

```bash
docker run -d --name simplex-auth --network simplex-net -p 8080:8080 \
  -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/conf.d/default.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v "$PWD/.htpasswd:/etc/nginx/.htpasswd:ro" nginx:alpine

curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/          # -> 401 (no creds)
curl -s -o /dev/null -w '%{http_code}\n' -u botuser:wrong \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" http://localhost:8080/                 # -> 401 (bad creds)
curl -s -i -u botuser:'CHANGE-ME' \
  -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" http://localhost:8080/ | head -1       # -> HTTP/1.1 101 WebSocket Protocol Handshake
```

Point Hermes Agent at `ws://<proxy-host>:8080` with the same credentials embedded as `ws://botuser:CHANGE-ME@<proxy-host>:8080`. Note that Basic auth over plain HTTP sends credentials base64-encoded — terminate TLS in front of nginx (e.g. Caddy automatic HTTPS or nginx `listen 443 ssl`) when the path leaves your LAN.

### Tagging & Pinning

For production stability, pin to a SHA tag (immutable):

```yaml
# docker-compose.yml
image: ghcr.io/libre-7/simplex-bridge:sha-a1b2c3d
```

SHA tags never change — the same commit always produces the same binary. The `latest` tag follows `main`.

## Integration with Hermes Agent

Hermes Agent v0.16.0+ (v2026.6.5+) ships a SimpleX Chat platform plugin. **Hermes Agent v0.20.0+ (v2026.8.3) includes the DM send fix natively** — the adapter's `send()` and `_standalone_send()` both use the structured `/_send @<id> json [...]` format for direct messages. No patching needed.

For older Hermes builds (v0.16.x–v0.19.x), the adapter had a bug ([upstream issue #46265](https://github.com/NousResearch/hermes-agent/issues/46265)): outbound DMs used the CLI shortcut format `@<id> text`, which the simplex-chat daemon silently rejects over WebSocket — it resolves `@<id>` as a display-name lookup, not a contactId lookup. Replies appeared in the Hermes WebUI but never reached the SimpleX app.

This one-command setup script installs `websockets` and **verifies** the adapter's DM send path already uses the structured `/_send … json` format. It never modifies the adapter: on an unrecognised version it **exits non-zero** and tells you to upgrade Hermes. See [One-command setup](#one-command-setup) below.

### One-command setup

```bash
curl -fsSL https://raw.githubusercontent.com/libre-7/simplex-bridge/main/install-websockets.sh | bash
docker exec hermes-webui /app/venv/bin/hermes gateway restart
```

The script:
1. Installs the `websockets` Python package (not bundled in the Hermes image), **pinned to the same version the bridge image ships** (`17.0.1`; override with `WEBSOCKETS_VERSION=`)
2. Verifies the adapter's DM send path already uses the structured `/_send … json` format, and **exits non-zero** if the adapter is an unrecognised version
3. Verifies the plugin is discoverable

> ⚠️ **The script installs into the gateway's virtualenv, not the system Python.** The Hermes gateway runs `/app/venv/bin/python3`, and that venv is created with `include-system-site-packages = false`. Installing `websockets` with a bare `pip` (or into `~/.local`) puts it somewhere the gateway **cannot import**, so the platform fails to load even though the install appeared to succeed. The script therefore resolves the venv interpreter explicitly (`/app/venv`, override with `HERMES_VENV=`) and uses it for both the install and the verification. If it cannot find that interpreter it says so loudly rather than silently falling back.

> **The script no longer patches the adapter.** Older versions of this script rewrote `adapter.py` in place with `sed -i` to work around [upstream issue #46265](https://github.com/NousResearch/hermes-agent/issues/46265). That patching was removed: it silently no-op'd once the adapter was refactored (so it "succeeded" while doing nothing), a bad edit could raise a `SyntaxError` that breaks the gateway's plugin import, and container rebuilds reverted it anyway. The upstream fix has shipped natively since Hermes 0.20.0 — upgrade rather than patch.

**Re-run after every Hermes container update or rebuild** — `websockets` is installed into the ephemeral container image and the auto-detect/patch step re-evaluates the installed adapter.

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

This mirrors the [`docker-compose.yml`](docker-compose.yml) shipped in the repo, pinned to the immutable v1.3.1 release by digest:

```yaml
services:
  simplex-bridge:
    image: ghcr.io/libre-7/simplex-bridge@sha256:07ab3f85082a3d47b0c1baac5095fc97a1d010bea482079ac703903713b737cf # v1.3.1
    container_name: simplex-bridge
    network_mode: host
    # The entrypoint starts as root because it must chown /data and use
    # gosu to drop privileges — so these three caps are required even
    # with everything else dropped. Removing them makes the container
    # abort at startup.
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp
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
| Repository | `ghcr.io/libre-7/simplex-bridge:v1.3.1` |
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
`linux/amd64` and `linux/arm64`. The image is published as a multi-arch manifest list, and the Dockerfile selects the matching `simplex-chat` release asset (`simplex-chat-ubuntu-24_04-x86_64` or `-aarch64`) and verifies its per-arch SHA256 at build time. Both registries carry the same platform set.

**Q: How is this different from a Telegram/Discord bot?**
SimpleX has no central servers that know who users are. No phone numbers, no usernames, no IPs logged. Your bot exists on a peer-to-peer network where only your contacts know it exists.

**Q: What port does this use?**
Port 5225 for the WebSocket API. Host networking is required — no port mapping is needed (both containers share loopback).

**Q: Can I run multiple bots?**
Not within one container. The WebSocket port is fixed at 5225 — there is no port variable. To run multiple bots, run separate containers, each with its own `/data` volume and its own network namespace (e.g. separate hosts/VMs). If you use the bridge networking mode, distinct published ports via `SIMPLEX_SOCAT_PORT` are possible (use a port other than 5225; see Network Configuration) — but note that socat mode is unauthenticated; see the warnings in Network Configuration.

## Testing

The regression tests need neither Docker nor network access:

```bash
bash tests/run-all.sh
```

This runs shellcheck, syntax and parse checks, and four suites that cover the
startup readiness gate, the Hermes installer, the first-run setup handshake, and
documentation/pin consistency. `tests/test-installer-interpreter.sh` needs a
Hermes installation to exercise interpreter detection and **skips** (exit 77)
elsewhere; the rest run anywhere.

They are also wired into the `lint` CI job, so a regression fails the build
rather than waiting for a runtime symptom.

## Building from Source

```bash
docker build -t simplex-bridge .
docker run --rm --network host -v $PWD/data:/data simplex-bridge
```

## License

This project is licensed under the GNU General Public License v3.0 (see [`LICENSE`](LICENSE)).

### Bundled third-party components

The container image redistributes prebuilt binaries that carry **their own licenses**, which are not superseded by this project's license:

| Component | License | Source |
|-----------|---------|--------|
| [simplex-chat](https://github.com/simplex-chat/simplex-chat) `v7.0.2` binary | **AGPL-3.0** | https://github.com/simplex-chat/simplex-chat/releases/tag/v7.0.2 |
| [simplexmq](https://github.com/simplex-chat/simplexmq) (linked into the above) | **AGPL-3.0** | https://github.com/simplex-chat/simplexmq |
| [gosu](https://github.com/tianon/gosu) `1.19` | MIT | https://github.com/tianon/gosu |

Both `simplex-chat` and `simplexmq` are **AGPL-3.0**. Because this image runs a network service built from AGPL components, the corresponding source is available at the links above, as AGPL-3.0 §13 requires. The image's `org.opencontainers.image.licenses` label is set to `AGPL-3.0` to reflect the terms of the redistributed binaries.

## Tags Reference

| Tag | When | Stability |
|-----|------|-----------|
| `latest` | Every push to `main` | Rolling |
| `sha-<commit>` | Every push to `main` | ✅ Immutable |
| `vX.Y.Z` | Git tag pushed | ✅ Immutable, versioned |
