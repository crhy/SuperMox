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
if [ "$count" -ne 14 ]; then
  echo "FAIL: --list printed $count lines, expected 14"
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

ov_out="$(bash "$target" --list-overrides)"
ov_line="proxmox-perl-rs c6b798f72a7e9f1063d75b144835d63781006ef4"
if ! printf '%s\n' "$ov_out" | grep -qxF -- "$ov_line"; then
  echo "FAIL: --list-overrides did not print: $ov_line"
  printf '%s\n' "$ov_out"
  exit 1
fi

co="upstream/pxvirt/packages/proxmox-perl-rs/proxmox-perl-rs"
if [ -d "$co" ]; then
  head="$(git -C "$co" rev-parse HEAD)"
  if [ "$head" != "c6b798f72a7e9f1063d75b144835d63781006ef4" ]; then
    echo "FAIL: $co HEAD is $head, expected override c6b798f72a7e9f1063d75b144835d63781006ef4"
    exit 1
  fi
fi

echo "OK: fetch-upstream.sh --list prints 14 lines including pve-cluster, pve-access-control and proxmox-perl-rs; --list-overrides prints the proxmox-perl-rs override and the checkout HEAD matches it"
