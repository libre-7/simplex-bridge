#!/bin/bash
set -e -o pipefail

DATA_DIR="/data"
DB_PREFIX="$DATA_DIR/simplex"
# Upstream's `-d/--database` takes a FILE PREFIX, not a directory: the CLI
# appends "_chat.db"/"_agent.db" itself (simplex-chat Options/SQLite.hs).
# So `-d /data/simplex` yields /data/simplex_chat.db — there is no "_v1"
# unless we leave -d at its default, which resolves to
# $XDG_DATA_HOME/simplex/simplex_v1 and would not be under /data at all.
DB_FILE="${DB_PREFIX}_chat.db"

# ── Resolve PUID/PGID ──────────────────────────────────────────────
PUID="${PUID:-99}"
PGID="${PGID:-100}"
echo "[entrypoint] Using PUID=$PUID PGID=$PGID"

# Ensure the 'simplex' user/group matches the runtime-requested IDs.
# Only recreate if the existing user has a different UID/GID.
if getent passwd simplex >/dev/null 2>&1; then
    EXISTING_UID=$(id -u simplex 2>/dev/null)
    EXISTING_GID=$(id -g simplex 2>/dev/null)
    if [ "$EXISTING_UID" = "$PUID" ] && [ "$EXISTING_GID" = "$PGID" ]; then
        echo "[entrypoint] simplex user already has PUID=$PUID PGID=$PGID — no change needed"
    else
        echo "[entrypoint] Recreating simplex user (UID $EXISTING_UID → $PUID, GID $EXISTING_GID → $PGID)..."
        if getent group simplex >/dev/null 2>&1; then groupdel simplex 2>/dev/null || true; fi
        if getent passwd simplex >/dev/null 2>&1; then userdel simplex 2>/dev/null || true; fi
        groupadd --system --gid "$PGID" simplex 2>/dev/null || \
          groupadd --system simplex 2>/dev/null
        useradd --system --no-log-init -g simplex -u "$PUID" --create-home simplex
    fi
else
    groupadd --system --gid "$PGID" simplex 2>/dev/null || \
      groupadd --system simplex 2>/dev/null
    useradd --system --no-log-init -g simplex -u "$PUID" --create-home simplex
fi

# ── Port-readiness helper ──────────────────────────────────────────
# Match a LISTEN socket on an EXACT port. Never use a bare `grep -q :5225`
# against `ss` output: that is an unanchored substring test, so it also
# matches 15225, 52250, 52251… Under `network_mode: host` — which this
# project REQUIRES, because the daemon binds 127.0.0.1 and Hermes must
# share that loopback — `ss` lists the entire host's listening sockets, not
# just this container's. An unrelated host service on a port containing
# "5225" would therefore satisfy the startup gate and declare the
# WebSocket API ready while simplex-chat is still starting or already dead.
#
# BOTH branches below anchor on the exact port, and that is deliberate on
# both paths:
#   * `sport = :PORT` is a server-side filter, but we still re-check the
#     port in awk rather than trusting `grep -q .`. An `ss` that does not
#     understand the filter prints the WHOLE socket table and exits 0, so
#     `grep -q .` would match any line and report the wrong port as ready —
#     the very bug this helper exists to prevent.
#   * the no-filter call is the same story with the filter removed.
# Field 4 is Local Address:Port, so requiring the port to end the field is
# an exact match that tolerates any address form (IPv4, IPv6, wildcard).
port_listening() {
    local port="$1"
    ss -tlnH "sport = :$port" 2>/dev/null |
        awk -v p=":$port" '$4 ~ p"$" { found=1 } END { exit !found }' &&
        return 0
    ss -tlnH 2>/dev/null |
        awk -v p=":$port" '$4 ~ p"$" { found=1 } END { exit !found }'
}

# ── Graceful shutdown handler ──────────────────────────────────────
shutdown() {
    local signal=$1
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
    if [ -n "${LOG_ROTATOR_PID:-}" ]; then
        kill "$LOG_ROTATOR_PID" 2>/dev/null || true
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

# Fix data dir ownership so the runtime user can write to it.
# chown -R is a full recursive walk — on a large /data (chat DB plus
# attachments) that costs seconds on every start. Skip it when the top
# of the tree already has the requested owner; the daemon user is the only
# writer, so a correct root means the subtree is correct too.
if [ "$(stat -c '%u:%g' "$DATA_DIR" 2>/dev/null)" != "$PUID:$PGID" ]; then
    chown -R "$PUID:$PGID" "$DATA_DIR"
else
    echo "[entrypoint] $DATA_DIR already owned by $PUID:$PGID — skipping chown"
fi

# ── Build extra flags (array — no shell re-parsing of env values) ──
FLAGS=(-d "$DATA_DIR/simplex" -p 5225)

# v7.x auto-migrates older DB schemas non-interactively with this flag;
# without it a v6-era data dir triggers an interactive Continue (y/N) prompt
# that dies headless. Upstream spelling is --yes-migrate / -y.
FLAGS+=(-y)

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

# Bound the daemon log so a long-running bot can't fill the appdata share.
# Unraid's LogMaxSize/LogMaxFile only govern the Docker log driver, not this
# file. Truncate at start, and cap the size on every boot.
DAEMON_LOG="/data/daemon.log"
MAX_LOG_BYTES=$(( 10 * 1024 * 1024 ))
if [ -f "$DAEMON_LOG" ]; then
    LOG_SIZE=$(stat -c '%s' "$DAEMON_LOG" 2>/dev/null || echo 0)
    if [ "${LOG_SIZE:-0}" -gt "$MAX_LOG_BYTES" ]; then
        echo "[entrypoint] daemon.log is ${LOG_SIZE} bytes — trimming to last 1MB"
        # mv is safe here: the daemon has not been started yet, so nothing
        # holds the old inode open.
        gosu "$PUID:$PGID" sh -c \
          'tail -c 1048576 /data/daemon.log > /data/daemon.log.tmp 2>/dev/null && mv -f /data/daemon.log.tmp /data/daemon.log' || :
    fi
fi

# The daemon's stdout is redirected inside the inner shell, i.e. as the
# daemon user, NOT by this root shell. After the chown above, root owns
# nothing under /data and — with caps limited to CHOWN/SETUID/SETGID — has
# no DAC_OVERRIDE to bypass that, so a root-side redirect fails EACCES.
# Passing the flags positionally through "$@" keeps the display name a single
# argv element (no shell re-parsing of its spaces), and `exec` makes $! the
# simplex-chat process itself so signals reach the daemon directly.
gosu "$PUID:$PGID" sh -c 'exec simplex-chat "$@" > /data/daemon.log 2>&1' sh "${FLAGS[@]}" &
DAEMON_PID=$!
echo "[entrypoint]   PID: $DAEMON_PID"

# Wait for the daemon to bind 5225. The default (15s) suits native amd64;
# emulated/slow ARM boards can need longer, so it is env-tunable.
STARTUP_TIMEOUT="${SIMPLEX_STARTUP_TIMEOUT:-15}"
case "$STARTUP_TIMEOUT" in
    ''|*[!0-9]*)
        echo "[entrypoint] ERROR: SIMPLEX_STARTUP_TIMEOUT must be a positive integer (got: '$STARTUP_TIMEOUT')"
        exit 1
        ;;
esac
if [ "$STARTUP_TIMEOUT" -lt 1 ]; then
    echo "[entrypoint] ERROR: SIMPLEX_STARTUP_TIMEOUT must be >= 1 (got: $STARTUP_TIMEOUT)"
    exit 1
fi

for i in $(seq 1 "$STARTUP_TIMEOUT"); do
    if port_listening 5225; then
        echo "[entrypoint] WebSocket API ready on port 5225"
        break
    fi
    # Gate on the port only. Do NOT test `kill -0 $DAEMON_PID` here: $! is the
    # PID of the `gosu` wrapper, and it is not a reliable proxy for the
    # daemon's liveness across the gosu -> sh -> simplex-chat exec chain. An
    # early-exit check on it fires within milliseconds of launch and kills
    # healthy startup — which is exactly what CI caught when this was added.
    if [ "$i" -eq "$STARTUP_TIMEOUT" ]; then
        echo "[entrypoint] ERROR: simplex-chat failed to start within ${STARTUP_TIMEOUT}s"
        tail -20 "$DATA_DIR/daemon.log" 2>/dev/null || true
        kill "$DAEMON_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

SETUP_MARKER="$DATA_DIR/.setup-complete"
if [ ! -f "$SETUP_MARKER" ]; then
    sleep 2
    echo "[entrypoint] Setting up bot address..."
    # /tmp, not /data: this redirect is performed by the root shell, which
    # has no write access to /data after the chown (see the daemon launch
    # above). The setup log is diagnostic output, not persistent state.
    SETUP_LOG="/tmp/setup.log"
    # Run as the daemon user; capture exit status explicitly — the sed pipe
    # would otherwise mask python's exit code (sed always exits 0).
    if gosu "$PUID:$PGID" python3 - <<'PYEOF' > "$SETUP_LOG" 2>&1
import asyncio, json, os, sys
import websockets

async def setup():
    async with websockets.connect('ws://127.0.0.1:5225', open_timeout=10) as ws:
        # Ask for the active user first: /user returns activeUser with the
        # full User object, whose userId is what /_address_settings takes as
        # its first argument (bots/api/COMMANDS.md:
        # `/_address_settings <userId> <json(settings)>`). Hardcoding an id
        # here silently targets the wrong profile whenever it isn't 1.
        await ws.send(json.dumps({'corrId': 's1', 'cmd': '/user'}))
        await asyncio.sleep(1)
        await ws.send(json.dumps({'corrId': 's2', 'cmd': '/ad'}))
        await asyncio.sleep(2)
        address = None
        user_id = None
        for _ in range(10):
            try:
                evt = await asyncio.wait_for(ws.recv(), timeout=1)
            except asyncio.TimeoutError:
                break
            data = json.loads(evt)
            resp = data.get('resp', {})
            rtype = resp.get('type')
            if rtype == 'activeUser':
                # activeUser carries the profile; prefer the active profile's
                # id, and only fall back to a single-user profile.
                user = resp.get('user', {})
                if user.get('activeUser'):
                    user_id = user.get('userId')
                elif user_id is None:
                    user_id = user.get('userId')
            elif rtype == 'usersList':
                users = resp.get('users', [])
                active = [u for u in users if u.get('activeUser')]
                if active and user_id is None:
                    user_id = active[0].get('userId')
            elif rtype == 'userContactLinkCreated':
                link = resp.get('connLinkContact', {})
                address = link.get('connFullLink') or link.get('connShortLink')
                if user_id is None:
                    # The creation event also carries the user.
                    user_id = (resp.get('user') or {}).get('userId')
        if os.environ.get('SIMPLEX_AUTO_ACCEPT', 'true') == 'true':
            if user_id is None:
                # Do NOT guess an id: applying settings to the wrong profile
                # is worse than leaving auto-accept off, and it fails silently.
                print('[setup] WARNING: could not determine userId — auto-accept NOT configured')
                print('[setup]          (accept contact requests manually in the SimpleX app)')
            else:
                settings = json.dumps({'businessAddress': False,
                                       'autoAccept': {'acceptIncognito': False}})
                await ws.send(json.dumps({'corrId': 's3',
                                          'cmd': f'/_address_settings {user_id} {settings}'}))
                await asyncio.sleep(1)
                # Correlate on corrId: the daemon echoes it (Server.hs wraps
                # every response as {corrId, resp}). Matching on the substring
                # 'userContactLinkUpdated' alone would accept an unrelated
                # event and report success for a command that never applied.
                confirmed = False
                try:
                    evt = await asyncio.wait_for(ws.recv(), timeout=3)
                    r = json.loads(evt)
                    if r.get('corrId') == 's3' and r.get('resp', {}).get('type') == 'userContactLinkUpdated':
                        confirmed = True
                except asyncio.TimeoutError:
                    pass
                except json.JSONDecodeError:
                    pass
                if confirmed:
                    print('[setup] Auto-accept enabled')
                else:
                    print('[setup] WARNING: /_address_settings was not confirmed for '
                          f'userId {user_id} — auto-accept may not be active')
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
        # Create the marker as the daemon user — root cannot write to /data.
        gosu "$PUID:$PGID" touch "$SETUP_MARKER"
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
    # 5225 is already bound by the daemon on 127.0.0.1. socat listens on
    # 0.0.0.0, so binding the same port fails with EADDRINUSE — and because
    # the healthcheck probes 127.0.0.1:5225 (the daemon, not socat), the
    # container still reports healthy while the bridge is dead. Fail loudly
    # here instead of shipping a silently broken proxy.
    if [ "$SIMPLEX_SOCAT_PORT" -eq 5225 ]; then
        echo "[entrypoint] ERROR: SIMPLEX_SOCAT_PORT must NOT be 5225 — the daemon already binds 127.0.0.1:5225."
        echo "[entrypoint]        Pick another port (e.g. 5226) and publish that one."
        exit 1
    fi
    echo "[entrypoint] *** WARNING: Exposing WebSocket API on 0.0.0.0:$SIMPLEX_SOCAT_PORT ***"
    echo "[entrypoint] *** No authentication — only use on trusted networks    ***"
    echo "[entrypoint] Starting socat bridge on 0.0.0.0:$SIMPLEX_SOCAT_PORT → 127.0.0.1:5225"
    socat "TCP-LISTEN:$SIMPLEX_SOCAT_PORT,reuseaddr,fork" TCP:127.0.0.1:5225 &
    SOCAT_PID=$!
    echo "[entrypoint]   socat PID: $SOCAT_PID"

    # Confirm the listener actually came up; otherwise the bridge is dead
    # and only a manual `ss -tln | grep $SIMPLEX_SOCAT_PORT` would reveal it.
    for i in $(seq 1 10); do
        if port_listening "$SIMPLEX_SOCAT_PORT"; then
            echo "[entrypoint] socat bridge listening on 0.0.0.0:$SIMPLEX_SOCAT_PORT"
            break
        fi
        if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
            echo "[entrypoint] ERROR: socat exited immediately — bridge NOT running on port $SIMPLEX_SOCAT_PORT"
            exit 1
        fi
        if [ "$i" -eq 10 ]; then
            echo "[entrypoint] ERROR: socat did not start listening on port $SIMPLEX_SOCAT_PORT within 10s"
            exit 1
        fi
        sleep 1
    done
fi

# ── Periodic daemon.log trim ───────────────────────────────────────
# The boot-time trim only helps on restart. A container left up for months
# would still grow without bound, so trim hourly in the background.
#
# Truncate in place — never mv. The running daemon holds daemon.log open by
# inode, so replacing the file would send all further output to an unlinked
# inode where it is silently lost. Truncating keeps the same inode open and
# the daemon simply keeps writing into it.
#
# Runs as the daemon user: after the entrypoint's chown, root has no write
# access to /data without CAP_DAC_OVERRIDE, which this image deliberately
# does not request. Single quotes are intentional: the inner shell expands
# "$@" and the size at runtime, and the one exception is spliced in above.
# shellcheck disable=SC2016
gosu "$PUID:$PGID" sh -c '
    while true; do
        sleep 3600
        if [ -f /data/daemon.log ]; then
            SIZE=$(stat -c "%s" /data/daemon.log 2>/dev/null || echo 0)
            if [ "${SIZE:-0}" -gt '"$MAX_LOG_BYTES"' ]; then
                truncate -s 0 /data/daemon.log 2>/dev/null || : > /data/daemon.log
                echo "[entrypoint] daemon.log exceeded max size — truncated"
            fi
        fi
    done
' &
LOG_ROTATOR_PID=$!

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
