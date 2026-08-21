#!/bin/bash
set -e -o pipefail

DATA_DIR="/data"
DB_PREFIX="$DATA_DIR/simplex"
DB_FILE="${DB_PREFIX}_v1_chat.db"

# ── Resolve PUID/PGID ──────────────────────────────────────────────
PUID="${PUID:-99}"
PGID="${PGID:-100}"
echo "[entrypoint] Using PUID=$PUID PGID=$PGID"

# Recreate the 'simplex' user/group with the runtime-requested IDs
if getent group simplex >/dev/null 2>&1; then groupdel simplex 2>/dev/null || true; fi
if getent passwd simplex >/dev/null 2>&1; then userdel simplex 2>/dev/null || true; fi
groupadd --system --gid "$PGID" simplex 2>/dev/null || \
  groupadd --system simplex 2>/dev/null
useradd --system --no-log-init -g simplex -u "$PUID" --create-home simplex

# ── Graceful shutdown handler ──────────────────────────────────────
shutdown() {
    signal=$1
    echo "[entrypoint] Received $signal — forwarding to simplex-chat..."
    kill "-$signal" "$DAEMON_PID" 2>/dev/null || true
    for i in $(seq 1 10); do
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
            echo "[entrypoint] simplex-chat exited cleanly"
            break
        fi
        sleep 1
    done
    if [ -n "${SOCAT_PID:-}" ]; then
        kill "$SOCAT_PID" 2>/dev/null || true
    fi
    echo "[entrypoint] Goodbye"
    exit 0
}

trap 'shutdown SIGTERM' SIGTERM
trap 'shutdown SIGINT'  SIGINT

# ── Timezone ───────────────────────────────────────────────────────
if [ -n "$TZ" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# Fix data dir ownership so the runtime user can write to it
chown -R "$PUID:$PGID" "$DATA_DIR"

# ── Build extra flags (array — no shell re-parsing of env values) ──
FLAGS=(-d "$DATA_DIR/simplex" -p 5225)

if [ ! -f "$DB_FILE" ]; then
    echo "[entrypoint] First run: creating bot profile..."
    FLAGS+=(--create-bot-display-name "$SIMPLEX_DISPLAY_NAME")
    if [ "$SIMPLEX_FILES_ENABLED" = "true" ]; then
        FLAGS+=(--create-bot-allow-files)
    fi
fi

if [ "$SIMPLEX_MARK_READ" = "true" ]; then
    FLAGS+=(-r)
fi

if [ "$SIMPLEX_TOR" = "true" ]; then
    FLAGS+=(-x)
fi

# ── Start simplex-chat daemon as non-root user ─────────────────────
echo "[entrypoint] Starting simplex-chat daemon as UID $PUID..."
echo "[entrypoint]   simplex-chat ${FLAGS[*]}"

gosu "$PUID:$PGID" simplex-chat "${FLAGS[@]}" > "$DATA_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
echo "[entrypoint]   PID: $DAEMON_PID"

for i in $(seq 1 15); do
    if ss -tln 2>/dev/null | grep -q :5225; then
        echo "[entrypoint] WebSocket API ready on port 5225"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "[entrypoint] ERROR: simplex-chat failed to start within 15s"
        tail -10 "$DATA_DIR/daemon.log"
        kill "$DAEMON_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

SETUP_MARKER="$DATA_DIR/.setup-complete"
if [ ! -f "$SETUP_MARKER" ]; then
    sleep 2
    echo "[entrypoint] Setting up bot address..."
    SETUP_LOG="$DATA_DIR/setup.log"
    # Run as the daemon user; capture exit status explicitly — the sed pipe
    # would otherwise mask python's exit code (sed always exits 0).
    if gosu "$PUID:$PGID" python3 - <<'PYEOF' > "$SETUP_LOG" 2>&1
import asyncio, json, os, sys
import websockets

async def setup():
    async with websockets.connect('ws://127.0.0.1:5225', open_timeout=10) as ws:
        await ws.send(json.dumps({'corrId': 's1', 'cmd': '/user'}))
        await asyncio.sleep(1)
        await ws.send(json.dumps({'corrId': 's2', 'cmd': '/ad'}))
        await asyncio.sleep(2)
        address = None
        for _ in range(10):
            try:
                evt = await asyncio.wait_for(ws.recv(), timeout=1)
            except asyncio.TimeoutError:
                break
            data = json.loads(evt)
            resp = data.get('resp', {})
            if resp.get('type') == 'userContactLinkCreated':
                link = resp.get('connLinkContact', {})
                address = link.get('connFullLink', link.get('connShortLink', ''))
        if os.environ.get('SIMPLEX_AUTO_ACCEPT', 'true') == 'true':
            settings = json.dumps({'businessAddress': False, 'autoAccept': {'acceptIncognito': False}})
            await ws.send(json.dumps({'corrId': 's3', 'cmd': f'/_address_settings 1 {settings}'}))
            await asyncio.sleep(1)
            try:
                evt = await asyncio.wait_for(ws.recv(), timeout=2)
                if 'userContactLinkUpdated' in evt:
                    print('[setup] Auto-accept enabled')
            except asyncio.TimeoutError:
                pass
        if address:
            print(f'[setup] Bot address: {address[:80]}...')
            with open('/data/bot_address.txt', 'w') as f:
                f.write(address + '\n')
        else:
            print('[setup] ERROR: no contact link received — setup will retry on next start')
            sys.exit(1)

asyncio.run(setup())
PYEOF
    then
        sed 's/^/[setup] /' "$SETUP_LOG"
        touch "$SETUP_MARKER"
    else
        echo "[entrypoint] WARNING: first-run setup did not complete — will retry on next restart"
        tail -5 "$SETUP_LOG" | sed 's/^/[setup] /'
    fi
fi

# ── Optional socat bridge ──────────────────────────────────────────
# WARNING: When enabled, the WebSocket API becomes accessible from any
# IP that can reach the container on 0.0.0.0:$SIMPLEX_SOCAT_PORT.
# The simplex-chat WebSocket protocol has no built-in authentication.
# Only enable on trusted networks or behind a firewall.
# This feature is experimental — use at your own risk.
if [ -n "$SIMPLEX_SOCAT_PORT" ]; then
    case "$SIMPLEX_SOCAT_PORT" in
        ''|*[!0-9]*)
            echo "[entrypoint] ERROR: SIMPLEX_SOCAT_PORT must be a numeric TCP port (got: '$SIMPLEX_SOCAT_PORT')"
            exit 1
            ;;
    esac
    if [ "$SIMPLEX_SOCAT_PORT" -lt 1 ] || [ "$SIMPLEX_SOCAT_PORT" -gt 65535 ]; then
        echo "[entrypoint] ERROR: SIMPLEX_SOCAT_PORT must be between 1 and 65535 (got: $SIMPLEX_SOCAT_PORT)"
        exit 1
    fi
    echo "[entrypoint] *** WARNING: Exposing WebSocket API on 0.0.0.0:$SIMPLEX_SOCAT_PORT ***"
    echo "[entrypoint] *** No authentication — only use on trusted networks    ***"
    echo "[entrypoint] Starting socat bridge on 0.0.0.0:$SIMPLEX_SOCAT_PORT → 127.0.0.1:5225"
    socat "TCP-LISTEN:$SIMPLEX_SOCAT_PORT,reuseaddr,fork" TCP:127.0.0.1:5225 &
    SOCAT_PID=$!
    echo "[entrypoint]   socat PID: $SOCAT_PID"
fi

# ── Ready ──────────────────────────────────────────────────────────
echo ""
echo "=== SimpleX Bridge ready ==="
echo "  Bot name: $SIMPLEX_DISPLAY_NAME"
echo "  Running as: PUID=$PUID PGID=$PGID"
if [ -f "$DATA_DIR/bot_address.txt" ]; then
    echo "  Bot address: $(cat "$DATA_DIR/bot_address.txt")"
fi
echo ""

wait "$DAEMON_PID"
