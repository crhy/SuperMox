#!/usr/bin/env bash
set -euo pipefail

VM_SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2223}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

remote() {
  sshpass -p supermox ssh -p "$VM_SSH_PORT" "${ssh_opts[@]}" root@127.0.0.1 "$@"
}

waited=0
until remote true 2>/dev/null; do
  if [ "$waited" -ge 180 ]; then
    printf 'FAIL: ssh not reachable within 180s\n'
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done

fail=0

init_path="$(remote 'readlink -f /proc/1/exe' 2>/dev/null || true)"
# /sbin is a symlink to /usr/sbin on merged-/usr systems, so PID 1 may show as /usr/sbin/init.
dpkg_line="$(remote "dpkg -S $init_path" 2>/dev/null || true)"
if { [ "$init_path" = "/sbin/init" ] || [ "$init_path" = "/usr/sbin/init" ]; } && printf '%s\n' "$dpkg_line" | grep -q 'sysvinit-core'; then
  printf 'PASS: PID 1 is sysvinit-core (%s)\n' "$init_path"
else
  printf 'FAIL: PID 1 not sysvinit-core (exe=%s dpkg=%s)\n' "$init_path" "$dpkg_line"
  fail=1
fi

src="$repo_root/scripts/check-no-systemd.sh"
dst="/root/check-no-systemd.sh"
if sshpass -p supermox scp -P "$VM_SSH_PORT" "${ssh_opts[@]}" "$src" "root@127.0.0.1:$dst"; then
  if remote "bash '$dst' --image /"; then
    printf 'PASS: check-no-systemd.sh --image /\n'
  else
    printf 'FAIL: check-no-systemd.sh --image /\n'
    fail=1
  fi
else
  printf 'FAIL: could not copy check-no-systemd.sh to VM\n'
  fail=1
fi

if remote 'test -e /dev/kvm'; then
  printf 'PASS: /dev/kvm present (nested KVM)\n'
else
  printf 'FAIL: /dev/kvm missing (no nested KVM)\n'
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'All VM smoke checks passed.\n'
