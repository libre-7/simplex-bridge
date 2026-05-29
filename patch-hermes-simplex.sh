#!/bin/bash
# patch-hermes-simplex.sh — Enable SimpleX Chat in Hermes Agent.
#
# What this script does (for a clean Hermes install):
#
# 1. Install 'websockets' Python package (not bundled in Hermes)
# 2. Copy plugin.yaml to site-packages if missing (wheel sometimes drops it)
# 3. Patch 3 bugs in the upstream SimpleX adapter that prevent messaging:
#    a) Missing /_start subscribe — daemon never pushes events
#    b) Wrong chatItems JSON path — inbound messages silently dropped
#    c) Wrong send format — outbound replies fail with contactNotFound
#
# The adapter was introduced in Hermes v0.14.0 (v2026.5.16).
# None of these bugs are fixed upstream as of v0.15.2 (v2026.5.29.2).
# Fix PRs: #26433, #27978 (both open/unmerged).
#
# Usage: bash patch-hermes-simplex.sh [container-name]
#   Default container: hermes-webui
#
# Run after recreating the Hermes WebUI container.
# Then restart the gateway: docker exec <container> /app/venv/bin/hermes gateway restart

set -e
C="${1:-hermes-webui}"

echo "=== Enabling SimpleX Chat plugin on container: $C ==="

# ---------------------------------------------------------------------------
# Step 1: Install websockets dependency
# ---------------------------------------------------------------------------
echo "[1/4] Installing websockets Python package..."
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null

docker exec "$C" python3 -c \
  "import websockets; print('  → websockets', websockets.__version__)" \
  2>/dev/null || {
  echo "  → FAILED to install websockets"
  exit 1
}

# ---------------------------------------------------------------------------
# Step 2: Copy plugin.yaml if missing from site-packages
# ---------------------------------------------------------------------------
echo "[2/4] Ensuring plugin.yaml is in site-packages..."
SRC_YAML="/home/hermeswebui/.hermes/hermes-agent/plugins/platforms/simplex/plugin.yaml"
DST_DIR="/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/"

if docker exec "$C" test -f "$DST_DIR/plugin.yaml" 2>/dev/null; then
  echo "  → plugin.yaml already present"
else
  docker exec "$C" cp "$SRC_YAML" "$DST_DIR/plugin.yaml" 2>/dev/null
  if docker exec "$C" test -f "$DST_DIR/plugin.yaml" 2>/dev/null; then
    echo "  → plugin.yaml copied"
  else
    echo "  → FAILED to copy plugin.yaml"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: Patch adapter.py — 3 bugs that prevent bidirectional messaging
# ---------------------------------------------------------------------------
echo "[3/4] Patching adapter.py (3 bugs)..."
ADAPTER="/app/venv/lib/python3.12/site-packages/plugins/platforms/simplex/adapter.py"

# Verify the adapter file exists
docker exec "$C" test -f "$ADAPTER" || {
  echo "  → adapter.py not found at $ADAPTER"
  exit 1
}

# --- Patch 3a: Send /_start after WebSocket connects so daemon pushes events
echo "  → Applying patch 1/3: /_start subscribe..."
docker exec "$C" python3 -c "
import sys
with open('$ADAPTER', 'r') as f:
    code = f.read()

old = '''                    logger.info(\"SimpleX WS: connected\")

                    async for raw in ws:'''

new = '''                    logger.info(\"SimpleX WS: connected\")
                    await ws.send(json.dumps({\"corrId\": \"hermes-init\", \"cmd\": \"/_start\"}))

                    async for raw in ws:'''

if old not in code:
    print('  ✗ Patch 1: target text not found. Aborting.')
    sys.exit(1)

code = code.replace(old, new, 1)
with open('$ADAPTER', 'w') as f:
    f.write(code)
print('  ✓ Patch 1 applied')
" || exit 1

# --- Patch 3b: Fix chatItems nesting — event.get("resp",{}).get("chatItems")
echo "  → Applying patch 2/3: chatItems JSON path..."
docker exec "$C" python3 -c "
import sys
with open('$ADAPTER', 'r') as f:
    code = f.read()

old = '''        elif resp_type == \"newChatItems\":
            # Batch variant — process each item
            items = event.get(\"chatItems\") or []
            for item_wrapper in items:'''

new = '''        elif resp_type == \"newChatItems\":
            # Batch variant — process each item
            items = event.get(\"resp\", {}).get(\"chatItems\") or []
            for item_wrapper in items:'''

if old not in code:
    print('  ✗ Patch 2: target text not found. Aborting.')
    sys.exit(1)

code = code.replace(old, new, 1)
with open('$ADAPTER', 'w') as f:
    f.write(code)
print('  ✓ Patch 2 applied')
" || exit 1

# --- Patch 3c: Fix send format — /_send @{id} json [...] not @[{id}] text
echo "  → Applying patch 3/3: send format (send + standalone_send)..."
docker exec "$C" python3 -c "
import sys
with open('$ADAPTER', 'r') as f:
    code = f.read()

# Fix 3c-i: SimplexAdapter.send() — uses 'content' parameter
old_send = '''        if chat_id.startswith(\"group:\"):
            group_id = chat_id[6:]
            cmd_str = f\"#[{group_id}] {content}\"
        else:
            cmd_str = f\"@[{chat_id}] {content}\"

        payload = {'''

new_send = '''        if chat_id.startswith(\"group:\"):
            group_id = chat_id[6:]
            chat_ref = f\"#{group_id}\"
        else:
            chat_ref = f\"@{chat_id}\"
        cmd_str = f\"/_send {chat_ref} json \" + json.dumps([{\"msgContent\": {\"type\": \"text\", \"text\": content}, \"mentions\": {}}])

        payload = {'''

if old_send not in code:
    print('  ✗ Patch 3 (send): target text not found.')
    sys.exit(1)

code = code.replace(old_send, new_send, 1)

# Fix 3c-ii: _standalone_send() — uses 'message' parameter
old_standalone = '''    try:
        if chat_id.startswith(\"group:\"):
            group_id = chat_id[6:]
            cmd_str = f\"#[{group_id}] {message}\"
        else:
            cmd_str = f\"@[{chat_id}] {message}\"

        payload = {'''

new_standalone = '''    try:
        if chat_id.startswith(\"group:\"):
            group_id = chat_id[6:]
            chat_ref = f\"#{group_id}\"
        else:
            chat_ref = f\"@{chat_id}\"
        cmd_str = f\"/_send {chat_ref} json \" + json.dumps([{\"msgContent\": {\"type\": \"text\", \"text\": message}, \"mentions\": {}}])

        payload = {'''

if old_standalone not in code:
    print('  ✗ Patch 3 (standalone_send): target text not found.')
    sys.exit(1)

code = code.replace(old_standalone, new_standalone, 1)

with open('$ADAPTER', 'w') as f:
    f.write(code)
print('  ✓ Patch 3 applied (send + standalone_send)')
" || exit 1

# ---------------------------------------------------------------------------
# Step 4: Verify
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] Verification..."

# 4a: Check websockets
echo -n "  websockets: "
docker exec "$C" python3 -c "import websockets; print('✓', websockets.__version__)" 2>/dev/null || echo "✗"

# 4b: Check plugin.yaml in site-packages
echo -n "  plugin.yaml: "
docker exec "$C" test -f "$DST_DIR/plugin.yaml" && echo "✓" || echo "✗"

# 4c: Verify all 3 patches landed
echo -n "  Patch 1 (_start): "
docker exec "$C" python3 -c "
with open('$ADAPTER') as f:
    c = f.read()
if '\"/_start\"' in c:
    print('✓')
else:
    print('✗')
" 2>/dev/null

echo -n "  Patch 2 (chatItems path): "
docker exec "$C" python3 -c "
with open('$ADAPTER') as f:
    c = f.read()
if 'event.get(\"resp\", {}).get(\"chatItems\")' in c:
    print('✓')
else:
    print('✗')
" 2>/dev/null

echo -n "  Patch 3 (send format): "
docker exec "$C" python3 -c "
with open('$ADAPTER') as f:
    c = f.read()
if '/_send' in c and 'chat_ref' in c and 'json' in c:
    print('✓')
else:
    print('✗')
" 2>/dev/null

# 4d: Verify plugin discovery
echo -n "  gateway discovery: "
docker exec "$C" python3 -c "
from hermes_cli.gateway import _all_platforms
simplex = [p for p in _all_platforms() if p['key'] == 'simplex']
if simplex:
    print('✓ SimpleX registered')
else:
    print('✗ NOT found')
" 2>/dev/null || echo "  ⚠ (gateway CLI not importable — check plugin.yaml manually)"

echo ""
echo "=== Done ==="
echo "Next steps:"
echo "  1. Set env vars (SIMPLEX_WS_URL, SIMPLEX_ALLOWED_USERS, etc.) on the $C container"
echo "  2. Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
echo "  3. Verify:         docker exec $C /app/venv/bin/hermes gateway status"
