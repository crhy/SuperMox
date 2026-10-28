#!/usr/bin/env bash
set -euo pipefail

PXVIRT_URL=https://github.com/jiangcuo/pxvirt
PXVIRT_COMMIT=57302a2060f34e158b81c471ea68e9ee02ef5d5a
COMPONENTS=(
  pve-manager
  pve-cluster
  pve-common
  qemu-server
  pve-container
  pve-storage
  pve-access-control
  pve-ha-manager
  pve-firewall
  pve-http-server
  pve-guest-common
  proxmox-ve
)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo_root/upstream/pxvirt"

if [ "${1:-}" = "--list" ]; then
  for c in "${COMPONENTS[@]}"; do
    printf '%s\n' "$c"
  done
  exit 0
fi

if [ ! -d "$dest" ]; then
  git clone --branch pxvirt "$PXVIRT_URL" "$dest"
  git -C "$dest" checkout "$PXVIRT_COMMIT"
else
  head="$(git -C "$dest" rev-parse HEAD)"
  if [ "$head" != "$PXVIRT_COMMIT" ]; then
    echo "ERROR: $dest HEAD is $head, expected $PXVIRT_COMMIT" >&2
    exit 1
  fi
fi

for c in "${COMPONENTS[@]}"; do
  git -C "$dest" submodule update --init --depth 1 "packages/$c/$c"
done
