#!/usr/bin/env bash
# Which SuperMox VMs are running, and does ssh answer? Lets agents check without touching the VM data paths.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
found=0
for pid in $(pgrep -x 'qemu-system-x86' || true) $(pgrep -x 'qemu-system-aar' || true); do
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  case "$cmd" in
    *supermox-test*|*test-data*) name="test"; port=${SUPERMOX_TEST_SSH_PORT:-2224} ;;
    *supermox-vm*|*vm-data*) name="build"; port=2223 ;;
    *) continue ;;
  esac
  found=1
  if SUPERMOX_VM_SSH_PORT=$port timeout 10 bash "$repo_root/scripts/vm-ssh.sh" true >/dev/null 2>&1; then
    printf '%s VM running (pid %s, ssh port %s): ssh OK\n' "$name" "$pid" "$port"
  else
    printf '%s VM running (pid %s, ssh port %s): ssh NOT answering\n' "$name" "$pid" "$port"
  fi
done
[ "$found" -eq 1 ] || printf 'no SuperMox VM running\n'
