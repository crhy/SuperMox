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

echo "OK: vm-build-pkg.sh --dry-run pve-common mentions mk-build-deps and localrepo"
