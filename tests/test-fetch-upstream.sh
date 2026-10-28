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
if [ "$count" -ne 13 ]; then
  echo "FAIL: --list printed $count lines, expected 13"
  exit 1
fi

for want in pve-cluster pve-access-control proxmox-perl-rs; do
  found=0
  for l in "${lines[@]}"; do
    if [ "$l" = "$want" ]; then
      found=1
    fi
  done
  if [ "$found" -ne 1 ]; then
    echo "FAIL: --list did not include $want"
    exit 1
  fi
done

echo "OK: fetch-upstream.sh --list prints 13 lines including pve-cluster, pve-access-control and proxmox-perl-rs"
