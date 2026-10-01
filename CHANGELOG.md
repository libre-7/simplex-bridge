# Changelog

All notable changes to this project are documented here.
Versions are image releases; the `vX.Y.Z` git tag builds the same image.

## [1.3.0] — 2026-10-01

Multi-arch release plus remediation of a full code review (2026-09-29).

### Added

- **Multi-arch images: `linux/amd64` and `linux/arm64`.** The previous
  "amd64 only" claim was incorrect — upstream `simplex-chat` has published an
  aarch64 binary since at least v7.0.0. The Dockerfile now selects the release
  asset **and** its SHA256 per `TARGETARCH`, and `gosu` resolves `gosu-${arch}`
  instead of hardcoding `gosu-amd64`. Both digests come from the v7.0.2 release
  notes. `TARGETARCH` falls back to `uname -m` so plain `docker build` still
  works.
- **`SIMPLEX_STARTUP_TIMEOUT`** (default `15`, input-validated) for slow or
  emulated ARM hosts.
- **CI smoke job is a platform matrix** with QEMU for arm64, using the same
  `cap_drop: ALL` + `CHOWN/SETUID/SETGID` + `no-new-privileges` set as
  `docker-compose.yml`, plus a longer healthcheck budget for emulation.
- **Cross-registry platform verification** in CI, asserting both platforms are
  present on both GHCR and Docker Hub.
- GitHub Releases now exist (F6). This release is the first.

### Fixed

- **First-run bot detection checked a path that can never exist.** `-d/--database`
  is a *file prefix* upstream — the CLI appends `_chat.db` itself — so
  `-d /data/simplex` creates `/data/simplex_chat.db`. The entrypoint was checking
  `/data/simplex_v1_chat.db`, so the test was always true and
  `--create-bot-display-name` was passed on every start. This was latent
  (upstream gates profile creation on the database having no active user), but it
  now checks the real path rather than relying on an undocumented upstream detail.
- **`install-websockets.sh` no longer patches the Hermes adapter.** It `sed -i`'d
  `adapter.py` to work around hermes-agent#46265, but the adapter was refactored
  to a `_send_cmd()` helper, so both the "already fixed" and "needs patching"
  patterns matched nothing — the script silently no-op'd, printed a warning, and
  **exited 0**. It now performs a read-only structural check and exits non-zero on
  an unrecognised adapter.
- **Docker Hub mirroring no longer collapses the manifest list.** The previous
  pull → retag → push resolved only the runner's amd64 manifest and would have
  replaced the multi-arch index with a single-arch image, breaking arm64 pulls.
  Now mirrored with `buildx imagetools create`.
- **`org.opencontainers.image.licenses` is now `AGPL-3.0` on the published
  image.** `docker/metadata-action` infers this label from the GitHub repo's
  license and overrides the Dockerfile `LABEL`, so the earlier AGPL correction was
  silently reverted in the artifact users pull. Now pinned in the workflow's
  `labels:` block.
- **gosu checksum verification can no longer pass on an empty match.** The
  `grep | sed` pipeline would exit 0 under `dash` (Ubuntu's `/bin/sh` has no
  `pipefail`), and `sha256sum -c` on a 0-byte file "verifies" nothing. Split into
  `grep > file` + `test -s`, which is strictly stronger.
- **The `build` job no longer reports success vacuously on pull requests.** Every
  publishing step is gated off on `pull_request`, so the job went green having
  published nothing; a "Report publishing scope" step now states which happened.
- Unraid template `<Changes>` and the Hermes minimum-version contradiction
  (0.16.0 vs 0.20.0) corrected.

### Changed

- `main` now requires **Hermes Agent 0.20.0+** and verifies the DM send path
  rather than patching it. Use the `compat-v0.14` branch for older versions.
- README `SIMPLEX_TOR` documentation corrected: it passes `-x`, which selects a
  local SOCKS5 proxy at `:9050`. It does not configure Tor, and onion-only routing
  requires `--socks-mode`, which this image does not set.

### Verified

- `simplex-chat` v7.0.2 binary run directly: database path is `simplex_chat.db`,
  the WebSocket API answers `HTTP/1.1 101`, and the kernel socket table confirms
  the daemon listens on `127.0.0.1` only — the project's central security claim,
  confirmed at runtime rather than by source reading.
- Post-merge: GHCR and Docker Hub both publish amd64 and arm64 with identical
  per-platform digests.

### Security notes

The WebSocket API has **no authentication**. The daemon binds `127.0.0.1` only,
so host networking (the default) is not exposed. Enabling `SIMPLEX_SOCAT_PORT`
publishes it on `0.0.0.0` — see the README's securing recipes.

The image redistributes AGPL-3.0 binaries (`simplex-chat`, `simplexmq`). This
project's own source remains GPL-3.0; the bundled components and their licenses
are listed in the README.

## [1.2.0] — 2026-09-27

Post-audit release: container startup fixes, refreshed `ubuntu:24.04` base image,
gosu 1.19, and CI that refuses to publish a container that never reaches healthy.
v1.1.0 and earlier shipped a `cap_drop: ALL` / no-`cap_add` combination that
aborted the container at startup — upgrade to v1.2.0 or later.

## [1.1.0]

Refused `SIMPLEX_SOCAT_PORT=5225` at startup instead of starting with a dead
bridge. `daemon.log` trimmed at boot and hourly.

## [1.0.1]

Documentation and socat bridge guidance.

## [1.0.0]

Initial Community Applications release.