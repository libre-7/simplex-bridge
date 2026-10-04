# Security Policy

## Reporting a Vulnerability

**Please report security issues privately.** Do not open a public GitHub issue
for a vulnerability you have found.

Use GitHub's private reporting on the Security tab
(**Security → Report a vulnerability**), or email the maintainer via the address
listed on the repository profile.

Please include:

- What the issue is, and which component it affects (image, entrypoint,
  `healthcheck.py`, `install-websockets.sh`, or CI)
- The image tag or commit you tested (`docker buildx imagetools inspect
  ghcr.io/libre-7/simplex-bridge:<tag>`)
- Steps to reproduce, and the impact you believe it has
- Any proof-of-concept output you are willing to share

You can expect an acknowledgement within a few days. Confirmed issues are
fixed in a follow-up release, and the reporter is credited in the CHANGELOG
unless they prefer otherwise.

## Deployment model and threat surface

This project ships a **network service with no authentication of its own**.
Understanding that is the most important part of using it safely.

| Property | Status |
|---|---|
| WebSocket API authentication | **None.** Anyone who can reach the port can read and send as the bot. |
| Default bind | `127.0.0.1:5225` — loopback only. |
| Default exposure | None. Host networking keeps the port on the host's loopback interface. |
| `SIMPLEX_SOCAT_PORT` | **Disables the loopback-only default.** Publishes `0.0.0.0:<port>` with no authentication. |
| Container privileges | `cap_drop: ALL` plus only `CHOWN`, `SETUID`, `SETGID`; `no-new-privileges:true`; non-root runtime via `gosu`. |
| Supply chain | Digest-pinned base image; `simplex-chat` and `gosu` binaries SHA256-verified at build time; CI actions pinned by commit SHA; SBOM and provenance attestations published. |

### Guidance

- **Keep the default.** Use host networking and leave `SIMPLEX_SOCAT_PORT` empty.
  Both the bridge and Hermes Agent must share loopback for this to work.
- **Never expose the port directly to an untrusted network.** If a remote client
  must connect, put an authenticating reverse proxy in front of it. The README's
  [Securing the socat port](README.md#securing-the-socat-port) section gives
  working nginx basic-auth and firewall-allowlist recipes — and notes that Basic
  auth over plain HTTP is base64, not encryption, so terminate TLS in front.
- **Verify what you are pulling.** Prefer a `sha-<commit>` tag or a
  `@sha256:` digest. The `latest` tag moves with `main`.
- **Understand the bundled components.** The image redistributes `simplex-chat`
  and `simplexmq`, both **AGPL-3.0**. Vulnerabilities in those binaries are
  upstream's to fix; report them to
  [simplex-chat/simplex-chat](https://github.com/simplex-chat/simplex-chat/issues)
  as well. See the README's bundled-components table for versions and sources.

## Out of scope

- Exposure caused by a user deliberately setting `SIMPLEX_SOCAT_PORT` without a
  firewall or authenticating proxy.
- Vulnerabilities in upstream `simplex-chat`, `simplexmq`, or `gosu` — please
  report those upstream (though you are welcome to tell us how they affect this
  image).
- Weaknesses in SimpleX Chat's own protocol design, which are inherent to the
  upstream design rather than to this packaging.
