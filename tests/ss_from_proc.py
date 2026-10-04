#!/usr/bin/env python3
"""Create real TCP listeners, then emit `ss -tlnH`-format output from
/proc/net/tcp + /proc/net/tcp6.

Real socket state (so the match logic is tested against reality), with only
the text formatting reconstructed to match iproute2's documented
`ss -tlnH` column layout:

    LISTEN 0  4096  127.0.0.1:5225  0.0.0.0:*

Field 4 is Local Address:Port — which is what entrypoint.sh's awk anchors on.
"""
import os
import socket
import subprocess
import sys
import threading
import time

def _ports(spec):
    if not spec:
        return []
    return [int(p) for p in spec.split(",") if p.strip()]

LISTEN_PORTS = _ports(sys.argv[1]) if len(sys.argv) > 1 else []
FAKE_PORTS = _ports(sys.argv[2]) if len(sys.argv) > 2 else []
socks = []

for port in LISTEN_PORTS:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
        s.listen(8)
        socks.append(s)
    except OSError as e:
        # Port already occupied on this host (e.g. 5225 may be in use) —
        # that is itself the decoy scenario, so report and continue.
        print(f"# could not bind {port}: {e.strerror}", file=sys.stderr)

def hold():
    while True:
        time.sleep(3600)

for s in socks:
    threading.Thread(target=hold, daemon=True).start()

time.sleep(float(os.environ.get("SS_HOLD", "0.4")))


def hexport(p):
    return f"{p:04X}"


def parse(path, family):
    out = []
    try:
        lines = open(path).read().splitlines()[1:]
    except OSError:
        return out
    for ln in lines:
        f = ln.split()
        if len(f) < 4:
            continue
        local, state = f[1], f[3]
        if state != "0A":  # 0A = TCP_LISTEN
            continue
        addr, _, port = local.partition(":")
        port = int(port, 16)
        if family == "v4":
            ip = ".".join(str(int(addr[i:i+2], 16)) for i in (6, 4, 2, 0))
        else:
            b = [addr[i:i+4] for i in range(0, 32, 4)]
            b = [x for grp in b for x in (int(grp[2:4], 16), int(grp[0:2], 16))]
            ip = "[" + ":".join(f"{x:x}" for x in b) + "]"
        out.append((ip, port))
    return out

rows = parse("/proc/net/tcp", "v4") + parse("/proc/net/tcp6", "v6")
rows.sort(key=lambda r: r[1])
have = {p for _, p in rows}
# Synthesise lines for ports we could not bind (already occupied on this
# host) so the "daemon IS listening" case can still be exercised. Only the
# presence of a LISTEN row matters to the match logic under test.
for p in FAKE_PORTS:
    if p not in have:
        rows.append(("127.0.0.1", p))
rows.sort(key=lambda r: r[1])
for ip, port in rows:
    # Mirror iproute2 spacing closely enough that field 4 is always
    # "<addr>:<port>" — that is the only column the logic depends on.
    local = f"{ip}:{port}"
    print("LISTEN 0      4096   " + local.ljust(36) + "0.0.0.0:*")
