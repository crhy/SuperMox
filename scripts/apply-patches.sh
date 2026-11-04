#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_PACKAGES="${UPSTREAM_PACKAGES:-$repo_root/upstream/pxvirt/packages}"
PATCHES_DIR="${PATCHES_DIR:-$repo_root/patches}"
INIT_SCRIPTS="${INIT_SCRIPTS:-$repo_root/config/init-scripts.txt}"

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
      # --backup-dir keeps patch's .orig backups out of the source tree: a stray
      # debian/control.orig or Makefile.orig would ship inside the built package.
      if ! out="$( cd "$dest" && patch -p1 --forward --batch --no-backup-if-mismatch < "$p" 2>&1 )"; then
        printf 'ERROR: patch failed: %s\n' "$p" >&2
        printf '%s\n' "$out" >&2
        exit 1
      fi
      # A hunk that lands with fuzz or an offset means the patch no longer matches
      # the pinned upstream exactly: it can silently attach to the wrong context.
      if printf '%s\n' "$out" | grep -qE 'fuzz|offset'; then
        printf 'WARN: %s applies to %s with fuzz/offset (rebase against the pinned upstream):\n' "${p##*/}" "$c" >&2
        printf '%s\n' "$out" | grep -E 'fuzz|offset' | sed 's/^/  /' >&2
      fi
    done < <(find "$pdir" -maxdepth 1 -type f -name '*.patch' -print0 | LC_ALL=C sort -z)
  fi
  # init.d/<svc> is the single source of truth; copy it into debian/ so the
  # packaging patches no longer embed copies.
  if [ -f "$INIT_SCRIPTS" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      read -r comp pkg svc <<< "$line"
      [ "$comp" = "$c" ] || continue
      [ -f "$repo_root/init.d/$svc" ] || continue
      mkdir -p "$dest/debian"
      install -m 0755 "$repo_root/init.d/$svc" "$dest/debian/$pkg.$svc.init"
    done < "$INIT_SCRIPTS"
  fi
done

printf 'Applied patches to %s (%s components)\n' "$outdir" "${#components[@]}"
