#!/bin/bash
# F2 verification harness — tests the REAL port_listening() body, extracted
# from entrypoint.sh at runtime (no copy that can drift).
#
# Real TCP listeners are created by ss_from_proc.py, which emits ss -tlnH
# -format output derived from /proc/net/tcp. So the socket state is real;
# only the column formatting is reconstructed.
set -u

# Resolve repo root from this script's own location so the harness works
# from any cwd and cannot be pointed at a stale copy by accident.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$HERE/../entrypoint.sh"
EXTRACT="$(mktemp)"
MOCKDIR=""
cleanup() { rm -rf "$MOCKDIR" "$EXTRACT"; }
trap cleanup EXIT

# ── Extract the shipped function verbatim ──────────────────────────
awk '/^port_listening\(\) \{/,/^\}/' "$ENTRYPOINT" > "$EXTRACT"
if ! grep -q "sport = :" "$EXTRACT"; then
    echo "FATAL: could not extract port_listening() from $ENTRYPOINT" >&2
    echo "extracted:" >&2; cat "$EXTRACT" >&2
    exit 2
fi
echo "=== extracted from entrypoint.sh ==="
sed 's/^/    /' "$EXTRACT"
echo

PASS=0; FAIL=0
check() {
    local desc="$1" port="$2" expect="$3"
    # shellcheck disable=SC1090
    . "$EXTRACT"
    if port_listening "$port"; then actual=0; else actual=1; fi
    unset -f port_listening
    if [ "$actual" = "$expect" ]; then
        echo "  ✓ $desc (query=$port exit=$actual)"; PASS=$((PASS+1))
    else
        echo "  ✗ $desc (query=$port exit=$actual expected=$expect)"; FAIL=$((FAIL+1))
    fi
}

MOCKDIR=$(mktemp -d); cat > "$MOCKDIR/ss" <<'MOCK'
#!/bin/bash
# Emulate `ss -tlnH [sport = :PORT]`. When SS_MOCK_NAIVE=1 the filter is
# ignored (old iproute2) so entrypoint's awk fallback is exercised.
#
# NOTE: the filter arrives as ONE argument ("sport = :5225"), because the
# caller quotes it. Split on whitespace rather than assuming three argv
# entries — verified against real bash argv semantics.
want=""
for a in "$@"; do
  case "$a" in
    *"sport = :"*) want="${a##*sport = :}"; break ;;
  esac
done
# SS_MOCK_OUTPUT holds the ss-format TEXT itself, not a path to it.
data="${SS_MOCK_OUTPUT}"
if [ -n "$want" ] && [ "${SS_MOCK_NAIVE:-0}" != "1" ]; then
  printf '%s\n' "$data" | awk -v p=":$want" '$4 ~ p"$"'
else
  printf '%s\n' "$data"
fi
MOCK
chmod +x "$MOCKDIR/ss"
export PATH="$MOCKDIR:$PATH"

run_ss() { python3 "$HERE/ss_from_proc.py" "$1" "${2:-}" 2>/dev/null; }

# This host already has a REAL service listening on 127.0.0.1:5225 (the
# user's SimpleX bridge), so /proc-derived output can never be "5225
# absent" without filtering. Restrict the fixture to the ports each case
# cares about, so the decoy-only scenario is genuinely decoy-only.
# Field 4 is the Local Address:Port column — the same column the fix anchors
# on, so use awk here too (shell ##*: would grab the LAST colon, i.e. "*").
only_ports() {
    printf '%s\n' "$1" | awk -v keep=",$2," '
        NF >= 4 {
            local = $4
            sub(/^.*:/, "", local)
            if (index(keep, "," local ",")) print
        }'
}
set_fixture() { SS_MOCK_OUTPUT=$(only_ports "$(run_ss "$1" "${3:-}")" "$2"); export SS_MOCK_OUTPUT; }

echo "=== A. daemon bound on 5225 alongside decoy ports ==="
set_fixture 15225,52250 "5225,15225,52250" 5225
while IFS= read -r l; do echo "    $l"; done <<< "$SS_MOCK_OUTPUT"
check "exact 5225 detected"            5225 0
check "15225 not read as 5225"        5225 0   # sanity: both true
check "query 15225 finds 15225"       15225 0
check "query 52250 finds 52250"       52250 0
check "query 5226 finds nothing"      5226  1
check "query 52251 finds nothing"     52251 1

echo
echo "=== B. THE F2 BUG: daemon dead, only decoy ports listening ==="
set_fixture 15225,52250 "15225,52250"
while IFS= read -r l; do echo "    $l"; done <<< "$SS_MOCK_OUTPUT"
check "must NOT report 5225 ready"    5225 1
check "15225 is genuinely listening"  15225 0
check "52250 is genuinely listening"  52250 0

echo
echo "=== C. awk fallback (old iproute2, filter unsupported) ==="
set_fixture 15225,52250 "5225,15225,52250" 5225; export SS_MOCK_NAIVE=1
check "fallback finds real 5225"      5225 0
set_fixture 15225,52250 "15225,52250"; export SS_MOCK_NAIVE=1
check "fallback still rejects decoy-only" 5225 1
SS_MOCK_OUTPUT=""; export SS_MOCK_OUTPUT SS_MOCK_NAIVE=1
check "fallback: empty socket table → exit 1" 5225 1
unset SS_MOCK_NAIVE

echo
echo "=== D. socat gate (F2 second site) ==="
set_fixture 15226 "5226,15226" 5226
check "socat 5226 detected"           5226 0
set_fixture 15226 "15226"
check "decoy 15226 must not satisfy 5226" 5226 1

echo
echo "=== E. fail-closed when ss is absent ==="
rm -f "$MOCKDIR/ss"
# shellcheck disable=SC1090  # $EXTRACT is generated at runtime by design
if . "$EXTRACT" 2>/dev/null && port_listening 5225; then
    echo "  ✗ reported ready with no ss"; FAIL=$((FAIL+1))
else
    echo "  ✓ no ss → not ready (fails closed)"; PASS=$((PASS+1))
fi

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
