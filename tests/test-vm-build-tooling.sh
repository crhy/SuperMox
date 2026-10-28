#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/vm-build-pkg.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run pve-common)"

missing=0
for pat in 'mk-build-deps' 'localrepo'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run output missing: $pat"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

# Multi-subdir component: --dry-run must list each subdir, in build order.
out2="$(bash "$target" --dry-run proxmox-perl-rs)"
for pat in 'common/pkg' 'pve-rs'; do
  if ! printf '%s\n' "$out2" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run proxmox-perl-rs missing subdir: $pat"
    exit 1
  fi
done
line_cp="$(printf '%s\n' "$out2" | awk '/common\/pkg/{print NR; exit}' || true)"
line_pr="$(printf '%s\n' "$out2" | awk '/pve-rs/{print NR; exit}' || true)"
if [ -z "$line_cp" ] || [ -z "$line_pr" ] || [ "$line_cp" -ge "$line_pr" ]; then
  echo "FAIL: --dry-run proxmox-perl-rs subdirs not in order (common/pkg before pve-rs)"
  exit 1
fi

echo "OK: vm-build-pkg.sh --dry-run pve-common mentions mk-build-deps and localrepo"
echo "OK: vm-build-pkg.sh --dry-run proxmox-perl-rs lists common/pkg before pve-rs"
