#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packaging/supermox-manager"
dir="$pkg/debian"
control="$dir/control"
rules="$dir/rules"
desktop="$pkg/supermox-manager.desktop"

fail=0

for f in "$control" "$dir/changelog" "$dir/copyright" "$dir/source/format" "$desktop"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f does not exist"
    exit 1
  fi
done

# Extract the Depends block (the Depends: line plus its indented continuation
# lines) and assert it never mentions systemd.
depends="$(awk '
  /^Depends:/ { f=1; print; next }
  f && /^[[:space:]]/ { print; next }
  f { exit }
' "$control")"

if [ -z "$depends" ]; then
  echo "FAIL: no Depends field found in $control"
  exit 1
fi

if printf '%s\n' "$depends" | grep -qi 'systemd'; then
  echo "FAIL: Depends mentions systemd"
  printf '%s\n' "$depends"
  exit 1
fi

# The app is GTK 3 + WebKitGTK + PyGObject + cryptography; a package that
# forgets one of these installs a launcher that cannot start.
for dep in python3 python3-cryptography python3-gi gir1.2-gtk-3.0 \
  gir1.2-webkit2-4.1 supermox-ve; do
  if ! printf '%s\n' "$depends" | grep -q "$dep"; then
    echo "FAIL: Depends is missing $dep"
    fail=1
  fi
done

if [ ! -x "$rules" ]; then
  echo "FAIL: $rules is not executable"
  fail=1
fi

# The menu entry must name the app, run it and point at our icon.
for line in 'Name=SuperMox Manager' 'Exec=supermox-manager' 'Icon=supermox-manager'; do
  if ! grep -qx "$line" "$desktop"; then
    echo "FAIL: desktop entry missing '$line'"
    fail=1
  fi
done

# vm-build-pkg.sh stages exactly what config/shipped-scripts.txt lists; if a
# module or the launcher is missing there, the installed app is broken.
for entry in \
  "supermox-manager bin/supermox-manager usr/bin/supermox-manager" \
  "supermox-manager src/supermox_manager/__init__.py usr/lib/python3/dist-packages/supermox_manager/__init__.py" \
  "supermox-manager src/supermox_manager/logic.py usr/lib/python3/dist-packages/supermox_manager/logic.py" \
  "supermox-manager src/supermox_manager/app.py usr/lib/python3/dist-packages/supermox_manager/app.py" \
  "supermox-manager website/assets/supermox-symbol.svg usr/share/icons/hicolor/scalable/apps/supermox-manager.svg"; do
  if ! grep -qxF "$entry" config/shipped-scripts.txt; then
    echo "FAIL: config/shipped-scripts.txt missing: $entry"
    fail=1
  fi
done

# supermox-ve must pull the manager in, so a desktop install gets the app.
recommends="$(awk '
  /^Recommends:/ { f=1; print; next }
  f && /^[[:space:]]/ { print; next }
  f { exit }
' packaging/supermox-ve/debian/control)"
if ! printf '%s\n' "$recommends" | grep -q 'supermox-manager'; then
  echo "FAIL: supermox-ve does not Recommend supermox-manager"
  fail=1
fi

# "Proxmox" is a trademark: our own package must never use the name.
if grep -rqi 'proxmox' "$pkg"; then
  echo "FAIL: $pkg mentions the Proxmox name or logo"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-manager packaging passes"
