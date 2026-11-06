#!/usr/bin/env bash
set -euo pipefail

# Architecture mapping: SUPERMOX_ARCH (Debian arch name) plus the QEMU binary/console/machine
# helpers. The build host's arch is only the first test target; this script starts a VM for any arch.
source "$(dirname "$0")/arch.sh"
# Paths: environment > config/local.env > build/ default (see docs/development.md).
source "$(dirname "$0")/local-env.sh"
# Shared pidfile/command-line lookup (also used by vm-stop.sh).
source "$(dirname "$0")/vm-pid.sh"

# Absolute, symlink-free VM_DIR: vm-start.sh writes this path into the -pidfile argument,
# and vm-stop.sh matches that argument to find the process, so a relative SUPERMOX_VM_DIR
# (e.g. build/test-data) has to be canonicalised here first.
VM_DIR="$(supermox_canon_path "$SUPERMOX_VM_DIR")"
VM_RAM="${SUPERMOX_VM_RAM:-4096}"
VM_CPUS="${SUPERMOX_VM_CPUS:-4}"
VM_SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2223}"
# Optional extra hostfwd entries (comma-separated tcp:127.0.0.1:HOSTPORT-:GUESTPORT),
# e.g. to expose the node's pveproxy port to the host for the desktop Manager's live tests.
VM_FWD="${SUPERMOX_VM_FWD:-}"

dry_run=0
background=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --background) background=1 ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

qemu_bin="$(supermox_qemu_bin)"
expected_comm="$(supermox_qemu_comm)"
console="$(supermox_console)"
mapfile -t mach_opts < <(supermox_machine_opts_words)

cmd=(
  "$qemu_bin"
  "${mach_opts[@]}"
)

host_arch="$(dpkg --print-architecture)"
if [ "$SUPERMOX_ARCH" = "$host_arch" ] && [ -e /dev/kvm ]; then
  cmd+=(-enable-kvm -cpu host)
else
  printf 'NOTE: no native KVM for arch %s on this %s host: using -cpu max (QEMU TCG emulation, slow).\n' "$SUPERMOX_ARCH" "$host_arch" >&2
  cmd+=(-cpu max)
fi

nic="user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22"
if [ -n "$VM_FWD" ]; then
  IFS=',' read -ra fwd_entries <<< "$VM_FWD"
  for entry in "${fwd_entries[@]}"; do
    if [[ ! "$entry" =~ ^tcp:127\.0\.0\.1:[0-9]+-:[0-9]+$ ]]; then
      printf 'ERROR: invalid SUPERMOX_VM_FWD entry: %s (want tcp:127.0.0.1:HOSTPORT-:GUESTPORT)\n' "$entry" >&2
      exit 2
    fi
    nic+=",hostfwd=$entry"
  done
fi

cmd+=(
  -m "$VM_RAM"
  -smp "$VM_CPUS"
  -kernel "$VM_DIR/vmlinuz"
  -initrd "$VM_DIR/initrd.img"
  -append "root=/dev/vda rw console=$console net.ifnames=0"
  -drive "file=$VM_DIR/rootfs.img,format=raw,if=virtio"
  -nic "$nic"
)

if [ "$background" -eq 1 ]; then
  cmd+=(
    -display none
    -serial "file:$VM_DIR/serial.log"
    -daemonize
    -pidfile "$VM_DIR/qemu.pid"
  )
else
  cmd+=(-nographic -serial mon:stdio)
fi

print_cmd() {
  local line="" a
  for a in "$@"; do
    case "$a" in
      *[[:space:]]*) line+="\"$a\" " ;;
      *) line+="$a " ;;
    esac
  done
  printf '%s\n' "$line"
}

if [ "$dry_run" -eq 1 ]; then
  print_cmd "${cmd[@]}"
  exit 0
fi

# Never start a second qemu for a VM_DIR that already has one running: two processes
# sharing one disk image corrupt it, and their pidfiles fight each other (QEMU unlinks
# -pidfile when it exits), which is how a running VM became un-stoppable and two VMs
# ran at once. --dry-run starts nothing, so it is not blocked by this check.
running_pid="$(supermox_find_qemu_pid "$VM_DIR/qemu.pid" "$expected_comm" || true)"
if [ -n "$running_pid" ]; then
  printf 'ERROR: a qemu process for VM_DIR %s is already running (pid %s); refusing to start a second instance.\n' "$VM_DIR" "$running_pid" >&2
  printf 'Stop it first: bash scripts/vm-stop.sh (with the same SUPERMOX_VM_DIR).\n' >&2
  exit 1
fi

missing=0
for f in "$VM_DIR/vmlinuz" "$VM_DIR/initrd.img" "$VM_DIR/rootfs.img"; do
  if [ ! -f "$f" ]; then
    printf 'ERROR: missing input file: %s\n' "$f" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  exit 1
fi

exec "${cmd[@]}"
