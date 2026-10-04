#!/bin/bash
# install-websockets.sh — Install websockets for SimpleX Chat.
#
# Always installs the 'websockets' Python package (required by any
# app that connects to the simplex-chat daemon via WebSocket).
#
# If the target container is running Hermes Agent, it also REPORTS on the
# state of the SimpleX adapter's DM send path. It does not modify it.
#
# History: this script used to sed-patch adapter.py to fix the DM send path
# (upstream hermes-agent issue #46265, fixed natively in Hermes 0.20.0+).
# That patching was removed because it no longer works and could do damage:
#   - the adapter was refactored to a `_send_cmd()` helper, so neither the
#     "already fixed" pattern nor the "needs patching" pattern matched and
#     both sed commands were silent no-ops while the script still exited 0;
#   - a `sed -i` multi-line edit into installed site-packages risks a
#     SyntaxError that breaks the gateway's plugin import entirely;
#   - it mutated the container filesystem, so every rebuild silently reverted it.
# The adapter now builds `/_send <target> json [...]` structurally, so the
# correct check is a read-only assertion — not a rewrite.
#
# Usage: bash install-websockets.sh [container-name]
#   Default container: hermes-webui
#
# Then restart the gateway:
#   docker exec <container> /app/venv/bin/hermes gateway restart
#
# Exit codes: 0 = websockets installed, adapter DM path verified.
#             1 = websockets install failed, or adapter state unrecognised.

set -e
C="${1:-hermes-webui}"

# ── Resolve the interpreter that actually runs the gateway ──────────
# The gateway is `/app/venv/bin/hermes`, so it runs under /app/venv's
# Python, NOT whatever `python3` resolves to on PATH. The venv is created
# with `include-system-site-packages = false`, so packages installed into
# the system interpreter (/usr/local/lib/python3.12/site-packages) or into
# a user's ~/.local tree are INVISIBLE to it. Installing via bare `pip`
# and then verifying via bare `python3` therefore "succeeds" while the
# gateway is still missing the dependency — the exact silent-failure this
# script exists to avoid. Resolve the venv explicitly and use it for both
# the install and the verification.
#
# If the venv is missing (a non-standard Hermes install), fall back to
# bare `python3` but say so loudly, so the result is never mistaken for a
# verified one.
GATEWAY_VENV="${HERMES_VENV:-/app/venv}"
if docker exec "$C" test -x "$GATEWAY_VENV/bin/python3" 2>/dev/null; then
    PY="$GATEWAY_VENV/bin/python3"
else
    PY="python3"
    echo "⚠ $GATEWAY_VENV/bin/python3 not found in '$C' — falling back to bare 'python3'." >&2
    echo "  If the gateway runs from a virtualenv, websockets may have been" >&2
    echo "  installed somewhere it cannot import. Set HERMES_VENV to override." >&2
fi

echo "=== Installing websockets for SimpleX Chat on container: $C ==="
echo "=== Target interpreter: $PY ==="
echo ""

# 1. Install websockets (universal — needed by any WebSocket client)
echo "[1/3] Installing websockets..."
# Pin to the same version the bridge image ships so the client library
# the bot uses matches the one its own healthcheck/setup code was tested
# against. Override with WEBSOCKETS_VERSION= to track a different pin.
WEBSOCKETS_VERSION="${WEBSOCKETS_VERSION:-17.0.1}"
# Prefer the venv's own pip so the install lands on the gateway's path.
PIP=""
if [ "$PY" != "python3" ]; then
    if docker exec "$C" test -x "$(dirname "$PY")/pip" 2>/dev/null; then
        PIP="$(dirname "$PY")/pip"
    fi
fi
[ -n "$PIP" ] || PIP="pip"

# Images that mark Python externally-managed (PEP 668) reject a plain
# `pip install`; the Hermes image is one of them. Try the normal form
# first, then --break-system-packages, and fail loudly if both fail
# rather than dying silently under `set -e`.
if ! docker exec "$C" "$PIP" install -q "websockets==$WEBSOCKETS_VERSION" 2>/dev/null; then
  if ! docker exec "$C" "$PIP" install -q --break-system-packages "websockets==$WEBSOCKETS_VERSION" 2>/dev/null; then
    # Show the real error now that we've exhausted the fallbacks
    docker exec "$C" "$PIP" install --break-system-packages "websockets==$WEBSOCKETS_VERSION" || {
      echo "  ✗ Failed to install websockets in container '$C'." >&2
      echo "    Check the container is running and pip is available: docker exec $C which $PIP" >&2
      exit 1
    }
  fi
fi

# Verify with the SAME interpreter the gateway uses. Verifying with a
# different one is what made this script report success over a broken
# gateway — so this check is load-bearing, not cosmetic.
if ! docker exec "$C" "$PY" -c \
  "import websockets; print('  → websockets', websockets.__version__, '->', websockets.__file__)" 2>/dev/null; then
    echo "  ✗ websockets installed but NOT importable by $PY." >&2
    echo "    The gateway will fail to load the SimpleX platform." >&2
    exit 1
fi

# 2. Check if this is a Hermes Agent container
echo "[2/3] Checking for Hermes Agent..."
IS_HERMES=false
docker exec "$C" "$PY" -c "import hermes_cli" 2>/dev/null && IS_HERMES=true

if [ "$IS_HERMES" = true ]; then
    echo "  → Hermes Agent detected"

    # Locate the adapter — with the gateway interpreter, which is the one
    # that can import it. The plugin may live in the venv's site-packages
    # OR in an editable/source checkout (hermes installs itself as an
    # editable package pointing at a source tree), so the find fallback
    # deliberately searches more than just the venv.
    ADAPTER=$(docker exec "$C" "$PY" -c "
import plugins.platforms.simplex.adapter as m
print(m.__file__)
" 2>/dev/null) || ADAPTER=$(docker exec "$C" sh -c '
find / -name adapter.py -path "*simplex*" -type f 2>/dev/null | head -1
' 2>/dev/null)

    if [ -n "$ADAPTER" ]; then
        echo "  → adapter: $ADAPTER"
        # Read-only structural check. Two shapes are known-good:
        #   (a) current adapter: a `_send_cmd()` helper returning
        #       f"/_send {target} json {json.dumps(items)}";
        #   (b) older fixed adapter: >=2 inline `cmd_str = f"/_send @...`
        #       assignments across send() and _standalone_send().
        # Anything else is an unrecognised version — reported, never patched.
        SHAPE=$(docker exec "$C" grep -c -e 'def _send_cmd' -e 'cmd_str = f"/_send @' "$ADAPTER" 2>/dev/null | tr -d '[:space:]')
        HITS=$(docker exec "$C" grep -c 'cmd_str = f"/_send @' "$ADAPTER" 2>/dev/null | tr -d '[:space:]')
        if [ "${SHAPE:-0}" -ge 1 ] || [ "${HITS:-0}" -ge 2 ]; then
            echo "  ✓ Adapter DM send path uses the structured /_send format — no action needed"
        else
            echo "  ✗ Unrecognised adapter DM send path in $ADAPTER" >&2
            echo "    This script no longer patches adapters (the old sed edit could" >&2
            echo "    corrupt installed source and was reverted on every rebuild)." >&2
            echo "    Upgrade Hermes to 0.20.0+ for the native fix, or send the" >&2
            echo "    adapter to https://github.com/NousResearch/hermes-agent/issues/46265" >&2
            exit 1
        fi
    else
        echo "  ⚠ Simplex adapter not found — skipping DM send verification" >&2
        # Not fatal (a bot may be installed without the plugin), but it is
        # NOT a verified state either — say so, and say it on stderr.
        echo "    (verification skipped: this is not a confirmed-good adapter)" >&2
    fi

    # 3. Verify plugin is discoverable
    echo "[3/3] Verifying plugin..."
    if ! docker exec "$C" "$PY" -c "
from hermes_cli.gateway import _all_platforms
simplex = [p for p in _all_platforms() if p['key'] == 'simplex']
if simplex:
    print('  → SimpleX plugin registered in Hermes gateway')
else:
    print('  ✗ SimpleX plugin NOT found')
    raise SystemExit(1)
" 2>/dev/null; then
        echo "  ✗ SimpleX plugin is not registered in the gateway." >&2
        echo "    websockets is installed, but the platform will not start." >&2
        exit 1
    fi

    echo ""
    echo "=== Done ==="
    echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
    echo "Then verify:    docker exec $C /app/venv/bin/hermes gateway status"
else
    echo "  → Not a Hermes Agent container — skipping adapter check"
    echo ""
    echo "=== Done ==="
fi