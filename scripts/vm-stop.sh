#!/usr/bin/env bash
# Stop the VM belonging to one VM_DIR.
#
# A running VM must always be stoppable. The pidfile alone is not reliable: QEMU
# unlinks its -pidfile when it exits, so an instance that is still shutting down
# deletes the pidfile a NEW instance with the same VM_DIR has just written. vm-stop.sh
# then printed "No pidfile" and did nothing while a VM kept running (observed 3 times
# on 2026-11-04; two VMs at once pushed this PC into swap). So: use the pidfile when
# it names a live qemu process, otherwise find the process by its command line
# (scripts/vm-pid.sh, the vm-status.sh idea).
set -euo pipefail

# Architecture mapping: the expected QEMU process comm depends on SUPERMOX_ARCH.
source "$(dirname "$0")/arch.sh"
# Paths: environment > config/local.env > build/ default (see docs/development.md).
source "$(dirname "$0")/local-env.sh"
# Shared pidfile/command-line lookup.
source "$(dirname "$0")/vm-pid.sh"

# Absolute, symlink-free VM_DIR: the same canonicalisation vm-start.sh puts in its
# -pidfile argument, so a relative SUPERMOX_VM_DIR (e.g. build/test-data) still matches.
VM_DIR="$(supermox_canon_path "$SUPERMOX_VM_DIR")"
pidfile="$VM_DIR/qemu.pid"
expected_comm="$(supermox_qemu_comm)"

pid=""
how=""

if [ -f "$pidfile" ]; then
  file_pid="$(tr -dc '0-9' < "$pidfile")"
  if [ -z "$file_pid" ]; then
    printf 'ERROR: empty pidfile: %s\n' "$pidfile" >&2
    exit 1
  fi
  if [ -r "/proc/$file_pid/comm" ]; then
    comm="$(tr -d '\n' < "/proc/$file_pid/comm")"
    if [ "$comm" != "$expected_comm" ]; then
      printf 'ERROR: pid %s is %s, not %s; refusing to kill\n' "$file_pid" "$comm" "$expected_comm" >&2
      exit 1
    fi
    pid="$file_pid"
    how="pidfile"
  else
    printf 'Pidfile pid %s is not running; searching the command line instead\n' "$file_pid"
  fi
else
  printf 'No pidfile: %s\n' "$pidfile"
fi

if [ -z "$pid" ]; then
  pid="$(supermox_find_qemu_pid "$pidfile" "$expected_comm" || true)"
  if [ -n "$pid" ]; then
    how="command line"
  fi
fi

if [ -z "$pid" ]; then
  printf 'Not running: %s\n' "$VM_DIR"
  exit 0
fi

if [ "$how" = "pidfile" ]; then
  printf 'Stopping qemu pid %s (found in %s)\n' "$pid" "$pidfile"
else
  printf 'Stopping qemu pid %s (found by command line: -pidfile %s)\n' "$pid" "$pidfile"
fi

# TERM ends QEMU without a guest shutdown, so whatever the guest still held in
# its page cache never reached the disk image. Measured 2026-11-06: join-e2e's
# EXIT trap restored /etc/supermox inside the VM, release-check then stopped the
# VM here, and the image still held the test cluster (and the backup the restore
# deletes), so the next LAN-pair run refused that base. Ask THIS guest to sync
# first: its ssh port is read from this qemu's own hostfwd, never from the
# environment, so the sync can only reach the VM being stopped.
ssh_port="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
  | sed -n 's/.*hostfwd=tcp:127\.0\.0\.1:\([0-9][0-9]*\)-:22.*/\1/p' | head -n1)"
if [ -n "$ssh_port" ] && command -v sshpass >/dev/null 2>&1; then
  if timeout 30 sshpass -p supermox ssh -p "$ssh_port" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
      root@127.0.0.1 sync 2>/dev/null; then
    printf 'Guest filesystems synced (ssh port %s)\n' "$ssh_port"
  else
    printf 'WARN: could not sync the guest over ssh port %s; stopping anyway\n' "$ssh_port" >&2
  fi
fi

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
