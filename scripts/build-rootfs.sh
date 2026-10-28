#!/usr/bin/env bash
set -euo pipefail

VM_DIR="${SUPERMOX_VM_DIR:-/media/rhy/data/supermox-vm}"
MIRROR="${SUPERMOX_MIRROR:-http://deb.devuan.org/merged}"
SUITE="${SUPERMOX_SUITE:-ceres}"
IMAGE_SIZE="${SUPERMOX_IMAGE_SIZE:-20G}"

# mmdebstrap builds in TMPDIR; /tmp is RAM on the build machine, so keep it on disk.
# The unshared build user must be able to enter TMPDIR, so it lives in the repo, not under /media/rhy/data (mode 700).
export TMPDIR="${SUPERMOX_TMPDIR:-$(cd "$(dirname "$0")/.." && pwd)/build/tmp}"

KEYRING=/usr/share/keyrings/devuan-archive-keyring.gpg
COMPONENTS=main,contrib,non-free-firmware

BASE_PKGS=sysvinit-core,sysv-rc,init-system-helpers,linux-image-amd64,openssh-server,ifupdown,dhcpcd-base,opensysusers,util-linux-extra,devuan-keyring,rsyslog,cron,ca-certificates,less
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

tarball="$VM_DIR/rootfs.tar"
img="$VM_DIR/rootfs.img"

setup_hook='printf "Package: systemd\nPin: version *\nPin-Priority: -1\n\nPackage: systemd-sysv\nPin: version *\nPin-Priority: -1\n\nPackage: libsystemd0\nPin: version *\nPin-Priority: -1\n\nPackage: libpam-systemd\nPin: version *\nPin-Priority: -1\n\nPackage: systemd-standalone-sysusers\nPin: version *\nPin-Priority: -1\n" > "$1/etc/apt/preferences.d/no-systemd"'

customize_hooks=(
  'echo supermox > "$1/etc/hostname"'
  'chroot "$1" sh -c "echo root:supermox | chpasswd"'
  'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" "$1/etc/ssh/sshd_config"'
  'printf "auto eth0\niface eth0 inet dhcp\n" > "$1/etc/network/interfaces"'
  'printf "/dev/vda / ext4 defaults 0 1\n" >> "$1/etc/fstab"'
  # util-linux-extra is in the include list: dracut needs its switch_root without systemd, but does not depend on it.
  # Maintainer scripts mask services for systemd with /dev/null links in /etc/systemd; sysvinit never reads them.
  'rm -rf "$1/etc/systemd"'
  'printf "DPkg::Post-Invoke { \"rm -rf /etc/systemd\"; };\n" > "$1/etc/apt/apt.conf.d/99supermox-no-systemd"'
)

cmd=(
  mmdebstrap
  --mode=unshare
  --variant=apt
  --format=tar
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
