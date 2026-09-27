#!/usr/bin/env python3
"""Health check for simplex-bridge WebSocket daemon.

Connects to the WebSocket API, sends a valid command, and verifies
a response is received. Falls back to a TCP port check when the
`websockets` package is unavailable, so a broken/missing client library
never reports a live daemon as unhealthy.

Exit code 0 = healthy, 1 = unhealthy.
"""
import sys
import json
import asyncio
import socket

WS_URL = 'ws://127.0.0.1:5225'


def websockets_available():
    """True when the websockets package can be imported."""
    try:
        import websockets  # noqa: F401
        return True
    except Exception:
        return False


async def check_ws():
    """WebSocket protocol check — returns True if the daemon answers."""
    import websockets
    async with websockets.connect(WS_URL, open_timeout=5) as ws:
        await ws.send(json.dumps({'corrId': 'hc', 'cmd': '/_contacts 1'}))
        resp = await asyncio.wait_for(ws.recv(), timeout=3)
        return bool(resp and len(resp) > 0)


def check_tcp():
    """Fallback TCP port check — daemon is listening even if the probe fails."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(('127.0.0.1', 5225))
        s.close()
        return True
    except Exception:
        return False


if __name__ == '__main__':
    # Only fall back when the client library itself is the problem. A live
    # daemon that fails the protocol probe is genuinely unhealthy, and
    # masking that behind a TCP connect would hide real failures.
    if not websockets_available():
        alive = check_tcp()
    else:
        try:
            alive = asyncio.run(check_ws())
        except Exception:
            alive = False
    sys.exit(0 if alive else 1)
