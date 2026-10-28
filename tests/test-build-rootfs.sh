#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/build-rootfs.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run)"

missing=0
for pat in '--mode=unshare' 'sysvinit-core' \
  'path-exclude=/lib/systemd/*' \
  'path-exclude=/usr/lib/systemd/*' \
  'path-exclude=/etc/systemd/*'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run output missing: $pat"
    missing=1
  fi
done

include="$(printf '%s\n' "$out" | tr ' ' '\n' | grep -oE -- '--include=[^ ]*' | head -n1)"
if [ -z "$include" ]; then
  echo "FAIL: --dry-run output has no --include= list"
  missing=1
fi
if printf '%s' "$include" | grep -qF -- 'systemd-sysv'; then
  echo "FAIL: include list must not contain systemd-sysv"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: build-rootfs.sh --dry-run prints unshare mode, sysvinit-core, all three path-excludes and no systemd-sysv in the include list"
