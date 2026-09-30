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

echo "=== Installing websockets for SimpleX Chat on container: $C ==="
echo ""

# 1. Install websockets (universal — needed by any WebSocket client)
echo "[1/3] Installing websockets..."
# Images that mark Python externally-managed (PEP 668) reject a plain
# `pip install`; the Hermes image is one of them. Try the normal form
# first, then --break-system-packages, and fail loudly if both fail
# rather than dying silently under `set -e`.
if ! docker exec "$C" pip install -q websockets 2>/dev/null; then
  if ! docker exec "$C" pip install -q --break-system-packages websockets 2>/dev/null; then
    # Show the real error now that we've exhausted the fallbacks
    docker exec "$C" pip install --break-system-packages websockets || {
      echo "  ✗ Failed to install websockets in container '$C'." >&2
      echo "    Check the container is running and pip is available: docker exec $C which pip" >&2
      exit 1
    }
  fi
fi

docker exec "$C" python3 -c \
  "import websockets; print('  → websockets', websockets.__version__)" 2>/dev/null

# 2. Check if this is a Hermes Agent container
echo "[2/3] Checking for Hermes Agent..."
IS_HERMES=false
docker exec "$C" python3 -c "import hermes_cli" 2>/dev/null && IS_HERMES=true

if [ "$IS_HERMES" = true ]; then
    echo "  → Hermes Agent detected"

    # Locate the adapter
    ADAPTER=$(docker exec "$C" python3 -c "
import plugins.platforms.simplex.adapter as m
print(m.__file__)
" 2>/dev/null) || ADAPTER=$(docker exec "$C" find /app/venv -path "*/simplex/adapter.py" -type f 2>/dev/null | head -1)

    if [ -n "$ADAPTER" ]; then
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
        echo "  ⚠ Simplex adapter not found — skipping DM send verification"
    fi

    # 3. Verify plugin is discoverable
    echo "[3/3] Verifying plugin..."
    if ! docker exec "$C" python3 -c "
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