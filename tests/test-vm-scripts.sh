#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/vm-start.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run)"

missing=0
for pat in '-cpu host' '-kernel' 'hostfwd=tcp:127.0.0.1:2223-:22'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run output missing: $pat"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: vm-start.sh --dry-run prints -cpu host, -kernel and the hostfwd port"
