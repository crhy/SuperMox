#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/fetch-upstream.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

mapfile -t lines < <(bash "$target" --list)

count=${#lines[@]}
if [ "$count" -ne 12 ]; then
  echo "FAIL: --list printed $count lines, expected 12"
  exit 1
fi

found=0
for l in "${lines[@]}"; do
  if [ "$l" = "pve-cluster" ]; then
    found=1
  fi
done
if [ "$found" -ne 1 ]; then
  echo "FAIL: --list did not include pve-cluster"
  exit 1
fi

echo "OK: fetch-upstream.sh --list prints 12 lines including pve-cluster"
