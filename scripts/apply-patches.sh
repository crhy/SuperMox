#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_PACKAGES="${UPSTREAM_PACKAGES:-$repo_root/upstream/pxvirt/packages}"
PATCHES_DIR="${PATCHES_DIR:-$repo_root/patches}"

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <outdir>\n' "${0##*/}" >&2
  exit 2
fi
outdir="$1"

components=()
while IFS= read -r c; do
  [ -n "$c" ] || continue
  components+=("$c")
done < <(bash "$repo_root/scripts/fetch-upstream.sh" --list)

if [ "${#components[@]}" -eq 0 ]; then
  printf 'ERROR: fetch-upstream.sh --list returned no components\n' >&2
  exit 1
fi

for c in "${components[@]}"; do
  src="$UPSTREAM_PACKAGES/$c/$c"
  [ -d "$src" ] || continue
  dest="$outdir/$c/$c"
  mkdir -p "$dest"
  rsync -a --delete --exclude .git "$src/" "$dest/"
  pdir="$PATCHES_DIR/$c"
  if [ -d "$pdir" ]; then
    while IFS= read -r -d '' p; do
      if ! ( cd "$dest" && patch -p1 --forward --batch < "$p" >/dev/null ); then
        printf 'ERROR: patch failed: %s\n' "$p" >&2
        exit 1
      fi
    done < <(find "$pdir" -maxdepth 1 -type f -name '*.patch' -print0 | LC_ALL=C sort -z)
  fi
done

printf 'Applied patches to %s (%s components)\n' "$outdir" "${#components[@]}"
