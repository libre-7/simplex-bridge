#!/bin/bash
# F1 verification — proves install-websockets.sh targets the interpreter that
# actually runs the gateway, pins the version, locates the adapter outside the
# venv, and that its verification CAN fail.
#
# `docker` is stubbed to exec commands locally, so the real script body runs.
# `pip` is stubbed, so nothing touches the network or mutates this container.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../install-websockets.sh"
STUB="$(mktemp -d)"; WORK="$(mktemp -d)"
trap 'rm -rf "$STUB" "$WORK"' EXIT

PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then echo "  ✓ $1 ($2)"; PASS=$((PASS+1));
       else echo "  ✗ $1 (got '$2', want '$3')"; FAIL=$((FAIL+1)); fi; }

# ── docker stub: drop "exec <container>", run the rest locally ────────
# Two traces: PIP_TRACE records the arguments the SCRIPT passed to pip (the
# thing under test). STUB_TRACE records docker invocations. Keeping them
# separate stops the pip stub's own logging from looking like a script bug.
cat > "$STUB/docker" <<'STUBEOF'
#!/bin/bash
[ "$1" = "exec" ] || { echo "stub: only 'exec' supported" >&2; exit 2; }
shift 2
[ -n "${STUB_TRACE:-}" ] && printf '%s\n' "$*" >> "$STUB_TRACE"
exec "$@"
STUBEOF
chmod +x "$STUB/docker"
export PATH="$STUB:$PATH" STUB_TRACE="$WORK/trace" PIP_TRACE="$WORK/piptrace"

# ── A gateway-shaped venv ───────────────────────────────────────────
# The interpreter must be a REAL Hermes interpreter so `import hermes_cli`
# succeeds (that is how the script detects Hermes). pip is stubbed.
REAL_PY=""
for cand in /app/venv/bin/python3 "$(command -v python3)"; do
    if [ -x "$cand" ] && "$cand" -c "import hermes_cli" 2>/dev/null; then
        REAL_PY="$cand"; break
    fi
done
if [ -z "$REAL_PY" ]; then
    # Exit 77 is the automake convention for "skipped". The test needs a real
    # Hermes install to exercise the venv-detection path; on a plain CI runner
    # there isn't one, and failing the build for that would be a false alarm.
    echo "SKIP: no Hermes-capable interpreter on this host" >&2
    echo "      (the venv-detection path can only be tested on a Hermes container)" >&2
    exit 77
fi
echo "  (using interpreter: $REAL_PY)"

FAKE_VENV="$WORK/venv"; mkdir -p "$FAKE_VENV/bin"
ln -s "$REAL_PY" "$FAKE_VENV/bin/python3"
cat > "$FAKE_VENV/bin/pip" <<'PIPEOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PIP_TRACE:-/dev/null}"
spec=""; brk=0
for a in "$@"; do
    case "$a" in websockets==*) spec="$a" ;; --break-system-packages) brk=1 ;; esac
done
[ -n "$spec" ] || { echo "stub pip: no websockets spec in: $*" >&2; exit 1; }
# Emulate PEP 668 so the script's --break-system-packages fallback is used.
[ "$brk" = "1" ] || { echo "stub pip: externally-managed-environment" >&2; exit 1; }
exit 0
PIPEOF
chmod +x "$FAKE_VENV/bin/pip"
export HERMES_VENV="$FAKE_VENV"

# ── A gateway-shaped plugin tree, OUTSIDE the venv ──────────────────
# This is the layout that made the old script skip verification silently:
# `find /app/venv -path '*/simplex/adapter.py'` finds nothing here.
SRC="$WORK/src"; ADIR="$SRC/plugins/platforms/simplex"
GW="$WORK/gwstub"
mkdir -p "$ADIR" "$GW/hermes_cli"
: > "$SRC/plugins/__init__.py"; : > "$SRC/plugins/platforms/__init__.py"
: > "$GW/hermes_cli/__init__.py"
# Minimal gateway registry so step 3 ("is the plugin discoverable?") can pass.
# Without this the check depends on the host's real Hermes install, which is
# not what this test is about.
cat > "$GW/hermes_cli/gateway.py" <<'PYEOF'
def _all_platforms():
    return [{'key': 'simplex', 'label': 'SimpleX Chat'}]
PYEOF
good_adapter() {
    cat > "$ADIR/adapter.py" <<'PYEOF'
import json
def _send_cmd(chat_id: str, items: list) -> str:
    target = f"#{chat_id[6:]}" if chat_id.startswith("group:") else f"@{chat_id}"
    return f"/_send {target} json {json.dumps(items)}"
PYEOF
}
good_adapter
# Gateway stub first on the path so `hermes_cli.gateway` resolves to the
# stub; the plugin tree provides the adapter.
export PYTHONPATH="$GW:$SRC"

echo "=== A. resolves the gateway venv, not bare python3 ==="
: > "$STUB_TRACE"
bash "$SCRIPT" testcontainer > "$WORK/out" 2>&1; rc=$?
ck "exit status" "$rc" "0"
grep -E "Target interpreter" "$WORK/out" | sed 's/^/    /'
if grep -q "Target interpreter: $FAKE_VENV/bin/python3" "$WORK/out"; then
    echo "  ✓ used the gateway venv interpreter"; PASS=$((PASS+1))
else
    echo "  ✗ did NOT use the gateway venv interpreter"; FAIL=$((FAIL+1))
fi
# The script must invoke pip/python3 ONLY as absolute venv paths. Any bare
# `pip`/`python3` in the docker trace means it fell back to PATH — the exact
# defect F1 describes.
strays=$(grep -E '(^| )(pip|python3)( |$)' "$STUB_TRACE" 2>/dev/null | grep -v 'test -x' || true)
if [ -z "$strays" ]; then echo "  ✓ no bare pip/python3 invocations"; PASS=$((PASS+1));
else echo "  ✗ bare interpreter invocations remain:"; printf '%s\n' "$strays" | sed 's/^/      /'; FAIL=$((FAIL+1)); fi

# pip must have been called with the version pin (matching the image).
if grep -q 'websockets==17.0.1' "$PIP_TRACE" 2>/dev/null; then
    echo "  ✓ install pinned to the image version (17.0.1)"; PASS=$((PASS+1))
else
    echo "  ✗ install not pinned; pip saw:"; sed 's/^/      /' "$PIP_TRACE" 2>/dev/null; FAIL=$((FAIL+1))
fi

# pip must have been reached via the venv, and the PEP 668 fallback used.
if grep -q -- '--break-system-packages' "$PIP_TRACE" 2>/dev/null; then
    echo "  ✓ PEP 668 fallback exercised"; PASS=$((PASS+1))
else
    echo "  • PEP 668 fallback not exercised (pip stub accepted plain install)"
fi

echo
echo "=== B. adapter found outside the venv; DM check actually runs ==="
grep -E "adapter:|DM send path|not found" "$WORK/out" | sed 's/^/    /'
if grep -q "DM send path uses the structured" "$WORK/out"; then
    echo "  ✓ verification executed (it did not silently skip)"; PASS=$((PASS+1))
else
    echo "  ✗ verification skipped or failed"; FAIL=$((FAIL+1))
fi

echo
echo "=== C. verification CAN fail (a check that cannot fail is not a check) ==="
cat > "$ADIR/adapter.py" <<'PYEOF'
# legacy adapter: broken CLI shortcut, no _send_cmd helper
class A:
    def send(self, chat_id, content):
        return f"@{chat_id} {content}"
PYEOF
bash "$SCRIPT" testcontainer > "$WORK/out2" 2>&1; rc2=$?
grep -E "Unrecognised adapter" "$WORK/out2" | head -1 | sed 's/^/    /'
if [ "$rc2" -ne 0 ]; then
    echo "  ✓ unrecognised adapter → exit $rc2 (no false 'verified')"; PASS=$((PASS+1))
else
    echo "  ✗ exited 0 on a broken adapter — the check is theatre"; FAIL=$((FAIL+1))
fi
if grep -q "=== Done ===" "$WORK/out2"; then
    echo "  ✗ still printed 'Done' despite the failure"; FAIL=$((FAIL+1))
else
    echo "  ✓ did not print 'Done'"; PASS=$((PASS+1))
fi
good_adapter

echo
echo "=== D. missing venv → loud warning, not a silent fallback ==="
rm -rf "$FAKE_VENV"
bash "$SCRIPT" testcontainer > "$WORK/out3" 2>&1
if grep -q "falling back to bare 'python3'" "$WORK/out3"; then
    echo "  ✓ warns when the gateway venv is absent"; PASS=$((PASS+1))
else
    echo "  ✗ no warning when the venv is missing"; FAIL=$((FAIL+1))
fi

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
