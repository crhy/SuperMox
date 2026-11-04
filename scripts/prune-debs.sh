#!/usr/bin/env bash
# Remove superseded .deb files from a local repo directory.
#
# For each (Package, Architecture) keep only the highest Version; delete the
# rest. dpkg-deb reads the real fields from each archive because filenames are
# unreliable: the Rust toolchain embeds underscores in the version, so the
# package/version/arch cannot be split out of the name. Version comparison uses
# dpkg --compare-versions (the same ordering apt/dpkg use).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <dir>\n' "$0" >&2
  exit 2
fi
dir="$1"
[ -d "$dir" ] || exit 0

shopt -s nullglob
debs=("$dir"/*.deb)
[ "${#debs[@]}" -gt 0 ] || exit 0

declare -A best_ver best_file
for f in "${debs[@]}"; do
  pkg="$(dpkg-deb -f "$f" Package 2>/dev/null)" || continue
  ver="$(dpkg-deb -f "$f" Version 2>/dev/null)" || continue
  arch="$(dpkg-deb -f "$f" Architecture 2>/dev/null)" || continue
  [ -n "$pkg" ] && [ -n "$arch" ] || continue
  key="$pkg|$arch"
  if [ -z "${best_ver[$key]:-}" ] || dpkg --compare-versions "$ver" gt "${best_ver[$key]}"; then
    best_ver[$key]="$ver"
    best_file[$key]="$f"
  fi
done

for f in "${debs[@]}"; do
  pkg="$(dpkg-deb -f "$f" Package 2>/dev/null)" || continue
  arch="$(dpkg-deb -f "$f" Architecture 2>/dev/null)" || continue
  key="$pkg|$arch"
  if [ "$f" != "${best_file[$key]}" ]; then
    printf 'prune: %s superseded by %s\n' "$(basename "$f")" "$(basename "${best_file[$key]}")" >&2
    rm -f "$f"
  fi
done
