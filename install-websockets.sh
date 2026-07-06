#!/bin/bash
# install-websockets.sh — Install websockets for SimpleX Chat.
#
# Always installs the 'websockets' Python package (required by any
# app that connects to the simplex-chat daemon via WebSocket).
#
# If the target container is running Hermes Agent, also:
#   - Patches the adapter's DM send path (upstream bug #46265)
#   - Verifies the plugin is discoverable
#
# Upstream bug: https://github.com/NousResearch/hermes-agent/issues/46265
#   The Hermes adapter uses @<id> text (CLI shortcut) for DMs, which
#   the simplex-chat daemon silently rejects over WebSocket — it resolves
#   @<id> as a display name lookup, not a contactId lookup. The fix
#   rewrites both send() and _standalone_send() to use the correct
#   /_send @<id> json [...] format.
#
# Usage: bash install-websockets.sh [container-name]
#   Default container: hermes-webui
#
# Then restart the gateway:
#   docker exec <container> /app/venv/bin/hermes gateway restart

set -e
C="${1:-hermes-webui}"

echo "=== Installing websockets for SimpleX Chat on container: $C ==="
echo ""

# 1. Install websockets (universal — needed by any WebSocket client)
echo "[1/3] Installing websockets..."
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null

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
        echo "  Patching adapter DM send path..."

        # Patch send() — gateway reply path
        docker exec "$C" sed -i 's/cmd_str = f"@{chat_id} {content}"/composed = json.dumps([{"msgContent": {"type": "text", "text": content}}])\n                cmd_str = f"\/_send @{chat_id} json {composed}"/' "$ADAPTER" 2>/dev/null || true

        # Patch _standalone_send() — cron/send_message tool path
        docker exec "$C" sed -i 's/cmd_str = f"@{chat_id} {message}"/composed = json.dumps([{"msgContent": {"type": "text", "text": message}}])\n            cmd_str = f"\/_send @{chat_id} json {composed}"/' "$ADAPTER" 2>/dev/null || true

        # Verify
        HITS=$(docker exec "$C" grep -c 'cmd_str = f"/_send @' "$ADAPTER" 2>/dev/null || echo "0")
        if [ "$HITS" -ge 2 ]; then
            echo "  → DM send patch applied ($HITS/2 locations)"
        else
            echo "  ⚠ DM send patch may not be complete ($HITS/2 locations)"
        fi
    else
        echo "  ⚠ Simplex adapter not found — skipping patch"
    fi

    # 3. Verify plugin is discoverable
    echo "[3/3] Verifying plugin..."
    docker exec "$C" python3 -c "
from hermes_cli.gateway import _all_platforms
simplex = [p for p in _all_platforms() if p['key'] == 'simplex']
if simplex:
    print('  → SimpleX plugin registered in Hermes gateway')
else:
    print('  ✗ SimpleX plugin NOT found')
    exit(1)
" 2>/dev/null

    echo ""
    echo "=== Done ==="
    echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
    echo "Then verify:    docker exec $C /app/venv/bin/hermes gateway status"
else
    echo "  → Not a Hermes Agent container — skipping adapter patch"
    echo ""
    echo "=== Done ==="
fi
