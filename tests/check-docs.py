#!/usr/bin/env python3
"""Documentation-consistency checks.

Catches the class of drift this repo has actually suffered: a README that
describes behaviour the code no longer has, and version/digest pins that
disagree between the README, compose file, and Unraid template.
"""
import re
import sys

BAD = []


def check(cond, msg):
    if cond:
        print(f"  ✓ {msg}")
    else:
        print(f"  ✗ {msg}")
        BAD.append(msg)


readme = open("README.md").read()
compose = open("docker-compose.yml").read()
template = open("templates/simplex-bridge.xml").read()
installer = open("install-websockets.sh").read()

# 1. The installer does not patch; the README must not say it does.
check("applies the two-line fix to the adapter" not in readme,
      "README does not claim the installer patches the adapter")
check("no longer patches the adapter" in readme,
      "README states the installer is read-only")
# Strip comments before looking for an actual sed -i edit — the file
# deliberately mentions `sed -i` in prose explaining why it was removed.
installer_code = "\n".join(
    ln for ln in installer.splitlines() if not ln.lstrip().startswith("#"))
check("sed -i" not in installer_code,
      "installer executes no sed -i edit (only mentions it in comments)")
check(not re.search(r">\s*\S*adapter\.py", installer_code),
      "installer never redirects into adapter.py")

# 2. Version pins must agree everywhere they appear.
m = re.search(r"pinned to the immutable (v[\d.]+) release by digest", readme)
check(m is not None, "README names the pinned release version")
if m:
    ver = m.group(1)
    check(f"# {ver}" in compose,
          f"compose pin comment agrees with README ({ver})")
    check(ver in template,
          f"Unraid template pins the same version ({ver})")

# 3. The digest in compose and in the README's embedded compose block.
digests = set(re.findall(r"sha256:([0-9a-f]{64})", readme)) | \
          set(re.findall(r"sha256:([0-9a-f]{64})", compose))
check(len(digests) == 1,
      f"one digest used across README and compose (found {len(digests)})")

# 4. The Unraid template's <Repository> must not float :latest. Match the
# element itself, not the prose around it.
repo = re.search(r"<Repository>([^<]+)</Repository>", template)
check(repo is not None, "Unraid template has a <Repository> element")
if repo:
    check(":latest" not in repo.group(1),
          f"Unraid <Repository> pins a version, not :latest ({repo.group(1)})")

# 5. Documented env vars must exist in the Dockerfile/entrypoint.
doc_vars = set(re.findall(r"\|\s*`(SIMPLEX_[A-Z_]+|PUID|PGID|TZ)`\s*\|", readme))
combined = open("Dockerfile").read() + open("entrypoint.sh").read()
missing = [v for v in sorted(doc_vars) if v not in combined]
check(not missing,
      f"every documented env var is referenced in code (missing: {missing or 'none'})")

# 6. SECURITY.md must exist now that we claim a reporting path.
try:
    sec = open("SECURITY.md").read()
    check("Report a vulnerability" in sec or "reporting" in sec.lower(),
          "SECURITY.md documents a reporting path")
except FileNotFoundError:
    check(False, "SECURITY.md exists")

# 7. The released version must be the one documented as latest — in the
# README headline and as a dated CHANGELOG entry. Without this, a release can
# ship with docs still describing the previous version as current.
if m:
    ver = m.group(1)
    headline = re.search(r"latest release is \*\*(v[\d.]+)\*\*", readme)
    check(headline is not None and headline.group(1) == ver,
          f"README headline calls {ver} the latest release")
    changelog = open("CHANGELOG.md").read()
    # CHANGELOG headings drop the leading "v" (## [1.3.1] — 2026-10-04) and
    # separate the date with an em-dash, so match either separator.
    bare = ver.lstrip("v")
    check(re.search(rf"^## \[{re.escape(bare)}\]\s*[—–-]\s*\d{{4}}-\d{{2}}-\d{{2}}",
                    changelog, re.M) is not None,
          f"CHANGELOG has a dated entry for {ver}")

print()
if BAD:
    print(f"=== {len(BAD)} doc check(s) failed ===")
    sys.exit(1)
print("=== all doc checks passed ===")
