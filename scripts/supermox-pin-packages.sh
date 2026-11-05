#!/usr/bin/env bash
# Print the binary package names SuperMox builds itself: every Package: line
# in every debian/control under the patched upstream tree apply-patches.sh
# produces (default build/patched; proxmox-perl-rs ships three debian/ dirs,
# one per Rust/Perl sub-package). Sorted, deduplicated, one name per line.
#
# The -1 stanza of packaging/supermox-ve/etc/apt/preferences.d/supermox-origins
# must list exactly these names: tests/test-supermox-ve.sh runs this script
# and fails the gate when the checked-in stanza and this list drift apart, so
# the pin cannot go stale when a component is added or a control file gains
# a package.
#
# Usage: scripts/supermox-pin-packages.sh [patched-dir]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$repo_root/build/patched}"

if [ ! -d "$dir" ]; then
  printf 'ERROR: patched tree not found: %s (run scripts/apply-patches.sh first)\n' "$dir" >&2
  exit 2
fi

find "$dir" -name .git -prune -o -type f -path '*/debian/control' -print0 |
  LC_ALL=C sort -z |
  xargs -0 -r awk '/^Package: /{print $2}' |
  LC_ALL=C sort -u
