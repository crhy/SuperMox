#!/usr/bin/env bash
# repack-init.sh — refresh the /etc/init.d scripts inside an already-built .deb
# with the current init.d/<service> files from this repo, then repack.
#
# Used when a full dpkg-buildpackage rebuild is not possible (e.g. uninstallable
# Proxmox build-deps on Devuan) but the only change to ship is an init script.
#
# Usage: repack-init.sh <deb-file> <service> [<service> ...]
#   Rewrites <deb-file> in place (a .bak is kept). The init.d/<service> files
#   come from this repo. md5sums are recomputed so dpkg stays consistent.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -lt 2 ]]; then
  echo "usage: repack-init.sh <deb-file> <service> [<service> ...]" >&2
  exit 2
fi

deb="$1"; shift
services=("$@")

for s in "${services[@]}"; do
  [[ -f "$repo_root/init.d/$s" ]] || die "no init.d/$s in repo"
done

mkdir -p "$repo_root/build"
work="$(mktemp -d "$repo_root/build/repack.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cp "$deb" "$deb.bak"
mkdir -p "$work/DEBIAN"
dpkg-deb -e "$deb" "$work/DEBIAN"
dpkg-deb -x "$deb" "$work"

for s in "${services[@]}"; do
  dest="$work/etc/init.d/$s"
  [[ -f "$dest" ]] || die "deb has no ./etc/init.d/$s (expected a conffile)"
  install -m 0755 "$repo_root/init.d/$s" "$dest"
  newmd5="$(md5sum "$dest" | cut -d' ' -f1)"
  if [[ -f "$work/DEBIAN/md5sums" ]]; then
    python3 - "$work/DEBIAN/md5sums" "./etc/init.d/$s" "$newmd5" <<'PY'
import sys
path, target, md5 = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path):
    parts = line.rstrip("\n").split(" ", 1)
    if len(parts) == 2 and parts[1] == target:
        out.append(f"{md5} {target}")
    else:
        out.append(line.rstrip("\n"))
open(path, "w").write("\n".join(out) + "\n")
PY
  fi
done

mkdir -p "$repo_root/build"
out="$repo_root/build/repack-out.$$.deb"
dpkg-deb -Zgzip --root-owner-group -b "$work" "$out" >/dev/null
cp "$out" "$deb"
rm -f "$out"

echo "PASS: repacked $(basename "$deb") with init.d: ${services[*]}"
