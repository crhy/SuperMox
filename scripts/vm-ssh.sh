#!/usr/bin/env bash
set -euo pipefail

VM_SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2223}"

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

exec sshpass -p supermox ssh \
  -p "$VM_SSH_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  root@127.0.0.1 "$@"
