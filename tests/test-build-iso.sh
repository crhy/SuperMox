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
  'config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units' \
  'config/hooks/normal/9990-supermox-no-systemd-units.hook.chroot' \
  'supermox-11.26-pc-amd64.iso' \
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

# The SuperMox release line comes from config/release, not from the Spaced base.
# When the Spaced base line differs from config/release, build-iso.sh prints a
# NOTE (and never fails the build); when they match, no NOTE is printed.
smx_release="$(head -n1 config/release | tr -d '[:space:]')"
[ -n "$smx_release" ] || { echo "FAIL: config/release is empty"; missing=1; }
spaced_line="$(git -C "$SUPERMOX_SPACED_REPO" show "${SUPERMOX_SPACED_REF:-main}:VERSION" 2>/dev/null | head -n1)"
spaced_line="${spaced_line%.*}"
if [ "$spaced_line" != "$smx_release" ]; then
  if ! printf '%s\n' "$out" | grep -qF -- "NOTE: Spaced base line $spaced_line differs from SuperMox release $smx_release"; then
    echo "FAIL: base line $spaced_line != release $smx_release but no NOTE printed"
    missing=1
  fi
elif printf '%s\n' "$out" | grep -qF -- 'NOTE: Spaced base line'; then
  echo "FAIL: base line matches release $smx_release but a NOTE was printed"
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
# ZERO systemd unit files: the ISO must stage the supermox-ve dpkg path-exclude
# conffile before any package installs (live-build copies includes.chroot_before_packages
# into the chroot ahead of the package stages), and must write the hook that removes
# the unit files the debootstrap stage left under lib/systemd, usr/lib/systemd, etc/systemd.
if ! grep -qF -- 'cp -f "$repo_root/packaging/supermox-ve/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units" "$lb_dir/config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units"' "$target"; then
  echo "FAIL: $target does not stage the supermox-ve dpkg path-exclude conffile into includes.chroot_before_packages"
  missing=1
fi
if ! grep -qF -- 'cat > "$lb_dir/config/hooks/normal/9990-supermox-no-systemd-units.hook.chroot"' "$target"; then
  echo "FAIL: $target does not write the 9990-supermox-no-systemd-units hook"
  missing=1
fi
# The ISO's own pref stanza may only add names the package does not pin.
if grep -qE '^Package: .*(libsystemd0|libpam-systemd|systemd-standalone)' "$target"; then
  echo "FAIL: $target duplicates supermox-ve pin names in a stanza of its own"
  missing=1
fi

# The ISO install must not fail on the libpve-network-perl/libpve-access-control
# version skew. The hold lives in the supermox-origins conffile, which the ISO
# copies into config/archives before supermox-ve can be installed, so assert both
# halves: the ISO copies that conffile, and the conffile it copies holds libpve-network-*
# at 1.6.7.
if ! grep -qF -- 'cp -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-origins" "$lb_dir/config/archives/supermox-origins.pref.chroot"' "$target"; then
  echo "FAIL: $target does not copy the supermox-origins conffile (with the libpve-network version hold) into config/archives"
  missing=1
fi
if ! grep -qE '^Pin: version 1\.6\.7\*\r?$' packaging/supermox-ve/etc/apt/preferences.d/supermox-origins; then
  echo "FAIL: the supermox-origins conffile the ISO copies has no libpve-network 1.6.7 version hold"
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

# --- GRUB branding: the ISO must say SuperMox, never Spaced Linux ----------
# The edit logic runs against a scratch live-build tree built from the lines
# measured in the real tree (build/spaced-iso/build/live-build), so a Spaced
# change to any of these four files fails the build instead of shipping the
# old name.
brand_script="scripts/iso-grub-branding.sh"
if [ ! -f "$brand_script" ]; then
  echo "FAIL: $brand_script does not exist"
  missing=1
fi

grub_test="$PWD/build/test-grub-branding"
rm -rf "$grub_test"

write_fixture() {
  local root="$1" d
  for d in config/bootloaders/grub-pc/live-theme config/includes.chroot/etc/default config/includes.chroot/etc/calamares/branding/spaced config/includes.chroot/boot/grub/themes/spaced; do
    mkdir -p "$root/$d"
  done
  cat > "$root/config/bootloaders/grub-pc/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=8

source /boot/grub/config.cfg

menuentry "Start Spaced Linux 10.26.8" --hotkey=s {
    linux @KERNEL_LIVE@ @APPEND_LIVE@
    initrd @INITRD_LIVE@
}

menuentry "Spaced Linux 10.26.8 — Safe Graphics Because Nvidia Sucks" {
    linux @KERNEL_LIVE@ boot=live components nosplash nomodeset module_blacklist=nouveau modprobe.blacklist=nouveau nouveau.modeset=0 nvidia-drm.modeset=0 username=user hostname=spaced
    initrd @INITRD_LIVE@
}

menuentry "Start Spaced Linux 10.26.8 (verbose boot)" {
    linux @KERNEL_LIVE@ boot=live components noplymouth console=tty0 noquiet loglevel=7 username=user hostname=spaced
    initrd @INITRD_LIVE@
}

submenu "Spaced Linux utilities" --hotkey=u {
    source /boot/grub/theme.cfg

    if [ "${grub_platform}" = "efi" ]; then
        menuentry "UEFI Firmware Settings" --hotkey=f {
            fwsetup
        }
    fi

    if @ENABLE_VERIFY_CHECKSUMS@; then
        menuentry "Verify the Spaced Linux boot medium" --hotkey=v {
            linux @KERNEL_LIVE@ @APPEND_VERIFY_CHECKSUMS@
            initrd @INITRD_LIVE@
        }
    fi
}
GRUBCFG
  cat > "$root/config/bootloaders/grub-pc/live-theme/theme.txt" <<'THEMTXT'
desktop-image: "splash.png"
desktop-color: "#14151a"
title-color: "#d8d8d8"
title-font: "Unifont Regular 16"
title-text: "Spaced Linux 10.26.8"
message-font: "Unifont Regular 16"
terminal-font: "Unifont Regular 16"
THEMTXT
  cat > "$root/config/includes.chroot/etc/default/grub" <<'DEFGROU'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Spaced Linux"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=false
GRUB_GFXMODE=1920x1080
GRUB_THEME="/boot/grub/themes/spaced/theme.txt"
DEFGROU
  cat > "$root/config/includes.chroot/boot/grub/themes/spaced/theme.txt" <<'BOOTTHEME'
desktop-image: "SimpleBackb.png"
desktop-image-scale-method: "stretch"
desktop-color: "#14151a"
title-color: "#cfd3d8"
title-font: "Unifont Regular 18"
title-text: "Spaced Linux"
message-font: "Unifont Regular 16"
terminal-font: "Unifont Regular 16"

+ image {
    id = "spaced-logo"
    file = "spaced-icon-fancy.png"
}
BOOTTHEME
  cat > "$root/config/includes.chroot/etc/calamares/branding/spaced/branding.desc" <<'BRANDDESC'
---
componentName: spaced

strings:
    productName:         Spaced Linux
    shortProductName:    Spaced Linux
    version:             10.26.8
    versionedName:       Spaced Linux 10.26.8
    bootloaderEntryName: Spaced Linux
    productUrl:          https://github.com/crhy/spaced
BRANDDESC
  printf 'splash.png placeholder for the fixture\n' > "$root/config/bootloaders/grub-pc/live-theme/splash.png"
  printf 'bootloader splash.png placeholder\n' > "$root/config/bootloaders/grub-pc/splash.png"
  printf 'SimpleBackb.png placeholder\n' > "$root/config/includes.chroot/boot/grub/themes/spaced/SimpleBackb.png"
  printf 'spaced-icon-fancy.png placeholder\n' > "$root/config/includes.chroot/boot/grub/themes/spaced/spaced-icon-fancy.png"
}

# The SuperMox splash art build-iso.sh renders with scripts/branding-assets.sh;
# the test supplies a stand-in file so the copy is checked without rsvg/magick.
bg_png="$grub_test/build/branding/grub-background-1920x1080.png"
logo_png="$grub_test/build/branding/logo-512.png"
mkdir -p "$grub_test/build/branding"
printf 'SuperMox GRUB background stand-in\n' > "$bg_png"
printf 'SuperMox GRUB logo stand-in\n' > "$logo_png"

wt_lb="$grub_test/worktree"
write_fixture "$wt_lb"
if ! out_lb="$(bash "$brand_script" "$wt_lb" 11.26 10.26.8 "$bg_png" "$logo_png" 2>&1)"; then
  echo "FAIL: $brand_script failed on the scratch live-build tree:"
  printf '%s\n' "$out_lb"
  missing=1
fi
# Menu titles must read SuperMox <release> PC, and nothing may say Spaced Linux.
for pat in 'menuentry "Start SuperMox 11.26 PC" --hotkey=s {' \
  'menuentry "SuperMox 11.26 PC — Safe Graphics Because Nvidia Sucks" {' \
  'menuentry "Start SuperMox 11.26 PC (verbose boot)" {' \
  'submenu "SuperMox utilities" --hotkey=u {' \
  'menuentry "Verify the SuperMox boot medium" --hotkey=v {'; do
  if ! grep -qF -- "$pat" "$wt_lb/config/bootloaders/grub-pc/grub.cfg"; then
    echo "FAIL: the live GRUB menu is missing: $pat"
    missing=1
  fi
done
for f in config/bootloaders/grub-pc/grub.cfg \
  config/bootloaders/grub-pc/live-theme/theme.txt \
  config/includes.chroot/boot/grub/themes/spaced/theme.txt \
  config/includes.chroot/etc/default/grub \
  config/includes.chroot/etc/calamares/branding/spaced/branding.desc; do
  if grep -q "Spaced Linux" "$wt_lb/$f"; then
    echo "FAIL: $wt_lb/$f still says Spaced Linux"
    missing=1
  fi
done

# Kernel command lines must be untouched: the linux/initrd lines of the edited
# file must equal those of an untouched copy of the same fixture.
write_fixture "$grub_test/pristine"
for f in config/bootloaders/grub-pc/grub.cfg config/includes.chroot/etc/default/grub; do
  if ! diff -q <(grep -E '^[[:space:]]*(linux|initrd|GRUB_CMDLINE_LINUX)' "$grub_test/pristine/$f") \
    <(grep -E '^[[:space:]]*(linux|initrd|GRUB_CMDLINE_LINUX)' "$wt_lb/$f") > /dev/null; then
    echo "FAIL: $brand_script changed a kernel command line in $f"
    missing=1
  fi
done
if ! grep -qF -- 'hostname=spaced' "$wt_lb/config/bootloaders/grub-pc/grub.cfg"; then
  echo "FAIL: the kernel command line hostname=spaced was altered"
  missing=1
fi

# Theme: SuperMox title, the SuperMox art installed as splash.png, and a title
# colour that still reads on the #092b32 background.
theme="$wt_lb/config/bootloaders/grub-pc/live-theme"
for pat in 'title-text: "SuperMox 11.26 PC"' 'desktop-image: "splash.png"' \
  'title-color: "#d8d8d8"' 'desktop-color: "#092b32"'; do
  if ! grep -qF -- "$pat" "$theme/theme.txt"; then
    echo "FAIL: the live GRUB theme is missing: $pat"
    missing=1
  fi
done
if ! cmp -s "$bg_png" "$theme/splash.png"; then
  echo "FAIL: live-theme/splash.png is not the SuperMox GRUB background"
  missing=1
fi
if ! cmp -s "$bg_png" "$wt_lb/config/bootloaders/grub-pc/splash.png"; then
  echo "FAIL: the grub-pc bootloader splash.png is not the SuperMox GRUB background"
  missing=1
fi

# The installed system's GRUB menu theme (/boot/grub/themes/spaced/theme.txt,
# which GRUB_THEME points at): SuperMox title, SuperMox background and logo.
boot_theme="$wt_lb/config/includes.chroot/boot/grub/themes/spaced"
for pat in 'title-text: "SuperMox"' 'desktop-image: "SimpleBackb.png"' \
  'title-color: "#cfd3d8"' 'desktop-color: "#092b32"'; do
  if ! grep -qF -- "$pat" "$boot_theme/theme.txt"; then
    echo "FAIL: the installed GRUB menu theme is missing: $pat"
    missing=1
  fi
done
if ! cmp -s "$bg_png" "$boot_theme/SimpleBackb.png"; then
  echo "FAIL: the installed GRUB theme background is not the SuperMox GRUB background"
  missing=1
fi
if ! cmp -s "$logo_png" "$boot_theme/spaced-icon-fancy.png"; then
  echo "FAIL: the installed GRUB theme logo is not the SuperMox logo"
  missing=1
fi

# Installed system: the GRUB menu name and the EFI boot entry name.
if ! grep -qF -- 'GRUB_DISTRIBUTOR="SuperMox"' "$wt_lb/config/includes.chroot/etc/default/grub"; then
  echo "FAIL: etc/default/grub does not set GRUB_DISTRIBUTOR=SuperMox"
  missing=1
fi
if ! grep -qF -- 'GRUB_THEME="/boot/grub/themes/spaced/theme.txt"' "$wt_lb/config/includes.chroot/etc/default/grub"; then
  echo "FAIL: etc/default/grub no longer points at the theme live-build installs"
  missing=1
fi
bd="$wt_lb/config/includes.chroot/etc/calamares/branding/spaced/branding.desc"
for pat in 'bootloaderEntryName: SuperMox' 'versionedName:       SuperMox 11.26 PC' 'productName:         SuperMox'; do
  if ! grep -qF -- "$pat" "$bd"; then
    echo "FAIL: the calamares branding is missing: $pat"
    missing=1
  fi
done

# A Spaced change must FAIL the script, not silently leave the old name: a
# version that is not in the files, and a missing file, both have to exit non-zero
# with a message.
bad_v="$grub_test/bad-version"
write_fixture "$bad_v"
if out_bad="$(bash "$brand_script" "$bad_v" 11.26 9.9.9 "$bg_png" "$logo_png" 2>&1)"; then
  echo "FAIL: $brand_script accepted a live-build tree with no 'Spaced Linux 9.9.9'"
  missing=1
else
  if ! printf '%s\n' "$out_bad" | grep -qF -- 'Spaced Linux 9.9.9'; then
    echo "FAIL: the missing-string failure does not name the string it wanted"
    missing=1
  fi
fi
bad_f="$grub_test/missing-file"
write_fixture "$bad_f"
rm -f "$bad_f/config/bootloaders/grub-pc/grub.cfg"
if bash "$brand_script" "$bad_f" 11.26 10.26.8 "$bg_png" "$logo_png" > /dev/null 2>&1; then
  echo "FAIL: $brand_script accepted a live-build tree with no grub.cfg"
  missing=1
fi
bad_bg="$grub_test/missing-bg"
write_fixture "$bad_bg"
if bash "$brand_script" "$bad_bg" 11.26 10.26.8 "$grub_test/nope.png" > /dev/null 2>&1; then
  echo "FAIL: $brand_script accepted a missing GRUB background"
  missing=1
fi
bad_logo="$grub_test/missing-logo"
write_fixture "$bad_logo"
if bash "$brand_script" "$bad_logo" 11.26 10.26.8 "$bg_png" "$grub_test/nope.png" > /dev/null 2>&1; then
  echo "FAIL: $brand_script accepted a missing GRUB logo"
  missing=1
fi
# A title colour too dark to read on the #092b32 art must FAIL the script.
dark="$grub_test/dark-title"
write_fixture "$dark"
sed -i 's/title-color: "#d8d8d8"/title-color: "#0b0b0b"/' "$dark/config/bootloaders/grub-pc/live-theme/theme.txt"
if out_dark="$(bash "$brand_script" "$dark" 11.26 10.26.8 "$bg_png" "$logo_png" 2>&1)"; then
  echo "FAIL: $brand_script accepted a theme whose title colour is unreadable on #092b32"
  missing=1
else
  if ! printf '%s\n' "$out_dark" | grep -qF -- 'not readable on the #092b32 background'; then
    echo "FAIL: the readability failure does not say why"
    missing=1
  fi
fi

# build-iso.sh must run the branding edit after make prepare, and make sure the
# art exists (scripts/branding-assets.sh renders it).
if ! grep -qF -- 'bash "$repo_root/scripts/iso-grub-branding.sh" "$lb_dir" "$release" "$spaced_version" "$grub_bg" "$grub_logo"' "$target"; then
  echo "FAIL: $target does not run scripts/iso-grub-branding.sh in the post-prepare config"
  missing=1
fi
if ! grep -qF -- 'run bash "$repo_root/scripts/branding-assets.sh"' "$target"; then
  echo "FAIL: $target does not render the GRUB background with scripts/branding-assets.sh when it is missing"
  missing=1
fi
if ! grep -qF -- 'grub_bg="$repo_root/build/branding/grub-background-1920x1080.png"' "$target"; then
  echo "FAIL: $target does not name build/branding/grub-background-1920x1080.png as the GRUB background"
  missing=1
fi
if ! grep -qF -- 'grub_logo="$repo_root/build/branding/logo-512.png"' "$target"; then
  echo "FAIL: $target does not name build/branding/logo-512.png as the GRUB logo"
  missing=1
fi
rm -rf "$grub_test"

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: build-iso.sh --dry-run prints the worktree, packages.chroot staging, the archive and pin files, the ISO name and the 2 GiB limit"
echo "OK: build-iso.sh skips every config/iso-exclude-debs.txt package by exact name (prefix lookalikes still staged) and prints the reason"
echo "OK: iso-grub-branding.sh renames the live GRUB menu, the live theme, the installed GRUB menu theme, etc/default/grub and the calamares boot entry to SuperMox (SuperMox art in every GRUB theme), leaves kernel command lines alone, and fails when a Spaced string, an asset or a readable title colour is missing"
