#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vm_ssh="$repo_root/scripts/vm-ssh.sh"

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

remote() {
  bash "$vm_ssh" "$@"
}

waited=0
until remote true 2>/dev/null; do
  if [ "$waited" -ge 180 ]; then
    printf 'FAIL: ssh not reachable within 180s\n' >&2
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done

mkdir -p "$repo_root/build"
remote_script="$repo_root/build/vm-setup-proxmox-repos.remote.sh"

cat > "$remote_script" <<'REMOTE'
set -e
export DEBIAN_FRONTEND=noninteractive
KEY_URL='https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg'
KEY_PATH='/usr/share/keyrings/proxmox-archive-keyring.gpg'

if [ ! -s "$KEY_PATH" ]; then
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$KEY_URL"
  mv "$tmp" "$KEY_PATH"
  chmod 644 "$KEY_PATH"
fi

printf 'deb [signed-by=%s] http://download.proxmox.com/debian/pve trixie pve-no-subscription\ndeb [signed-by=%s] http://download.proxmox.com/debian/devel trixie main\n' "$KEY_PATH" "$KEY_PATH" > /etc/apt/sources.list.d/proxmox.list
rm -f /etc/apt/sources.list.d/pve.list

cat > /etc/apt/preferences.d/supermox-origins <<'PIN'
Package: *
Pin: origin download.proxmox.com
Pin-Priority: 100

Package: *
Pin: origin ""
Pin-Priority: 900
PIN

apt-get update
REMOTE

if ! remote 'bash -s' < "$remote_script"; then
  printf 'FAIL: apt repository setup (keyring, sources, pins, apt-get update)\n' >&2
  exit 1
fi

fail=0

pol="$(remote 'apt-cache policy systemd' 2>/dev/null || true)"
if printf '%s\n' "$pol" | grep -qE '^[[:space:]]*Candidate:[[:space:]]*\(none\)[[:space:]]*$'; then
  printf 'PASS: apt-cache policy systemd candidate is (none)\n'
else
  printf 'FAIL: apt-cache policy systemd candidate is not (none)\n'
  fail=1
fi

if remote 'apt-get -s install pve-qemu-kvm lxc-pve' >/dev/null 2>&1; then
  printf 'PASS: apt-get -s install pve-qemu-kvm lxc-pve\n'
else
  printf 'FAIL: apt-get -s install pve-qemu-kvm lxc-pve\n'
  fail=1
fi

if remote 'apt-get -s install librust-proxmox-log-dev' >/dev/null 2>&1; then
  printf 'PASS: apt-get -s install librust-proxmox-log-dev\n'
else
  printf 'FAIL: apt-get -s install librust-proxmox-log-dev\n'
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'Proxmox repos configured (pve + devel trixie); Devuan/local win, systemd blocked.\n'
