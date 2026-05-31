#!/usr/bin/env python3
"""Health check for simplex-bridge WebSocket daemon.

Connects to the WebSocket API, sends a valid command, and verifies
a response is received. Falls back to TCP port check if the websockets
package is unavailable.

Exit code 0 = healthy, 1 = unhealthy.
"""
import sys
import json
import asyncio
import socket


async def check_ws():
    """Try WebSocket protocol check — returns True if alive."""
    try:
        import websockets  # noqa: F811
        async with websockets.connect('ws://127.0.0.1:5225', open_timeout=5) as ws:  # type: ignore[name-defined]  # noqa: F821
            await ws.send(json.dumps({'corrId': 'hc', 'cmd': '/_contacts 1'}))
            resp = await asyncio.wait_for(ws.recv(), timeout=3)
            return bool(resp and len(resp) > 0)
    except Exception:
        return False


def check_tcp():
    """Fallback TCP port check."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect(('127.0.0.1', 5225))
        s.close()
        return True
    except Exception:
        return False


if __name__ == '__main__':
    try:
        alive = asyncio.run(check_ws())
    except Exception:
        alive = check_tcp()
    sys.exit(0 if alive else 1)
