#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Stage only public assets, never repository files or credentials.
output=build/website
rm -rf -- "$output"
mkdir -p "$output/assets/screenshots" "$output/documents"
cp website/index.html website/styles.css website/script.js website/_headers "$output/"
cp website/assets/supermox-symbol.svg "$output/assets/"
cp website/assets/screenshots/spaced-desktop.webp \
  website/assets/screenshots/android-lawnchair.jpg \
  website/assets/screenshots/supermox-original-phone.png "$output/assets/screenshots/"
cp website/documents/supermox-whitepaper.pdf "$output/documents/"

echo "Website staged in $output"
