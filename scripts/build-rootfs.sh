#!/usr/bin/env bash
set -euo pipefail

# Architecture mapping: SUPERMOX_ARCH (Debian arch name) plus the kernel/QEMU/console
# helpers. The build host's arch is only the first test target; this script works for any arch.
source "$(dirname "$0")/arch.sh"

VM_DIR="${SUPERMOX_VM_DIR:-/media/rhy/data/supermox-vm}"
MIRROR="${SUPERMOX_MIRROR:-http://deb.devuan.org/merged}"
SUITE="${SUPERMOX_SUITE:-ceres}"
IMAGE_SIZE="${SUPERMOX_IMAGE_SIZE:-20G}"

# mmdebstrap builds in TMPDIR; /tmp is RAM on the build machine, so keep it on disk.
# The unshared build user must be able to enter TMPDIR, so it lives in the repo, not under /media/rhy/data (mode 700).
export TMPDIR="${SUPERMOX_TMPDIR:-$(cd "$(dirname "$0")/.." && pwd)/build/tmp}"

KEYRING=/usr/share/keyrings/devuan-archive-keyring.gpg
COMPONENTS=main,contrib,non-free-firmware

# ifupdown (classic) is not used: it depends on systemd-provided sysusers and its
# /etc/init.d/networking becomes an orphan when ifupdown2 replaces it later, which
# breaks boot networking. ifupdown2 provides the tools; SuperMox ships the init script.
BASE_PKGS=sysvinit-core,sysv-rc,init-system-helpers,openssh-server,ifupdown2,iproute2,dhcpcd-base,opensysusers,util-linux-extra,devuan-keyring,rsyslog,cron,ca-certificates,less
KERNEL_PKG="$(supermox_kernel_pkg)"
BASE_PKGS="$KERNEL_PKG,$BASE_PKGS"
EXTRA_PKGS="${SUPERMOX_EXTRA_PKGS:-lsb-base}"
if [ -n "$EXTRA_PKGS" ]; then
  INCLUDE="$BASE_PKGS,$EXTRA_PKGS"
else
  INCLUDE="$BASE_PKGS"
fi

dry_run=0
force=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# A foreign-arch rootfs needs the host kernel to run foreign binaries via binfmt_misc.
# Do not install anything: tell the operator what is missing and stop. Skipped for --dry-run.
if [ "$dry_run" -ne 1 ]; then
  host_arch="$(dpkg --print-architecture)"
  if [ "$SUPERMOX_ARCH" != "$host_arch" ] && [ ! -e "/proc/sys/fs/binfmt_misc/qemu-$SUPERMOX_ARCH" ]; then
    printf 'ERROR: building a %s rootfs on a %s host needs foreign-arch execution via binfmt_misc.\n' "$SUPERMOX_ARCH" "$host_arch" >&2
    printf 'Install the qemu-user-binfmt package on the build host (apt install qemu-user-binfmt), then re-run.\n' >&2
    exit 2
  fi
fi

tarball="$VM_DIR/rootfs.tar"
img="$VM_DIR/rootfs.img"

setup_hook='printf "Package: systemd\nPin: version *\nPin-Priority: -1\n\nPackage: systemd-sysv\nPin: version *\nPin-Priority: -1\n\nPackage: libsystemd0\nPin: version *\nPin-Priority: -1\n\nPackage: libpam-systemd\nPin: version *\nPin-Priority: -1\n\nPackage: systemd-standalone-sysusers\nPin: version *\nPin-Priority: -1\n\nPackage: systemd-standalone-tmpfiles\nPin: version *\nPin-Priority: -1\n" > "$1/etc/apt/preferences.d/no-systemd"'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

customize_hooks=(
  'echo supermox > "$1/etc/hostname"'
  'printf "127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n" > "$1/etc/hosts"'
  'chroot "$1" sh -c "echo root:supermox | chpasswd"'
  'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" "$1/etc/ssh/sshd_config"'
  # Devuan ships dhcpcd, not dhclient, and ifupdown2's "inet dhcp" method hard-codes
  # /sbin/dhclient, so DHCP is done by /etc/init.d/networking running dhcpcd directly.
  # interfaces keeps only the stanzas ifupdown2 does handle (loopback, static, manual).
  # It must contain at least one stanza: ifup -a with an empty file exits non-zero with
  # "no ifaces found matching given allow lists" and S10networking would report failure.
  'mkdir -p "$1/etc/network"'
  'copy-in '"$repo_root"'/config/network/interfaces /etc/network/'
  'printf "/dev/vda / ext4 defaults 0 1\n" >> "$1/etc/fstab"'
  # util-linux-extra is in the include list: dracut needs its switch_root without systemd, but does not depend on it.
  # Maintainer scripts mask services for systemd with /dev/null links in /etc/systemd; sysvinit never reads them.
  'rm -rf "$1/etc/systemd"'
  'printf "DPkg::Post-Invoke { \"rm -rf /etc/systemd\"; };\n" > "$1/etc/apt/apt.conf.d/99supermox-no-systemd"'
  # ifupdown2 ships no init script, so the base image must carry SuperMox's own
  # /etc/init.d/networking. sysv-rc boots runlevel S make-style: startpar only runs the scripts
  # listed in /etc/init.d/.depend.boot, which insserv generates from the init script's LSB header
  # and the rc?.d links. A hand-made rcS.d symlink is therefore not enough - networking would
  # never run - so let update-rc.d create the links and regenerate the dependency files.
  'copy-in '"$repo_root"'/init.d/networking /etc/init.d/'
  'chmod 755 "$1/etc/init.d/networking"'
  'chroot "$1" update-rc.d networking defaults'
  # QEMU gives the guest its NIC as a virtio-net-pci device, but the kernel initramfs has no
  # virtio_net.ko and nothing autoloads it under sysvinit, so eth0 never exists and S10networking
  # has nothing to configure. /etc/init.d/kmod (rcS.d/S06kmod, i.e. before S10networking) loads
  # the modules listed in /etc/modules-load.d/.
  'mkdir -p "$1/etc/modules-load.d"'
  'copy-in '"$repo_root"'/config/modules-load.d/supermox.conf /etc/modules-load.d/'
)

cmd=(
  mmdebstrap
  --mode=unshare
  --variant=apt
  --format=tar
  --architectures="$SUPERMOX_ARCH"
  --keyring="$KEYRING"
  --components="$COMPONENTS"
  --include="$INCLUDE"
  --dpkgopt='path-exclude=/lib/systemd/*'
  --dpkgopt='path-exclude=/usr/lib/systemd/*'
  --dpkgopt='path-exclude=/etc/systemd/*'
  --setup-hook="$setup_hook"
)
for h in "${customize_hooks[@]}"; do
  cmd+=(--customize-hook="$h")
done
cmd+=("$SUITE" "$tarball" "$MIRROR")

mke2fs_cmd=(
  /sbin/mke2fs
  -t ext4
  -F
  -L supermox
  -d "$tarball"
  "$img"
)

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
  printf 'truncate -s %s %s\n' "$IMAGE_SIZE" "$img"
  print_cmd "${mke2fs_cmd[@]}"
  exit 0
fi

if [ -f "$img" ] && [ "$force" -ne 1 ]; then
  printf 'ERROR: refusing to overwrite existing %s (pass --force)\n' "$img" >&2
  exit 1
fi

mkdir -p "$VM_DIR" "$TMPDIR"

"${cmd[@]}"

tmp="$VM_DIR/rootfs-kernel-tmp"
rm -rf "$tmp"
mkdir -p "$tmp"
tar -xf "$tarball" -C "$tmp" --wildcards './boot/vmlinuz-*' './boot/initrd.img-*'

newest_vmlinuz=""
for f in "$tmp"/boot/vmlinuz-*; do
  [ -e "$f" ] || continue
  newest_vmlinuz="$f"
done
newest_initrd=""
for f in "$tmp"/boot/initrd.img-*; do
  [ -e "$f" ] || continue
  newest_initrd="$f"
done
if [ -z "$newest_vmlinuz" ] || [ -z "$newest_initrd" ]; then
  printf 'ERROR: no kernel or initrd found in %s\n' "$tarball" >&2
  exit 1
fi
cp "$newest_vmlinuz" "$VM_DIR/vmlinuz"
cp "$newest_initrd" "$VM_DIR/initrd.img"
rm -rf "$tmp"

truncate -s "$IMAGE_SIZE" "$img"
"${mke2fs_cmd[@]}"

# mke2fs -d can silently leave entries out of the image (and dpkg inside a booted VM later
# drops the rcS.d link again), so verify the paths that decide whether the VM boots with a
# network. debugfs exits 0 even when a path is missing, so grep its output instead.
if [ -x /usr/sbin/debugfs ]; then
  cmds="$TMPDIR/rootfs-verify.cmds"
  printf 'stat /etc/init.d/networking\nstat /etc/modules-load.d/supermox.conf\n' > "$cmds"
  missing="$(/usr/sbin/debugfs -f "$cmds" "$img" 2>&1 | grep -E 'not found' || true)"
  rm -f "$cmds"
  if [ -n "$missing" ]; then
    printf 'ERROR: %s is missing boot-critical paths:\n%s\n' "$img" "$missing" >&2
    exit 1
  fi
  # sysv-rc boots runlevel S make-style: startpar only runs scripts that have both an rcS.d
  # link and an entry in .depend.boot, so both must name networking.
  if ! /usr/sbin/debugfs -R 'ls /etc/rcS.d' "$img" 2>/dev/null | grep -q 'networking'; then
    printf 'ERROR: %s: no networking link in /etc/rcS.d; the network would never come up at boot\n' "$img" >&2
    exit 1
  fi
  if ! /usr/sbin/debugfs -R 'cat /etc/init.d/.depend.boot' "$img" 2>/dev/null | grep -q 'networking'; then
    printf 'ERROR: %s: /etc/init.d/.depend.boot does not list networking; it would never run at boot\n' "$img" >&2
    exit 1
  fi
  printf 'Verified boot-critical paths in %s\n' "$img"
else
  printf 'WARNING: /usr/sbin/debugfs not installed; image not verified\n' >&2
fi
