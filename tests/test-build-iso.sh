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
if ! printf '%s\n' "$out" | grep -qE '^DRY-RUN: cd .*lb build$'; then
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

# ZERO systemd: the ISO must pin systemd away.
if ! printf '%s\n' "$out" | grep -qF -- 'systemd -1'; then
  echo "FAIL: --dry-run output missing the systemd -1 pin"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: build-iso.sh --dry-run prints the worktree, packages.chroot staging, the three archive files, the ISO name and the 2 GiB limit"
