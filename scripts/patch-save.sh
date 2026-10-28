#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_PACKAGES="${UPSTREAM_PACKAGES:-$repo_root/upstream/pxvirt/packages}"
PATCHES_DIR="${PATCHES_DIR:-$repo_root/patches}"

usage() {
  printf 'usage: %s <component> <slug>\n' "${0##*/}" >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi
component="$1"
slug="$2"

work="$repo_root/build/work/$component"
orig="$work/orig"
new="$work/new"
if [ ! -d "$orig" ] || [ ! -d "$new" ]; then
  printf 'ERROR: workspace missing; run patch-workspace.sh %s first\n' "$component" >&2
  exit 2
fi

pdir="$PATCHES_DIR/$component"
mkdir -p "$pdir"

max=0
while IFS= read -r f; do
  base="$(basename "$f")"
  num="${base%%-*}"
  n=$((10#$num))
  if [ "$n" -gt "$max" ]; then
    max="$n"
  fi
done < <(find "$pdir" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.patch' -print)

next=$((max + 1))
nnnn="$(printf '%04d' "$next")"
out="$pdir/$nnnn-$slug.patch"
if [ -e "$out" ]; then
  printf 'ERROR: patch file already exists: %s\n' "$out" >&2
  exit 1
fi

set +e
diff_body="$(cd "$work" && diff -ruN orig new)"
rc=$?
set -e

if [ "$rc" -eq 0 ] || [ -z "$diff_body" ]; then
  printf 'ERROR: no changes between orig and new; nothing to save\n' >&2
  exit 1
fi
if [ "$rc" -ne 1 ]; then
  printf 'ERROR: diff failed (exit %s)\n' "$rc" >&2
  exit 2
fi

printf '%s\n' "$diff_body" \
  | sed -e 's|^--- orig/|--- a/|' -e 's|^+++ new/|+++ b/|' > "$out"

printf 'Wrote %s\n' "$out"
