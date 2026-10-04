#!/bin/bash
# Run every static gate and regression test for this repo.
# No Docker required. Exits non-zero if anything fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

FAIL=0
step() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
verdict() { if [ "$1" -eq 0 ]; then echo "  ✓ $2"; else echo "  ✗ $2"; FAIL=1; fi; }

step "shellcheck"
shellcheck entrypoint.sh install-websockets.sh tests/*.sh
verdict $? "shell scripts clean"

step "bash syntax"
for f in entrypoint.sh install-websockets.sh tests/*.sh; do bash -n "$f" || exit 1; done
verdict $? "shell syntax OK"

step "python compile"
python3 -m py_compile healthcheck.py tests/test-setup-userid.py tests/ss_from_proc.py
verdict $? "python sources compile"

step "yaml / xml parse"
python3 - <<'PY'
import yaml, xml.dom.minidom as md
for f in ["docker-compose.yml", ".github/workflows/docker-publish.yml",
          ".github/workflows/base-refresh.yml", ".hadolint.yaml"]:
    yaml.safe_load(open(f)); print("  OK", f)
for f in ["templates/simplex-bridge.xml", "ca_profile.xml"]:
    md.parse(f); print("  OK", f)
PY
verdict $? "structured files parse"

step "no unanchored port grep in the entrypoint"
if grep -nE 'ss -tln[^H]*.*grep -q "?:?\$?[A-Za-z_]*port' entrypoint.sh; then
  echo "  ✗ found an unanchored port match"; FAIL=1
else
  echo "  ✓ no substring port matching"; verdict 0 ""
fi

step "F2 — readiness gate matches an exact port"
bash tests/test-port-gate.sh
verdict $? "port gate regression tests"

step "F1 — installer targets the gateway interpreter"
bash tests/test-installer-interpreter.sh
rc=$?
if [ "$rc" -eq 77 ]; then echo "  ~ skipped (no Hermes interpreter on this host)"; verdict 0 ""
else verdict "$rc" "installer interpreter tests"; fi

step "F3 — first-run setup uses the real userId"
python3 tests/test-setup-userid.py
verdict $? "setup userId tests"

step "docs consistency"
python3 tests/check-docs.py ${CHECK_DOCS_NET:+"$CHECK_DOCS_NET"}
verdict $? "README matches reality"

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mALL GATES PASSED\033[0m\n'
else
  printf '\033[31mSOME GATES FAILED\033[0m\n'
fi
exit "$FAIL"
