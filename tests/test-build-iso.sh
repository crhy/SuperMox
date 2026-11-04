#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/build-iso.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run)"

missing=0
for pat in \
  'worktree add --detach' \
  'build/spaced-iso' \
  'config/packages.chroot/' \
  'config/archives/proxmox.list.chroot' \
  'config/archives/proxmox.key.chroot' \
  'config/archives/supermox.pref.chroot' \
  'config/archives/supermox-no-systemd.pref.chroot' \
  'supermox-10.26-pc-amd64.iso' \
  'supermox-ve' \
  'config/includes.chroot/etc/supermox/release' \
  '2 GiB'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run output missing: $pat"
    missing=1
  fi
done

# The live-build run needs root: --dry-run may only show it, never run it.
if ! printf '%s\n' "$out" | grep -qE '^DRY-RUN: sudo bash .*iso-pre-clean\.sh && cd .*lb build$'; then
  echo "FAIL: --dry-run must print, not run, the lb build command"
  missing=1
fi

# Debug packages and mk-build-deps helpers must never reach the ISO.
if printf '%s\n' "$out" | grep -qE -- '-(dbgsym|build-deps)_[^/]*\.deb$'; then
  echo "FAIL: --dry-run stages a -dbgsym or -build-deps package"
  missing=1
fi

# Newest version only: supermox-ve must be staged exactly once.
ve_count="$(printf '%s\n' "$out" | grep -cE 'supermox-ve_[^_]*_all\.deb$' || true)"
if [ "${ve_count:-0}" -gt 1 ]; then
  echo "FAIL: supermox-ve staged $ve_count times (only the newest version may go in)"
  missing=1
fi

# The deb dir must be the documented SUPERMOX_DEBS_DIR (where vm-build-pkg.sh
# writes debs), never a hard-coded path: a fresh clone has no such directory and
# would either fail or stage stale debs into the ISO.
marker_dir="$PWD/build/test-iso-debs"
rm -rf "$marker_dir"
mkdir -p "$marker_dir"
: > "$marker_dir/supermox-ve_9.9.9_all.deb"
marker_out="$(SUPERMOX_DEBS_DIR="$marker_dir" bash "$target" --dry-run)"
if ! printf '%s\n' "$marker_out" | grep -qF -- "$marker_dir/supermox-ve_9.9.9_all.deb"; then
  echo "FAIL: --dry-run does not stage debs from SUPERMOX_DEBS_DIR"
  missing=1
fi
rm -rf "$marker_dir"

# ZERO systemd: the ISO must pin systemd away.
if ! printf '%s\n' "$out" | grep -qF -- 'systemd -1'; then
  echo "FAIL: --dry-run output missing the systemd -1 pin"
  missing=1
fi

# The ISO stages the pin before supermox-ve can be installed, so it must copy
# the conffile itself rather than keep its own list of names. live-build installs
# config/archives/<name>.pref.chroot as /etc/apt/preferences.d/<name>.pref for the
# chroot phase only and removes it before the binary stage, so the shipped ISO is
# left with exactly one copy of the pin: the package's conffile.
if ! grep -qF -- 'cp -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-no-systemd" "$lb_dir/config/archives/supermox-no-systemd.pref.chroot"' "$target"; then
  echo "FAIL: $target does not copy the supermox-ve pin conffile into config/archives"
  missing=1
fi
# The ISO's own pref stanza may only add names the package does not pin.
if grep -qE '^Package: .*(libsystemd0|libpam-systemd|systemd-standalone)' "$target"; then
  echo "FAIL: $target duplicates supermox-ve pin names in a stanza of its own"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: build-iso.sh --dry-run prints the worktree, packages.chroot staging, the archive and pin files, the ISO name and the 2 GiB limit"
