#!/usr/bin/env bash
set -euo pipefail

PXVIRT_URL=https://github.com/jiangcuo/pxvirt
PXVIRT_COMMIT=57302a2060f34e158b81c471ea68e9ee02ef5d5a
COMPONENTS=(
  pve-manager
  pve-cluster
  pve-common
  qemu-server
  pve-container
  pve-storage
  pve-access-control
  pve-ha-manager
  pve-firewall
  pve-http-server
  pve-guest-common
  proxmox-ve
  proxmox-perl-rs
  librados2-perl
)

# Debian source packages we fork. Here the .dsc is the source of truth, not
# upstream git: the changes we need are to Debian's own packaging of the
# component (its systemd-only service install), so we fork the Debian source
# package and keep Debian's version so Debian's dependency resolution still
# works. Fetched over HTTPS from the Debian pool and verified against a pinned
# sha256 of the .dsc before dpkg-source unpacks it.
#   <name> <version> <sha256 of the .dsc>
DEBIAN_SRC=(
  "rrdtool 1.9.0-2.1 4953392378c0377a5b99fd08b217e0a7ae00c3abc8b092b6ae161c798640357e"
  "isc-dhcp 4.4.3-P1-8 8f11305d0d978e60114f596615b2cd605004802bb42587a95bf0806211880723"
)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo_root/upstream/pxvirt"
overrides_file="$repo_root/config/upstream-overrides.txt"
UPSTREAM_PACKAGES="${UPSTREAM_PACKAGES:-$repo_root/upstream/pxvirt/packages}"
# Where the forked Debian source packages live. Override for tests.
UPSTREAM_DEBIAN_SRC="${UPSTREAM_DEBIAN_SRC:-$repo_root/upstream/debian-src}"

declare -a ov_component ov_url ov_commit

parse_overrides() {
  [ -f "$overrides_file" ] || return 0
  local line before reason comp url commit extra lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    before="${line%%#*}"
    if [ "$before" = "$line" ]; then
      printf 'ERROR: override line %d has no "# reason": %s\n' "$lineno" "$line" >&2
      exit 2
    fi
    reason="${line#*#}"
    reason="${reason#"${reason%%[![:space:]]*}"}"
    if [ -z "$reason" ]; then
      printf 'ERROR: override line %d has empty reason: %s\n' "$lineno" "$line" >&2
      exit 2
    fi
    read -r comp url commit extra <<< "$before"
    if [ -z "$comp" ] || [ -z "$url" ] || [ -z "$commit" ] || [ -n "${extra:-}" ]; then
      printf 'ERROR: override line %d malformed (expected "<component> <git-url> <commit>  # <reason>"): %s\n' "$lineno" "$line" >&2
      exit 2
    fi
    ov_component+=("$comp")
    ov_url+=("$url")
    ov_commit+=("$commit")
  done < "$overrides_file"
}

# Name of a forked Debian source package, if the component is one.
debian_src_name() {
  local c="$1" e name
  for e in "${DEBIAN_SRC[@]}"; do
    read -r name _ver _sha <<< "$e"
    [ "$name" = "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Where a component's source tree lives once fetched. apply-patches.sh,
# patch-workspace.sh, patch-save.sh and vm-build-pkg.sh go through this
# instead of hardcoding the pxvirt packages layout.
src_dir() {
  local c="$1"
  if debian_src_name "$c" >/dev/null; then
    printf '%s/%s/%s\n' "$UPSTREAM_DEBIAN_SRC" "$c" "$c"
    return 0
  fi
  local x
  for x in "${COMPONENTS[@]}"; do
    [ "$x" = "$c" ] && { printf '%s/%s/%s\n' "$UPSTREAM_PACKAGES" "$c" "$c"; return 0; }
  done
  # Not in either pinned list: assume the pxvirt submodule layout, which is where
  # a component we have not pinned yet would live. Callers check the directory
  # exists; a resolver that only knows the pinned names cannot serve a workspace
  # for a component being forked for the first time.
  printf '%s/%s/%s\n' "$UPSTREAM_PACKAGES" "$c" "$c"
  return 0
}

if [ "${1:-}" = "--list" ]; then
  for c in "${COMPONENTS[@]}"; do
    printf '%s\n' "$c"
  done
  for e in "${DEBIAN_SRC[@]}"; do
    read -r c _ver _sha <<< "$e"
    printf '%s\n' "$c"
  done
  exit 0
fi

if [ "${1:-}" = "--list-debian-src" ]; then
  for e in "${DEBIAN_SRC[@]}"; do
    printf '%s\n' "$e"
  done
  exit 0
fi

if [ "${1:-}" = "--src-dir" ]; then
  if [ "$#" -lt 2 ]; then
    printf 'ERROR: --src-dir requires a component name\n' >&2
    exit 2
  fi
  src_dir "$2"
  exit $?
fi

if [ "${1:-}" = "--list-overrides" ]; then
  parse_overrides
  for i in "${!ov_component[@]}"; do
    printf '%s %s\n' "${ov_component[$i]}" "${ov_commit[$i]}"
  done
  exit 0
fi

if [ ! -d "$dest" ]; then
  git clone --branch pxvirt "$PXVIRT_URL" "$dest"
  git -C "$dest" checkout "$PXVIRT_COMMIT"
else
  head="$(git -C "$dest" rev-parse HEAD)"
  if [ "$head" != "$PXVIRT_COMMIT" ]; then
    echo "ERROR: $dest HEAD is $head, expected $PXVIRT_COMMIT" >&2
    exit 1
  fi
fi

for c in "${COMPONENTS[@]}"; do
  git -C "$dest" submodule update --init --depth 1 "packages/$c/$c"
done

# Forked Debian source packages: download the pinned .dsc and the files it
# declares, verify every one against a sha256, then unpack with dpkg-source.
# The unpacked tree is what apply-patches.sh patches.
# Debian's pool path uses the first letter of the package name, except that
# "lib*" packages share pool/main/lib/.
pool_dir() {
  local name="$1"
  if [ "${name#lib}" != "$name" ]; then
    printf 'lib\n'
  else
    printf '%s\n' "${name:0:1}"
  fi
}

# deb_pool_get <dir> <pool-subpath> <file> <sha256>: fetch into <dir> unless
# it is already there and matching. Never trusts the download: the sha256 comes
# from the pinned .dsc (or from the pin for the .dsc itself).
deb_pool_get() {
  local dir="$1" pool="$2" file="$3" sha="$4"
  local url="http://deb.debian.org/debian/pool/$pool/$file"
  if [ -f "$dir/$file" ] && printf '%s  %s\n' "$sha" "$dir/$file" | sha256sum --check --status; then
    return 0
  fi
  printf 'Fetching %s\n' "$url"
  if ! curl -fsSL --retry 3 -o "$dir/$file.part" "$url"; then
    printf 'FAIL: download %s\n' "$url" >&2
    rm -f "$dir/$file.part"
    return 1
  fi
  if ! printf '%s  %s\n' "$sha" "$dir/$file.part" | sha256sum --check --status; then
    printf 'FAIL: sha256 mismatch for %s\n' "$file" >&2
    rm -f "$dir/$file.part"
    return 1
  fi
  mv "$dir/$file.part" "$dir/$file"
}

fetch_debian_src() {
  local name="$1" ver="$2" sha="$3"
  local dir="$UPSTREAM_DEBIAN_SRC/$name"
  local dsc="${name}_${ver}.dsc"
  local pool
  pool="main/$(pool_dir "$name")/$name"
  # Version-independent unpack dir, so patches/ and the build scripts never
  # have to be touched when the pin moves.
  local out="$dir/$name"

  mkdir -p "$dir"
  if ! deb_pool_get "$dir" "$pool" "$dsc" "$sha"; then
    return 1
  fi
  # The tarballs dpkg-source needs are declared by the .dsc itself, so their
  # sha256s come from the pinned file rather than being pinned a second time.
  local file sum
  while read -r sum file; do
    [ -n "$file" ] || continue
    if ! deb_pool_get "$dir" "$pool" "$file" "$sum"; then
      return 1
    fi
  done < <(awk '/^Checksums-Sha256:/{f=1; next}
    f && NF == 3 { print $1, $3 }
    f && NF != 3 { exit }' "$dir/$dsc")

  if [ -d "$out" ]; then
    printf 'OK: unpacked %s\n' "$out"
    return 0
  fi
  rm -rf "$out"
  # --skip-patches: our patches/ live against the pristine upstream files, and
  # Debian's own quilt patches stay in debian/patches/ to be applied by dpkg-buildpackage
  # at build time. Unpacking with them applied would make our patch hunks depend on them.
  # (--unapply-patches would NOT do this: it only controls the --after-build unapplication
  # and is a no-op for -x, leaving quilt patches applied with no .pc bookkeeping.)
  if ! dpkg-source -x --skip-patches "$dir/$dsc" "$out"; then
    printf 'FAIL: dpkg-source -x %s\n' "$dsc" >&2
    return 1
  fi
  printf 'OK: unpacked %s\n' "$out"
}

for e in "${DEBIAN_SRC[@]}"; do
  read -r c ver sha <<< "$e"
  fetch_debian_src "$c" "$ver" "$sha"
done

parse_overrides
for i in "${!ov_component[@]}"; do
  comp="${ov_component[$i]}"
  url="${ov_url[$i]}"
  commit="${ov_commit[$i]}"
  co="$dest/packages/$comp/$comp"
  head="$(git -C "$co" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    git -C "$co" fetch --depth 1 "$url" "$commit"
    git -C "$co" checkout "$commit"
  fi
done
