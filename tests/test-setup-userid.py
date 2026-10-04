#!/usr/bin/env python3
"""F3 verification — drives the REAL setup block from entrypoint.sh against a
fake WebSocket daemon that speaks simplex-chat's documented envelope.

The daemon replays scripted responses ({corrId, resp} — per Server.hs) so we
can prove:
  * the userId passed to /_address_settings is the REAL one, not a literal 1;
  * the confirmation is correlated on corrId, so an unrelated event with the
    right substring does NOT count as success;
  * when no userId can be determined, auto-accept is skipped with a warning
    rather than applied to a guessed profile.

The setup code is extracted from entrypoint.sh at runtime, so this cannot
drift from what ships.
"""
import asyncio
import json
import os
import re
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ENTRYPOINT = os.path.join(HERE, "..", "entrypoint.sh")

PASS = []
FAIL = []


def ck(desc, cond, detail=""):
    if cond:
        PASS.append(desc)
        print(f"  ✓ {desc}")
    else:
        FAIL.append(desc)
        print(f"  ✗ {desc}" + (f"  [{detail}]" if detail else ""))


def extract_setup():
    """Pull the python heredoc body out of entrypoint.sh."""
    src = open(ENTRYPOINT).read()
    m = re.search(r"<<'PYEOF' > \"\$SETUP_LOG\" 2>&1\n(.*?)\nPYEOF", src, re.S)
    if not m:
        print("FATAL: could not extract the setup heredoc from entrypoint.sh")
        sys.exit(2)
    return m.group(1)


def run_case(name, script, user_id, expect_confirmed, expect_cmd_id,
                   auto_accept="true", expect_no_settings=False):
    """Run the extracted setup against a fake daemon replaying `script`."""
    received = []
    replies = script["replies"]
    reply_idx = [0]

    def fake_ws(url, **kw):
        """Stand in for websockets.connect(...).

        websockets.connect returns an awaitable async-context-manager, and the
        setup code uses it as `async with websockets.connect(...) as ws`, so the
        replacement exposes __aenter__/__aexit__ directly (it is NOT a
        coroutine function).

        Two SEPARATE queues model the socket directions: the daemon must read
        what the client sent and write replies the client then reads. Sharing
        one queue lets each side consume the other's traffic.
        """
        class FakeWS:
            def __init__(self):
                self.to_daemon = asyncio.Queue()   # client -> daemon
                self.to_client = asyncio.Queue()   # daemon -> client
                self._task = None

            async def send(self, data):
                await self.to_daemon.put(data)

            async def recv(self):
                # The client wraps recv() in asyncio.wait_for(...), so this
                # must yield; a fake that blocks forever defeats wait_for.
                return await asyncio.wait_for(self.to_client.get(), timeout=5)

            async def __aenter__(self):
                self._task = asyncio.ensure_future(handler(self))
                return self

            async def __aexit__(self, *exc):
                if self._task:
                    self._task.cancel()
                return False

        return FakeWS()

    async def handler(ws):
        """Fake daemon: answer each command as the client sends it.

        Replies are pushed in the order scripted, one per received command, so
        the client's recv() sees them in the intended sequence.
        """
        try:
            while True:
                raw = await ws.to_daemon.get()
                msg = json.loads(raw)
                received.append(msg)
                if len(replies) > reply_idx[0]:
                    await ws.to_client.put(json.dumps(replies[reply_idx[0]]))
                    reply_idx[0] += 1
        except asyncio.CancelledError:
            raise
        except Exception:
            return

    # Neutralise the on-disk write; we only care about the logic.
    tmpdata = tempfile.mkdtemp()
    src = extract_setup().replace("/data/bot_address.txt", os.path.join(tmpdata, "addr.txt"))

    # Inject a stub module named `websockets` so the extracted setup code's
    # `import websockets` succeeds. The real library is NOT required: the code
    # under test only calls websockets.connect(...), which is replaced with the
    # fake below. Depending on the real package would make this suite fail on
    # any runner that doesn't have it installed.
    stub_mod = types.ModuleType("websockets")
    stub_mod.connect = fake_ws
    stub_mod.__version__ = "stub"
    prev_mod = sys.modules.get("websockets", "<absent>")
    sys.modules["websockets"] = stub_mod

    import io
    import contextlib
    buf = io.StringIO()
    code = 0
    g = {"__name__": "__main__", "asyncio": asyncio, "json": json, "os": os,
         "sys": sys, "websockets": stub_mod, "fake_ws": fake_ws}
    try:
        with contextlib.redirect_stdout(buf):
            exec(compile(src, "setup", "exec"), g)
    except SystemExit as e:
        code = e.code or 0
    finally:
        if prev_mod == "<absent>":
            sys.modules.pop("websockets", None)
        else:
            sys.modules["websockets"] = prev_mod
    out = buf.getvalue()

    print(f"\n--- {name} ---")
    for line in out.strip().splitlines():
        print(f"    {line}")

    cmds = [m["cmd"] for m in received if "cmd" in m]
    settings_cmd = next((c for c in cmds if c.startswith("/_address_settings")), None)
    if expect_no_settings:
        ck(f"{name}: sent NO /_address_settings (no id to target)",
           settings_cmd is None, f"cmds={cmds}")
    else:
        ck(f"{name}: sent /_address_settings", settings_cmd is not None,
           f"cmds={cmds}")
    if expect_cmd_id is None:
        ck(f"{name}: did NOT guess an id", settings_cmd is None,
           f"got {settings_cmd!r}")
    else:
        ck(f"{name}: used real userId {expect_cmd_id}",
           settings_cmd is not None and settings_cmd.split()[1] == str(expect_cmd_id),
           f"got {settings_cmd!r}")
    if expect_confirmed is True:
        ck(f"{name}: reported auto-accept enabled", "Auto-accept enabled" in out)
    elif expect_confirmed is False:
        ck(f"{name}: did NOT falsely claim success",
           "Auto-accept enabled" not in out and "WARNING" in out)
    return out


def main():
    body = extract_setup()
    ck("setup block extracted from entrypoint.sh", "activeUser" in body)
    ck("no hardcoded '/_address_settings 1 ' remains",
       "/_address_settings 1 " not in body)
    ck("confirmation correlates on corrId", "corrId') == 's3'" in body)

    link = "simplex:/contact#/?v=2-7&smp=smp%3A%2F%2Ffake"

    # 1. Normal case: userId is 42, and the daemon confirms with corrId s3.
    run_case("userId=42 confirmed", {
        "replies": [
            {"corrId": "s1", "resp": {"type": "activeUser",
                                      "user": {"userId": 42, "activeUser": True}}},
            {"corrId": "s2", "resp": {"type": "userContactLinkCreated",
                                      "user": {"userId": 42},
                                      "connLinkContact": {"connFullLink": link}}},
            {"corrId": "s3", "resp": {"type": "userContactLinkUpdated",
                                      "user": {"userId": 42}}},
        ]}, 42, True, 42)

    # 2. The decoy: an unrelated event that merely CONTAINS the substring
    #    'userContactLinkUpdated' but has the wrong corrId. The old code
    #    matched on substring and would have claimed success.
    run_case("wrong corrId decoy", {
        "replies": [
            {"corrId": "s1", "resp": {"type": "activeUser",
                                      "user": {"userId": 7, "activeUser": True}}},
            {"corrId": "s2", "resp": {"type": "userContactLinkCreated",
                                      "user": {"userId": 7},
                                      "connLinkContact": {"connFullLink": link}}},
            {"corrId": "s99", "resp": {"type": "userContactLinkUpdated",
                                       "user": {"userId": 7}}},
        ]}, 7, False, 7)

    # 3. No user info at all — must not guess, must warn.
    run_case("no userId available", {
        "replies": [
            {"corrId": "s1", "resp": {"type": "cmdOk"}},
            {"corrId": "s2", "resp": {"type": "userContactLinkCreated",
                                      "connLinkContact": {"connFullLink": link}}},
        ]}, None, False, None, expect_no_settings=True)

    # 4. userId comes from the creation event when /user is unhelpful.
    run_case("userId from creation event", {
        "replies": [
            {"corrId": "s1", "resp": {"type": "cmdOk"}},
            {"corrId": "s2", "resp": {"type": "userContactLinkCreated",
                                      "user": {"userId": 1234},
                                      "connLinkContact": {"connFullLink": link}}},
            {"corrId": "s3", "resp": {"type": "userContactLinkUpdated",
                                      "user": {"userId": 1234}}},
        ]}, 1234, True, 1234)

    # 5. usersList fallback (multiple profiles).
    run_case("usersList fallback", {
        "replies": [
            {"corrId": "s1", "resp": {"type": "usersList", "users": [
                {"userId": 5, "activeUser": False},
                {"userId": 9, "activeUser": True}]}},
            {"corrId": "s2", "resp": {"type": "userContactLinkCreated",
                                      "user": {"userId": 9},
                                      "connLinkContact": {"connFullLink": link}}},
            {"corrId": "s3", "resp": {"type": "userContactLinkUpdated",
                                      "user": {"userId": 9}}},
        ]}, 9, True, 9)

    print(f"\n=== RESULT: {len(PASS)} passed, {len(FAIL)} failed ===")
    for f in FAIL:
        print(f"  FAILED: {f}")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
