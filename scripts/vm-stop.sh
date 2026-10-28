#!/usr/bin/env bash
set -euo pipefail

# Architecture mapping: the expected QEMU process comm depends on SUPERMOX_ARCH.
source "$(dirname "$0")/arch.sh"

VM_DIR="${SUPERMOX_VM_DIR:-/media/rhy/data/supermox-vm}"
pidfile="$VM_DIR/qemu.pid"

if [ ! -f "$pidfile" ]; then
  printf 'No pidfile: %s\n' "$pidfile"
  exit 0
fi

pid="$(tr -dc '0-9' < "$pidfile")"
if [ -z "$pid" ]; then
  printf 'ERROR: empty pidfile: %s\n' "$pidfile" >&2
  exit 1
fi

comm_file="/proc/$pid/comm"
if [ ! -r "$comm_file" ]; then
  printf 'Not running: pid %s\n' "$pid"
  exit 0
fi

comm="$(tr -d '\n' < "$comm_file")"
expected_comm="$(supermox_qemu_comm)"
if [ "$comm" != "$expected_comm" ]; then
  printf 'ERROR: pid %s is %s, not %s; refusing to kill\n' "$pid" "$comm" "$expected_comm" >&2
  exit 1
fi

printf 'Stopping qemu pid %s\n' "$pid"
kill -TERM "$pid" 2>/dev/null || true

for _ in $(seq 1 30); do
  if [ ! -d "/proc/$pid" ]; then
    printf 'Stopped.\n'
    exit 0
  fi
  sleep 1
done

printf 'WARN: pid %s still running after 30s\n' "$pid" >&2
exit 1
