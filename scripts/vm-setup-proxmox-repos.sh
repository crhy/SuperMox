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
  command -v curl >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null; }
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
Pin-Priority: 999

Explanation: qemu-server needs Proxmox's patched swtpm (0.10.2+pve1), not Devuan's.
Package: swtpm swtpm-libs swtpm-tools
Pin: origin download.proxmox.com
Pin-Priority: 600

Explanation: the pinned PXVIRT tree builds libpve-access-control 9.1.2, but the
 Proxmox repo's newest libpve-network-perl (1.6.8) requires libpve-access-control
 (>= 9.2.0). Hold the libpve-network-* packages at the release the pinned tree was cut with
 (1.6.7) so the locally built set stays self-consistent instead of half-upgraded.
 Re-derive this hold whenever upstream/pinned-commit.txt moves.
Package: libpve-network-*
Pin: version 1.6.7*
Pin-Priority: 990
PIN

printf 'deb http://deb.devuan.org/merged excalibur main\n' > /etc/apt/sources.list.d/excalibur-rust.list

cat > /etc/apt/preferences.d/supermox-rust-excalibur <<'RUSTPIN'
Explanation: Rust crates are build-time source only; nothing from them ships.
 Ceres crate versions are too new for Proxmox's trixie-targeted devel crates
 (e.g. proxmox-log needs nix 0.29 but Ceres has 0.30, and tracing-journald
 >=0.3.1 but Ceres has 0.3.0), so take crates from Devuan excalibur (trixie-era)
 and prefer Proxmox's own librust crates from download.proxmox.com.
 The compiler comes from Proxmox too: their crates need a newer rustc than
 excalibur's 1.85 (proxmox-schema 5.5 needs 1.88), and Proxmox builds with
 its own backported rustc.
Package: *
Pin: release n=excalibur
Pin-Priority: 50

Package: librust-* dh-cargo
Pin: release n=excalibur
Pin-Priority: 990

Package: librust-* rustc cargo libstd-rust-*
Pin: origin download.proxmox.com
Pin-Priority: 995
RUSTPIN

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

for pkg in libpve-network-perl libpve-network-api-perl; do
  pol="$(remote "apt-cache policy $pkg" 2>/dev/null || true)"
  if printf '%s\n' "$pol" | grep -qE '^[[:space:]]*Candidate:[[:space:]]*1\.6\.7'; then
    printf 'PASS: apt-cache policy %s candidate is the pinned-era 1.6.7\n' "$pkg"
  else
    printf 'FAIL: apt-cache policy %s candidate is not 1.6.7*\n' "$pkg"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'Proxmox repos configured (pve + devel trixie); Devuan/local win, systemd blocked.\n'
