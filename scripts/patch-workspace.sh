#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_PACKAGES="${UPSTREAM_PACKAGES:-$repo_root/upstream/pxvirt/packages}"
PATCHES_DIR="${PATCHES_DIR:-$repo_root/patches}"

usage() {
  printf 'usage: %s <component>\n' "${0##*/}" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
component="$1"

src="$UPSTREAM_PACKAGES/$component/$component"
if [ ! -d "$src" ]; then
  printf 'ERROR: component source not found: %s\n' "$src" >&2
  exit 2
fi

work="$repo_root/build/work/$component"
orig="$work/orig"
new="$work/new"

rm -rf "$work"
mkdir -p "$orig" "$new"

rsync -a --delete --exclude .git "$src/" "$orig/"
rsync -a --delete --exclude .git "$src/" "$new/"

apply_patch() {
  local dir="$1" pfile="$2"
  if ! ( cd "$dir" && patch -p1 --forward --batch < "$pfile" >/dev/null ); then
    printf 'ERROR: patch failed to apply: %s (in %s)\n' "$pfile" "$dir" >&2
    return 1
  fi
}

pdir="$PATCHES_DIR/$component"
if [ -d "$pdir" ]; then
  while IFS= read -r -d '' p; do
    apply_patch "$orig" "$p"
    apply_patch "$new" "$p"
  done < <(find "$pdir" -maxdepth 1 -type f -name '*.patch' -print0 | LC_ALL=C sort -z)
fi

printf 'Workspace ready: %s (edit files under new/ only)\n' "$work"
