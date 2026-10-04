# Changelog

All notable changes to this project are documented here.
Versions are image releases; the `vX.Y.Z` git tag builds the same image.

## [1.3.1] — 2026-10-04

Remediation of the 2026-10-03 code review. No image behaviour change for
correctly-configured deployments; two of these fixes change failure modes from
"silently wrong" to "loudly wrong".

**Upgrade note:** if you ran `install-websockets.sh` on v1.3.0 or earlier, re-run
it after upgrading. That script installed `websockets` into the wrong Python
(see the first entry below), so an install performed before this release leaves
a broken SimpleX platform in place even on the fixed image.

### Fixed

- **`install-websockets.sh` installed `websockets` where the gateway could not
  import it.** The script used bare `pip` / `python3` via `docker exec`, but the
  gateway runs `/app/venv/bin/python3` in a venv created with
  `include-system-site-packages = false`. Packages landed in the system
  interpreter (or a user's `~/.local`), which is **not on the venv's
  `sys.path`** — so the script installed the dependency, verified it with the
  same wrong interpreter, reported success, and left the SimpleX platform
  unable to load. It now resolves the gateway interpreter explicitly
  (`HERMES_VENV`, default `/app/venv`) and uses it for both the install and the
  verification; the install is pinned to the image's `websockets` version
  (`WEBSOCKETS_VERSION`, default `17.0.1`) instead of tracking latest; and a
  missing venv produces a loud warning rather than a silent fallback.
- **The adapter check silently skipped.** It located the adapter with
  `import plugins.platforms.simplex.adapter` under the wrong interpreter, then
  fell back to `find /app/venv -path '*/simplex/adapter.py'` — which returns
  nothing on a current Hermes layout, where the plugin lives in a source
  checkout (`/app/hermes-agent-src`). The script printed "skipping DM send
  verification" and exited 0, so the verification added in v1.3.0 never ran. It
  now imports with the gateway interpreter and falls back to a filesystem-wide
  search, and it says on stderr that an unverified state is not a verified one.
- **Readiness gates matched any port *containing* the number.** Both the
  startup gate and the socat gate used `ss -tln | grep -q :5225`, an
  unanchored substring test that also matches 15225, 52250, 52251…. Under
  `network_mode: host` — which this project requires — `ss` lists the entire
  host's listening sockets, so an unrelated service could satisfy the gate and
  report the WebSocket API ready while the daemon was dead. A shared
  `port_listening()` helper now anchors on an exact port on **both** code paths:
  the `sport = :PORT` filter is re-verified with awk rather than trusted via
  `grep -q .`, because an `ss` that does not understand the filter prints the
  whole socket table and `grep -q .` would match any line.
- **First-run auto-accept targeted a hardcoded id and never checked the
  result.** `/_address_settings 1 …` used a literal `1`; the daemon's contract
  is `/_address_settings <userId> <json(settings)>` (bots/api/COMMANDS.md), and
  the id is now read from the `/user` (`activeUser`) response, with a
  `userContactLinkCreated` / `usersList` fallback. Success was detected by
  searching any event for the substring `userContactLinkUpdated`; it now
  correlates the `corrId` the daemon echoes (`Server.hs` wraps every response
  as `{corrId, resp}`). When no id can be determined the step is skipped with a
  warning rather than applied to a guessed profile.
- **`base-refresh.yml` could not succeed.** The digest step called `skopeo`,
  which is not installed on `ubuntu-latest` and had no install step, so the
  output could be empty — and with no `set -e` that failure was silent. It now
  uses the preinstalled `docker buildx imagetools inspect`, sets
  `set -euo pipefail`, and fails loudly on an empty digest instead of opening a
  PR with a blank value.
- **README contradicted itself about the installer.** Line 196 still described
  the removed `sed -i` adapter patching, fourteen lines below the note saying it
  was removed. Rewritten to match, plus a new warning explaining why the
  installer targets the gateway venv.
- **Unraid template floated `:latest`** while compose pinned a digest, so
  Unraid's Update button could silently jump versions. Now pinned to the
  release tag (a tag rather than a digest: the Unraid template schema does not
  reliably round-trip a digest through `Repository`). README install
  instructions updated to match.

### Added

- **`SECURITY.md`** — private vulnerability-reporting path, plus an explicit
  statement of the deployment model: the WebSocket API has **no
  authentication**, the default bind is loopback-only, and setting
  `SIMPLEX_SOCAT_PORT` removes that protection.
- **Regression tests** (`tests/`, no Docker required) covering the two High and
  one Medium code fixes, wired into the `lint` CI job so they cannot rot:
  - `test-port-gate.sh` — creates **real** TCP listeners and asserts
    `port_listening()` matches an exact port, including the decoy-port case and
    the no-`ss` fail-closed case.
  - `test-installer-interpreter.sh` — stubs `docker` and `pip` and asserts the
    installer uses only absolute venv paths, pins the version, finds an adapter
    outside the venv, and **fails** on an unrecognised adapter.
  - `test-setup-userid.py` — drives the real setup block from `entrypoint.sh`
    against a fake WebSocket daemon, including a wrong-`corrId` decoy that the
    old substring match would have accepted as success.
  - `check-docs.py` — version/digest pin agreement across README, compose, and
    the Unraid template, and that documented env vars exist in code.
  - `run-all.sh` — runs every gate.

### Verified

- All three behavioural test suites were checked against deliberately
  re-introduced versions of each bug (mutation testing) and failed as expected,
  then passed again on restore — so they detect the defects they guard.
- `shellcheck` clean across `entrypoint.sh`, `install-websockets.sh`, and
  `tests/*.sh`.
- The published image was checked, not just its CI status: `entrypoint.sh`
  extracted from the `linux/amd64` layer matches the released source
  byte-for-byte, and both old defects (the substring port grep, the literal
  `/_address_settings 1`) are absent.
- Release image verified on **both** registries, which agree on the index digest
  (`sha256:74d14437…`) and carry `linux/amd64` + `linux/arm64`.
- **A note on digests and reproducibility.** v1.3.1's `rootfs.diff_ids` are
  *identical* to the post-merge build, yet the index digest differs — only the
  OCI metadata labels change (`version`, `created`, `revision`), and those are
  part of the config, hence the manifest, hence the digest. So a content-only
  comparison will report two "different" images for the same bits. Pin the digest
  the tag actually resolves to; do not carry one forward by hand.
- **Deployed and started successfully on a production Unraid host.** This is
  runtime proof that the reworked `port_listening()` gate returns true — a gate
  that never did would have spun until `SIMPLEX_STARTUP_TIMEOUT`.

### Not verified

- The production run above exercised **container startup**, not the SimpleX
  platform end to end. A container can start while the platform still cannot
  import `websockets` (that is F1's whole failure mode), so confirm the
  platform itself loads and DMs send.
- First-run auto-accept against **live SMP servers**, and real-silicon ARM64
  (CI covers ARM64 under emulation only), remain unproven here.

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