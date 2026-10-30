#!/usr/bin/env bash
# Build the architecture-neutral desktop package without building a server.
set -euo pipefail
umask 022
cd "$(dirname "$0")/.."

for tool in python3 dpkg-deb rsvg-convert; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p build
stage="$(mktemp -d "$PWD/build/manager-package.XXXXXX")"
chmod 0755 "$stage"
trap 'rm -rf "$stage"' EXIT
while read -r package source destination; do
  [ "$package" = supermox-manager ] || continue
  mode=0644
  [ "$source" != bin/supermox-manager ] || mode=0755
  install -Dm "$mode" "$source" "$stage/$destination"
done < config/shipped-scripts.txt
install -Dm 0644 packaging/supermox-manager/supermox-manager.desktop \
  "$stage/usr/share/applications/supermox-manager.desktop"
install -Dm 0644 packaging/supermox-manager/debian/copyright \
  "$stage/usr/share/doc/supermox-manager/copyright"
for size in 16 24 32 48 64 128 256 512; do
  icon="$stage/usr/share/icons/hicolor/${size}x${size}/apps/supermox-manager.png"
  mkdir -p "$(dirname "$icon")"
  rsvg-convert -w "$size" -h "$size" -o "$icon" \
    "$stage/usr/share/icons/hicolor/scalable/apps/supermox-manager.svg"
done
mkdir -p "$stage/DEBIAN"
version="$(python3 - "$stage" <<'PY'
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
metadata = pathlib.Path('packaging/supermox-manager/debian')
version = re.search(r'\(([^)]+)\)', (metadata / 'changelog').read_text()).group(1)
source, package = (metadata / 'control').read_text().split('\n\n', 1)
package = re.sub(r',\s*\$\{misc:Depends\}', '', package)
maintainer = next(line for line in source.splitlines() if line.startswith('Maintainer:'))
(root / 'DEBIAN/control').write_text(package.rstrip() + '\nVersion: ' + version + '\n' + maintainer + '\n')
print(version)
PY
)"
output="$PWD/build/supermox-manager_${version}_all.deb"
dpkg-deb --root-owner-group --build "$stage" "$output"
echo "Built $output"
