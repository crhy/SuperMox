#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_PACKAGES="${UPSTREAM_PACKAGES:-$repo_root/upstream/pxvirt/packages}"
UPSTREAM_DEBIAN_SRC="${UPSTREAM_DEBIAN_SRC:-$repo_root/upstream/debian-src}"
PATCHES_DIR="${PATCHES_DIR:-$repo_root/patches}"
INIT_SCRIPTS="${INIT_SCRIPTS:-$repo_root/config/init-scripts.txt}"

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <outdir>\n' "${0##*/}" >&2
  exit 2
fi
outdir="$1"

# Scratch for the changelog step below; build/ is the repo's scratch dir.
mkdir -p "$repo_root/build"
CL_TMP="$repo_root/build/apply-patches.changelog.tmp"

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
  # fetch-upstream.sh --src-dir knows both layouts: pxvirt submodules and
  # forked Debian source packages (upstream/debian-src/<name>/<name>).
  src="$(UPSTREAM_PACKAGES="$UPSTREAM_PACKAGES" UPSTREAM_DEBIAN_SRC="$UPSTREAM_DEBIAN_SRC" \
    bash "$repo_root/scripts/fetch-upstream.sh" --src-dir "$c")" || src=""
  [ -d "$src" ] || continue
  dest="$outdir/$c/$c"
  mkdir -p "$dest"
  rsync -a --delete --exclude .git "$src/" "$dest/"
  pdir="$PATCHES_DIR/$c"
  if [ -d "$pdir" ]; then
    while IFS= read -r -d '' p; do
      # --no-backup-if-mismatch keeps patch's .orig backups out of the source tree: a stray
      # debian/control.orig or Makefile.orig would ship inside the built package.
      if ! out="$( cd "$dest" && patch -p1 --forward --batch --no-backup-if-mismatch < "$p" 2>&1 )"; then
        printf 'ERROR: patch failed: %s\n' "$p" >&2
        printf '%s\n' "$out" >&2
        exit 1
      fi
      # A hunk that lands with fuzz or an offset means the patch no longer matches
      # the pinned upstream exactly: it can silently attach to the wrong context.
      # This is fatal: every patch must apply with zero fuzz/offset.
      if printf '%s\n' "$out" | grep -qE 'fuzz|offset'; then
        printf 'ERROR: %s applies to %s with fuzz/offset (rebase against the pinned upstream):\n' "${p##*/}" "$c" >&2
        printf '%s\n' "$out" | grep -E 'fuzz|offset' | sed 's/^/  /' >&2
        exit 1
      fi
    done < <(find "$pdir" -maxdepth 1 -type f -name '*.patch' -print0 | LC_ALL=C sort -z)
  fi
  # Version suffix (GitHub crhy/SuperMox#10): a SuperMox build of an upstream
  # component must carry a version Proxmox's repository can never produce, so
  # the apt pin supermox-ve ships can demote download.proxmox.com for our
  # package names and `apt upgrade` can never swap our sysvinit build for their
  # systemd one. One generic step, run after the patches so it never shifts a
  # patch's context: prepend one changelog entry to every debian/changelog in
  # the tree (proxmox-perl-rs ships three: common/pkg, pmg-rs, pve-rs).
  # Idempotent: a version that already ends in +supermoxN (the forked Debian
  # sources rrdtool and isc-dhcp get theirs from their own patch set) is left
  # alone, and the rsync --delete above restores the pristine changelog on every
  # run, so re-running never stacks entries.
  while IFS= read -r -d '' cl; do
    if ! ver="$(dpkg-parsechangelog -l "$cl" -S Version 2>/dev/null)"; then
      printf 'ERROR: dpkg-parsechangelog cannot read %s\n' "$cl" >&2
      exit 1
    fi
    if printf '%s\n' "$ver" | grep -qE '\+supermox[0-9]+$'; then
      continue
    fi
    if ! src_name="$(dpkg-parsechangelog -l "$cl" -S Source 2>/dev/null)" || \
       ! dist="$(dpkg-parsechangelog -l "$cl" -S Distribution 2>/dev/null)"; then
      printf 'ERROR: dpkg-parsechangelog cannot read Source/Distribution of %s\n' "$cl" >&2
      exit 1
    fi
    printf '%s (%s+supermox1) %s; urgency=medium\n\n  Rebuilt for SuperMox: sysvinit, no systemd.\n\n -- SuperMox <noreply@supermox.me>  %s\n\n' \
      "$src_name" "$ver" "$dist" "$(date -R)" > "$CL_TMP"
    # Two temps, not one: `> "$cl"` would truncate the changelog before cat
    # reads it, and `mv` would reset the file mode. cat into the original.
    cat "$CL_TMP" "$cl" > "$CL_TMP.all"
    cat "$CL_TMP.all" > "$cl"
  done < <(find "$dest" -name .git -prune -o -type f -path '*/debian/changelog' -print0 | LC_ALL=C sort -z)
  rm -f "$CL_TMP" "$CL_TMP.all"
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
