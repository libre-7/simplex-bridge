#!/bin/bash
# install-websockets.sh — Install websockets for SimpleX Chat in Hermes Agent v0.16.0+.
#
# The Simplex adapter that ships with Hermes Agent v0.16.0
# (v2026.6.5+) works out of the box. The only missing piece is the
# 'websockets' Python package, which is not bundled in the Hermes
# container image. This script installs it.
#
# No adapter code patches or plugin.yaml copies are needed.
#
# Usage: bash patch-hermes-simplex.sh [container-name]
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
echo "[1/1] Installing websockets..."
docker exec "$C" pip install -q websockets 2>/dev/null || \
  docker exec "$C" pip install websockets 2>/dev/null

# Verify
docker exec "$C" python3 -c \
  "import websockets; print('  → websockets', websockets.__version__)" 2>/dev/null

# 2. Verify plugin is discoverable
echo ""
echo "=== Verification ==="
docker exec "$C" python3 -c "
from hermes_cli.gateway import _all_platforms
simplex = [p for p in _all_platforms() if p['key'] == 'simplex']
if simplex:
    print('✓ SimpleX plugin registered in Hermes gateway')
else:
    print('✗ SimpleX plugin NOT found')
    exit(1)
" 2>/dev/null

echo ""
echo "=== Done ==="
echo "Restart gateway: docker exec $C /app/venv/bin/hermes gateway restart"
echo "Then verify:    docker exec $C /app/venv/bin/hermes gateway status"