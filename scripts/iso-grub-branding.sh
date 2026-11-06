#!/usr/bin/env bash
# iso-grub-branding.sh - make the ISO's GRUB say SuperMox, not Spaced Linux.
#
# Run by build-iso.sh's post-prepare script (build/iso-post-prepare.sh) after
# 'make prepare' and before 'lb build': 'prepare' deletes and re-creates
# build/live-build/, so every branding edit has to happen after it. The Spaced
# Makefile and checkout are never edited.
#
# Four files are edited (paths relative to the live-build dir):
#   config/bootloaders/grub-pc/grub.cfg                        live ISO boot menu titles
#   config/bootloaders/grub-pc/live-theme/theme.txt            live menu theme (title + art)
#   config/includes.chroot/etc/default/grub                    the installed system's GRUB name
#   config/includes.chroot/etc/calamares/branding/spaced/branding.desc
#                                                        the installed EFI boot entry name
#   config/includes.chroot/boot/grub/themes/spaced/theme.txt    the INSTALLED system's GRUB
#                                                        menu title (GRUB_THEME points at it)
#
# Every replacement FAILS (exit 1) when its target string is missing, so a Spaced
# change can never silently leave the old name in the ISO. Kernel command lines
# (linux/initrd lines, hostname=spaced, ...) are never touched.
#
# usage: iso-grub-branding.sh <live-build-dir> <release> <spaced-version> [background-png]
#   release         e.g. 11.26  (the SuperMox release line, from config/release via build-iso.sh)
#   spaced-version  e.g. 10.26.8 (the Spaced VERSION file, from build-iso.sh)
#   background-png  GRUB splash art; default build/branding/grub-background-1920x1080.png
set -euo pipefail

repo_root="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

lb_dir="${1:-}"
release="${2:-}"
spaced_version="${3:-}"
bg_png="${4:-$repo_root/build/branding/grub-background-1920x1080.png}"
logo_png="${5:-$repo_root/build/branding/logo-512.png}"

if [ -z "$lb_dir" ] || [ -z "$release" ] || [ -z "$spaced_version" ]; then
  printf 'usage: %s <live-build-dir> <release> <spaced-version> [background-png [logo-png]]\n' "$0" >&2
  exit 2
fi

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

grub_cfg="$lb_dir/config/bootloaders/grub-pc/grub.cfg"
theme_txt="$lb_dir/config/bootloaders/grub-pc/live-theme/theme.txt"
boot_theme="$lb_dir/config/includes.chroot/boot/grub/themes/spaced/theme.txt"
default_grub="$lb_dir/config/includes.chroot/etc/default/grub"
branding_desc="$lb_dir/config/includes.chroot/etc/calamares/branding/spaced/branding.desc"

# Replace every occurrence of a FIXED string, failing when it is not there at all.
# awk's index/substr are byte-exact: no regex, so the em dash in the menu titles
# and the quotes in etc/default/grub need no escaping.
replace() {
  local f="$1" old="$2" new="$3" tmp
  [ -f "$f" ] || fail "missing file: $f"
  if ! grep -qF -- "$old" "$f"; then
    fail "$f: expected string not found: [$old] - Spaced changed this file; refusing to build an ISO that still says Spaced Linux"
  fi
  replace_all "$f" "$old" "$new"
}

# Same replacement, but a no-op when the string is already gone: used for the
# catch-all pass, whose job the final "no Spaced Linux left" grep does instead.
replace_if_present() { replace_all "$1" "$2" "$3"; }

replace_all() {
  local f="$1" old="$2" new="$3" tmp
  [ -f "$f" ] || fail "missing file: $f"
  tmp="$f.supermox-tmp"
  awk -v old="$old" -v new="$new" '{
    line = ""
    rest = $0
    while ((i = index(rest, old)) > 0) {
      line = line substr(rest, 1, i - 1) new
      rest = substr(rest, i + length(old))
    }
    print line rest
  }' "$f" > "$tmp" || { rm -f "$tmp"; fail "awk failed on $f"; }
  mv "$tmp" "$f"
}

# a) the live ISO boot menu: "Spaced Linux <ver>" -> "SuperMox <release> PC", then
#    the submenu and the checksum-verify entry. Kernel command lines are not
#    matched (they carry hostname=spaced, never "Spaced Linux").
replace "$grub_cfg" "Spaced Linux $spaced_version" "SuperMox $release PC"
replace_if_present "$grub_cfg" "Spaced Linux" "SuperMox"

# b) the live menu theme title (same versioned form).
replace "$theme_txt" "Spaced Linux $spaced_version" "SuperMox $release PC"
replace_if_present "$theme_txt" "Spaced Linux" "SuperMox"

# e) the INSTALLED system's GRUB menu title: /etc/default/grub points GRUB_THEME
#    at /boot/grub/themes/spaced/theme.txt, whose title-text is a bare "Spaced Linux"
#    (no version), so it needs its own exact edit.
replace "$boot_theme" 'title-text: "Spaced Linux"' 'title-text: "SuperMox"'
replace_if_present "$boot_theme" "Spaced Linux" "SuperMox"

# c) the installed system's GRUB menu name (update-grub puts it in the titles).
replace "$default_grub" 'GRUB_DISTRIBUTOR="Spaced Linux"' 'GRUB_DISTRIBUTOR="SuperMox"'
replace_if_present "$default_grub" "Spaced Linux" "SuperMox"

# d) the installed EFI boot entry name, plus the calamares product names. The
#    bootloaderEntryName edit runs before the catch-all so it stays a hard check.
replace "$branding_desc" "Spaced Linux $spaced_version" "SuperMox $release PC"
replace "$branding_desc" "bootloaderEntryName: Spaced Linux" "bootloaderEntryName: SuperMox"
replace_if_present "$branding_desc" "Spaced Linux" "SuperMox"

# Theme art: the SuperMox symbol centred on #092b32 (scripts/branding-assets.sh
# renders it from website/assets/supermox-symbol.svg). live-theme/ holds only
# theme.txt and splash.png, so the theme keeps referencing "splash.png"; the
# installed theme keeps referencing its own art names, SimpleBackb.png and
# spaced-icon-fancy.png (a square logo slot, so logo-512.png fits it).
[ -r "$bg_png" ] || fail "missing GRUB background: $bg_png (run scripts/branding-assets.sh)"
[ -r "$logo_png" ] || fail "missing GRUB logo: $logo_png (run scripts/branding-assets.sh)"
cp -f "$bg_png" "$lb_dir/config/bootloaders/grub-pc/live-theme/splash.png"
cp -f "$bg_png" "$lb_dir/config/bootloaders/grub-pc/splash.png"
cp -f "$bg_png" "$(dirname "$boot_theme")/SimpleBackb.png"
cp -f "$logo_png" "$(dirname "$boot_theme")/spaced-icon-fancy.png"

# The art is dark (#092b32): make each theme's desktop colour match it, and keep
# the light title colour readable on it (relative luminance, so both themes'
# own colours - #d8d8d8 and #cfd3d8 - are checked rather than hard-coded).
for t in "$theme_txt" "$boot_theme"; do
  replace "$t" 'desktop-color: "#14151a"' 'desktop-color: "#092b32"'
  title=$(grep -m1 -oE 'title-color:[[:space:]]*"#[0-9a-fA-F]{3,6}"' "$t" | grep -oE '#[0-9a-fA-F]{3,6}')
  desk=$(grep -m1 -oE 'desktop-color:[[:space:]]*"#[0-9a-fA-F]{3,6}"' "$t" | grep -oE '#[0-9a-fA-F]{3,6}')
  [ -n "$title" ] && [ -n "$desk" ] || fail "$t: no title-color/desktop-color hex to check readability against"
  lum_ok=$(awk -v t="$title" -v d="$desk" '
    function lum(c,   r, g, b, x) {
      sub(/#/, "", c)
      if (length(c) == 3) c = substr(c,1,1) substr(c,1,1) substr(c,2,1) substr(c,2,1) substr(c,3,1) substr(c,3,1)
      r = hexval(substr(c,1,2)); g = hexval(substr(c,3,2)); b = hexval(substr(c,5,2))
      return 0.212*lin(r/255) + 0.715*lin(g/255) + 0.072*lin(b/255)
    }
    function hexval(h,   i, c, v) {
      v = 0
      for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        v = v * 16 + ((c >= "0" && c <= "9") ? c + 0 \
          : ((c >= "a" && c <= "f") ? c - "a" + 10 : ((c >= "A" && c <= "F") ? c - "A" + 10 : 0)))
      }
      return v
    }
    function lin(x) { return (x <= 0.0404) ? x / 12.92 : ((x + 0.055) / 1.055) ^ 2.4 }
    BEGIN { printf "%.1f\n", lum(t) - lum(d) }' )
  awk -v v="$lum_ok" 'BEGIN { exit !(v + 0 >= 0.3) }' \
    || fail "$t: title-color $title is not readable on the #092b32 background (luminance gap $lum_ok < 0.3)"
done

# Nothing may still say Spaced Linux in the five files.
for f in "$grub_cfg" "$theme_txt" "$boot_theme" "$default_grub" "$branding_desc"; do
  if grep -n "Spaced Linux" "$f"; then
    fail "$f: still says \"Spaced Linux\" (lines above)"
  fi
done

printf 'OK: GRUB branding is SuperMox %s PC in:\n' "$release"
for f in "$grub_cfg" "$theme_txt" "$boot_theme" "$default_grub" "$branding_desc"; do
  printf '  %s\n' "$f"
done
printf '  splash.png, SimpleBackb.png <- %s\n  spaced-icon-fancy.png <- %s\n' "$bg_png" "$logo_png"
