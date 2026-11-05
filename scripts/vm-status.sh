#!/usr/bin/env bash
# Which SuperMox VMs are running (build, test, arm64, and the ISO boot from
# scripts/vm-boot-iso.sh), and does ssh answer? Lets agents check without touching
# the VM data paths. The ISO boot has no ssh port: its handles are its -pidfile,
# its QMP socket and its serial log, all under build/iso-boot/.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
found=0
for pid in $(pgrep -x 'qemu-system-x86' || true) $(pgrep -x 'qemu-system-aar' || true); do
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  case "$cmd" in
    # Matched first: the ISO guest's paths contain neither "supermox-vm" nor
    # "vm-data", so without this branch it is invisible to this script -- which
    # is how a previous run's qemu came back as "no SuperMox VM running" while
    # it held its RAM.
    *iso-boot*)
      found=1
      pf="${cmd##*-pidfile }"; pf="${pf%% *}"
      dir="$(dirname "$pf")"
      if [ -S "$dir/qmp.sock" ]; then
        printf 'iso VM running (pid %s, QMP %s): serial log %s bytes\n' \
          "$pid" "$dir/qmp.sock" "$(wc -c < "$dir/serial.log" 2>/dev/null || printf 0)"
      else
        printf 'iso VM running (pid %s): QMP socket %s missing\n' "$pid" "$dir/qmp.sock"
      fi
      continue ;;
    # arm64 first: its data dir is .../supermox-vm-arm64, which would otherwise match the
    # build VM pattern below and be reported with the wrong ssh port.
    *arm64*) name="arm64"; port=${SUPERMOX_ARM64_SSH_PORT:-2225} ;;
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
