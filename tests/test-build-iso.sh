#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Every path build-iso.sh uses comes from the local settings, so the test asks
# for the same values instead of hard-coding a machine's paths.
source scripts/local-env.sh

if [ -z "$SUPERMOX_SPACED_WORKTREE" ]; then
  echo "FAIL: SUPERMOX_SPACED_WORKTREE is empty (local-env.sh must default it)"
  exit 1
fi

target="scripts/build-iso.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run)"

missing=0
for pat in \
  'worktree add --detach' \
  "$SUPERMOX_SPACED_WORKTREE" \
  'config/packages.chroot/' \
  'config/archives/proxmox.list.chroot' \
  'config/archives/proxmox.key.chroot' \
  'config/archives/supermox.pref.chroot' \
  'config/archives/supermox-no-systemd.pref.chroot' \
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
if ! printf '%s\n' "$out" | grep -qE '^DRY-RUN: sudo bash .*iso-pre-clean\.sh && cd .*lb build$'; then
  echo "FAIL: --dry-run must print, not run, the lb build command"
  missing=1
fi

# Debug packages and mk-build-deps helpers must never reach the ISO.
if printf '%s\n' "$out" | grep -qE -- '-(dbgsym|build-deps)_[^/]*\.deb$'; then
  echo "FAIL: --dry-run stages a -dbgsym or -build-deps package"
  missing=1
fi

# Newest version only: supermox-ve must be staged exactly once. Count the
# staging lines stage_debs prints for each package it keeps; the pre-clean
# prints `DRY-RUN: rm -f .../build/local-packages/supermox-ve_<ver>_all.deb` for
# the copy an earlier run left in the worktree, and that removal is not a stage.
ve_count="$(printf '%s\n' "$out" | grep -cE '^STEP:   supermox-ve_[^_]*_all\.deb$' || true)"
if [ "${ve_count:-0}" -gt 1 ]; then
  echo "FAIL: supermox-ve staged $ve_count times (only the newest version may go in)"
  missing=1
fi

# The check above only catches a double stage if an earlier build happened to
# leave a copy in the worktree. Reproduce that state instead of depending on it:
# a stale supermox-ve of another version, in a scratch worktree, must be pre-
# cleaned and must not make the package look staged twice, because live-build
# installs every deb in the pool.
scratch_wt="$PWD/build/test-iso-worktree"
rm -rf "$scratch_wt"
mkdir -p "$scratch_wt/.git" "$scratch_wt/build/local-packages"
: > "$scratch_wt/build/local-packages/supermox-ve_0.0.1_all.deb"
scratch_out="$(SUPERMOX_SPACED_WORKTREE="$scratch_wt" bash "$target" --dry-run)"
scratch_count="$(printf '%s\n' "$scratch_out" | grep -cE '^STEP:   supermox-ve_[^_]*_all\.deb$' || true)"
if [ "${scratch_count:-0}" -ne 1 ]; then
  echo "FAIL: supermox-ve staged $scratch_count times with a stale copy in the worktree (must be 1)"
  missing=1
fi
if ! printf '%s\n' "$scratch_out" | grep -qF -- \
  "DRY-RUN: rm -f $scratch_wt/build/local-packages/supermox-ve_0.0.1_all.deb"; then
  echo "FAIL: the stale supermox-ve_0.0.1_all.deb in the worktree is not pre-cleaned"
  missing=1
fi
if ! printf '%s\n' "$scratch_out" | grep -qF -- "STEP:   supermox-ve_"; then
  echo "FAIL: the newest supermox-ve is not staged over the stale copy in the worktree"
  missing=1
fi
rm -rf "$scratch_wt"

# The deb dir must be the documented SUPERMOX_DEBS_DIR (where vm-build-pkg.sh
# writes debs), never a hard-coded path: a fresh clone has no such directory and
# would either fail or stage stale debs into the ISO.
marker_dir="$PWD/build/test-iso-debs"
rm -rf "$marker_dir"
mkdir -p "$marker_dir"
: > "$marker_dir/supermox-ve_9.9.9_all.deb"
marker_out="$(SUPERMOX_DEBS_DIR="$marker_dir" bash "$target" --dry-run)"
if ! printf '%s\n' "$marker_out" | grep -qF -- "$marker_dir/supermox-ve_9.9.9_all.deb"; then
  echo "FAIL: --dry-run does not stage debs from SUPERMOX_DEBS_DIR"
  missing=1
fi
rm -rf "$marker_dir"

# ZERO systemd: the ISO must pin systemd away.
if ! printf '%s\n' "$out" | grep -qF -- 'systemd -1'; then
  echo "FAIL: --dry-run output missing the systemd -1 pin"
  missing=1
fi

# The ISO stages the pin before supermox-ve can be installed, so it must copy
# the conffile itself rather than keep its own list of names. live-build installs
# config/archives/<name>.pref.chroot as /etc/apt/preferences.d/<name>.pref for the
# chroot phase only and removes it before the binary stage, so the shipped ISO is
# left with exactly one copy of the pin: the package's conffile.
if ! grep -qF -- 'cp -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-no-systemd" "$lb_dir/config/archives/supermox-no-systemd.pref.chroot"' "$target"; then
  echo "FAIL: $target does not copy the supermox-ve pin conffile into config/archives"
  missing=1
fi
# The ISO's own pref stanza may only add names the package does not pin.
if grep -qE '^Package: .*(libsystemd0|libpam-systemd|systemd-standalone)' "$target"; then
  echo "FAIL: $target duplicates supermox-ve pin names in a stanza of its own"
  missing=1
fi

# The ISO must not ship a DHCP server or development packages: our forks build
# binaries SuperMox does not depend on, and live-build installs every deb stage_debs
# stages. config/iso-exclude-debs.txt is the deny list, matched by EXACT package
# name (a package whose name merely starts with a listed one must still go in).
exclude_file="config/iso-exclude-debs.txt"

# Against the real deb dir: none of the excluded packages may be staged.
for n in isc-dhcp-server isc-dhcp-server-ldap isc-dhcp-relay isc-dhcp-keama \
  isc-dhcp-dev isc-dhcp-client-ddns librrd-dev lua-rrd lua-rrd-dev rrdtool-tcl \
  python3-rrdtool ruby-rrd; do
  if printf '%s\n' "$out" | grep -qE -- "(STEP:   |DRY-RUN: cp [^ ]*/)${n}_[0-9]"; then
    echo "FAIL: build-iso.sh --dry-run stages $n, which $exclude_file excludes"
    missing=1
  fi
done

if [ ! -f "$exclude_file" ]; then
  echo "FAIL: $exclude_file does not exist"
  missing=1
  listed=""
else
  listed="$(awk '{ sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if (length($0) > 0) print }' "$exclude_file")"
fi

# The packages the forks added that SuperMox does not need must be listed.
for n in isc-dhcp-server isc-dhcp-server-ldap isc-dhcp-relay isc-dhcp-keama \
  isc-dhcp-dev isc-dhcp-client-ddns librrd-dev rrdtool-tcl lua-rrd python3-rrdtool; do
  if ! printf '%s\n' "$listed" | grep -qxF -- "$n"; then
    echo "FAIL: $exclude_file does not list $n"
    missing=1
  fi
done
# The packages SuperMox needs must NOT be listed (pve-cluster depends on librrds-perl
# and rrdcached; supermox-ve depends on isc-dhcp-client; PVE's graphs use rrdtool).
for n in isc-dhcp-client isc-dhcp-common rrdcached librrd8t64 librrds-perl librrdp-perl rrdtool; do
  if printf '%s\n' "$listed" | grep -qxF -- "$n"; then
    echo "FAIL: $exclude_file lists $n, which SuperMox needs in the ISO"
    missing=1
  fi
done

# Tiny real debs (dpkg-deb --build from a minimal DEBIAN/control) prove the
# staging behaviour itself, not just the list contents.
fake_dir="$PWD/build/test-iso-exclude-debs"
fake_src="$PWD/build/test-iso-fake-pkg"
rm -rf "$fake_dir" "$fake_src"
mkdir -p "$fake_dir"

mk_fake_deb() {
  local name="$1" ver="1.0.0-fake1"
  rm -rf "$fake_src"
  mkdir -p "$fake_src/DEBIAN"
  {
    printf 'Package: %s\n' "$name"
    printf 'Version: %s\n' "$ver"
    printf 'Architecture: all\n'
    printf 'Maintainer: SuperMox test <noreply@supermox.me>\n'
    printf 'Description: fake package for the ISO staging test\n'
  } > "$fake_src/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$fake_src" "$fake_dir/${name}_${ver}_all.deb" >/dev/null
}

fake_pkgs=(
  isc-dhcp-server isc-dhcp-server-ldap isc-dhcp-relay isc-dhcp-keama
  isc-dhcp-dev isc-dhcp-client-ddns isc-dhcp-server-extra
  librrd-dev rrdtool-tcl lua-rrd python3-rrdtool
  isc-dhcp-client isc-dhcp-common rrdcached librrd8t64 librrds-perl
  librrdp-perl rrdtool
)
# Also cover the first entry of the list generically, so the rule holds for
# whatever is listed, not only for the dhcp/rrd names spelled out above.
first_listed="$(printf '%s\n' "$listed" | head -1)"
if [ -n "$first_listed" ]; then
  fake_pkgs+=("$first_listed" "${first_listed}-extra")
fi
for n in "${fake_pkgs[@]}"; do
  mk_fake_deb "$n"
done

fake_out="$(SUPERMOX_DEBS_DIR="$fake_dir" bash "$target" --dry-run)"
for n in "${fake_pkgs[@]}"; do
  deb_line="${n}_1.0.0-fake1_all.deb"
  staged=no
  if printf '%s\n' "$fake_out" | grep -qxF -- "STEP:   $deb_line"; then staged=yes; fi
  skipped=no
  if printf '%s\n' "$fake_out" | grep -qF -- "SKIP: $deb_line ("; then skipped=yes; fi
  if printf '%s\n' "$listed" | grep -qxF -- "$n"; then
    if [ "$skipped" = no ] || [ "$staged" = yes ]; then
      echo "FAIL: $n is listed in $exclude_file but --dry-run did not skip it"
      missing=1
    fi
  else
    if [ "$staged" = no ] || [ "$skipped" = yes ]; then
      echo "FAIL: $n is not listed in $exclude_file but --dry-run did not stage it"
      missing=1
    fi
  fi
done

# The dry-run must say WHY a package was skipped: the reason from the list.
if [ -n "$first_listed" ]; then
  reason="$(awk -v pkg="$first_listed" '{ l = $0; sub(/[[:space:]]*#.*/, "", l); if (l == pkg) { r = $0; sub(/^[^#]*#[[:space:]]*/, "", r); print r } }' "$exclude_file")"
  skip_line="$(printf '%s\n' "$fake_out" | grep -F -- "SKIP: ${first_listed}_1.0.0-fake1_all.deb" | head -1)"
  if [ -z "$skip_line" ] || ! printf '%s\n' "$skip_line" | grep -qF -- "$reason"; then
    echo "FAIL: the --dry-run skip line for $first_listed does not state its reason from $exclude_file"
    missing=1
  fi
fi
rm -rf "$fake_dir" "$fake_src"

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: build-iso.sh --dry-run prints the worktree, packages.chroot staging, the archive and pin files, the ISO name and the 2 GiB limit"
echo "OK: build-iso.sh skips every config/iso-exclude-debs.txt package by exact name (prefix lookalikes still staged) and prints the reason"
