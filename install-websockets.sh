#!/bin/bash
# install-websockets.sh — Install websockets for SimpleX Chat in Hermes Agent v0.16.0+.
#
# The Simplex adapter that ships with Hermes Agent v0.16.0
# (v2026.6.5+) has a bug in the DM send path: it uses the CLI
# shortcut format @<id> text, which the simplex-chat daemon
# silently rejects over WebSocket (the daemon resolves @<id>
# as a display name lookup, not a contactId lookup).
#
# This script:
#   1. Installs the 'websockets' Python package (not bundled)
#   2. Patches the adapter's DM send path to use the correct
#      /_send @<id> json [...] format
#   3. Verifies the plugin is discoverable
#
# Re-run after every Hermes container update or rebuild.
#
# Upstream issue: https://github.com/NousResearch/hermes-agent/issues/46265
#
# Usage: bash install-websockets.sh [container-name]
#   Default container: hermes-webui
#
# Then restart the gateway:
#   docker exec <container> /app/venv/bin/hermes gateway restart

set -e
C="${1:-hermes-webui}"

echo "=== Enabling SimpleX Chat plugin on container: $C ===
Target: Hermes Agent v0.16.0+ (v2026.6.5+)
"

# 1. Install websockets
echo "[1/3] Installing websockets..."
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null

# Verify
docker exec "$C" python3 -c \
  "import websockets; print('  → websockets', websockets.__version__)" 2>/dev/null

# 2. Patch the DM send path in the adapter
echo "[2/3] Patching adapter DM send path..."
ADAPTER=$(docker exec "$C" python3 -c "
import plugins.platforms.simplex.adapter as m
print(m.__file__)
" 2>/dev/null) || ADAPTER=""

if [ -z "$ADAPTER" ]; then
    # Fallback: find it
    ADAPTER=$(docker exec "$C" find /app/venv -path "*/simplex/adapter.py" -type f 2>/dev/null | head -1)
fi

if [ -n "$ADAPTER" ]; then
    # Patch send() — gateway reply path
    docker exec "$C" sed -i 's/cmd_str = f"@{chat_id} {content}"/composed = json.dumps([{"msgContent": {"type": "text", "text": content}}])\n                cmd_str = f"\/_send @{chat_id} json {composed}"/' "$ADAPTER" 2>/dev/null || true

    # Patch _standalone_send() — cron/send_message tool path
    docker exec "$C" sed -i 's/cmd_str = f"@{chat_id} {message}"/composed = json.dumps([{"msgContent": {"type": "text", "text": message}}])\n            cmd_str = f"\/_send @{chat_id} json {composed}"/' "$ADAPTER" 2>/dev/null || true

    # Verify patches landed
    HITS=$(docker exec "$C" grep -c 'cmd_str = f"/_send @' "$ADAPTER" 2>/dev/null || echo "0")
    if [ "$HITS" -ge 2 ]; then
        echo "  → DM send patch applied ($HITS/2 locations)"
    else
        echo "  ⚠ DM send patch may not be complete ($HITS/2 locations)"
    fi
else
    echo "  ⚠ Could not locate adapter.py — skipping patch"
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
