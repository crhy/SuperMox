#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# The credit logic (which binary packages a component produces) must respect
# config/build-subdirs.txt: proxmox-perl-rs builds only common/pkg and pve-rs,
# so libpmg-rs-perl (under pmg-rs/) must NOT be credited to proxmox-perl-rs,
# while pve-rs (under pve-rs/) must be. Run the report offline (an empty
# policy cache is fine: produced.tsv is computed before any apt query) and
# inspect build/t21-build-order/produced.tsv. The script regenerates
# docs/build-deps.md, so back it up and restore it.

doc_backup=build/build-deps-report-doc.bak
cp docs/build-deps.md "$doc_backup"
trap 'cp "$doc_backup" docs/build-deps.md' EXIT

: > build/empty-policy.out
SUPERMOX_POLICY_CACHE=build/empty-policy.out bash scripts/build-deps-report.sh >/dev/null

produced=build/t21-build-order/produced.tsv
if [ ! -f "$produced" ]; then
  echo "FAIL: produced.tsv not generated"
  exit 1
fi

if ! grep -qP '^libpve-rs-perl\tproxmox-perl-rs$' "$produced"; then
  echo "FAIL: libpve-rs-perl (pve-rs/ subdir) not credited to proxmox-perl-rs"
  exit 1
fi
if grep -qP '^libpmg-rs-perl\tproxmox-perl-rs$' "$produced"; then
  echo "FAIL: libpmg-rs-perl wrongly credited to proxmox-perl-rs (pmg-rs/ is not a built subdir)"
  exit 1
fi

# Step 2: the report must NOT list systemd/systemd-sysv as missing; it moves
# them to a "Deliberately replaced" section (we ship sysvinit instead).
if ! grep -q '^## Deliberately replaced' docs/build-deps.md; then
  echo "FAIL: report missing 'Deliberately replaced' section for systemd"
  exit 1
fi
if grep -q '^- systemd$' docs/build-deps.md; then
  # systemd may appear as a bullet only under the Deliberately replaced section,
  # never in the External missing list. The External list precedes the section,
  # so a systemd bullet must come after the section header.
  sec_line=$(grep -n '^## Deliberately replaced' docs/build-deps.md | cut -d: -f1)
  sys_line=$(grep -n '^- systemd$' docs/build-deps.md | head -1 | cut -d: -f1)
  if [ "$sys_line" -lt "$sec_line" ]; then
    echo "FAIL: systemd listed under External missing instead of Deliberately replaced"
    exit 1
  fi
fi

echo "OK: build-deps-report credits only built subdirs (libpve-rs-perl yes, libpmg-rs-perl no)"
