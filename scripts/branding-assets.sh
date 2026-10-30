#!/usr/bin/env bash
# branding-assets.sh - export the PNG sizes tools need from the website SVG.
#
# Source of truth: website/assets/supermox-symbol.svg (see docs/ui-and-branding.md).
# Everything lands in build/branding/ (git-ignored scratch); nobody keeps second
# copies of the logo by hand.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

src=website/assets/supermox-symbol.svg
out=${1:-build/branding}

for tool in rsvg-convert magick; do
  command -v "$tool" >/dev/null || { echo "$0: need $tool" >&2; exit 1; }
done
[ -r "$src" ] || { echo "$0: missing $src" >&2; exit 1; }

mkdir -p "$out"

# --- favicons and logos: the symbol at fixed pixel sizes -------------------
for size in 16 32 48 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$src" -o "$out/logo-${size}.png"
done
for size in 16 32 48; do
  cp "$out/logo-${size}.png" "$out/favicon-${size}.png"
done
magick "$out/favicon-16.png" "$out/favicon-32.png" "$out/favicon-48.png" \
  "$out/favicon.ico"

# --- GRUB background: symbol centred on the SuperMox background colour -----
grub_bg=1920x1080
grub_logo=320
rsvg-convert -w "$grub_logo" -h "$grub_logo" "$src" -o "$out/grub-symbol.png"
magick -size "$grub_bg" xc:'#092b32' \
  "$out/grub-symbol.png" -gravity center -composite \
  "$out/grub-background-${grub_bg}.png"
rm -f "$out/grub-symbol.png"

# --- the SVG itself, for anything that can take a vector logo --------------
cp "$src" "$out/supermox-logo.svg"

echo "branding assets in $out:"
ls -1 "$out"
