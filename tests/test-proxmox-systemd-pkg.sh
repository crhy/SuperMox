#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dir="packaging/librust-proxmox-systemd-dev"
control="$dir/debian/control"
changelog="$dir/debian/changelog"
sysrs="$dir/crate/src/sys.rs"

fail=0

if [ ! -f "$control" ]; then
  echo "FAIL: $control does not exist"
  exit 1
fi

# Extract the Depends block (the Depends: line plus its indented continuation
# lines) and assert it never mentions libsystemd.
depends="$(awk '
  /^Depends:/ { f=1; print; next }
  f && /^[[:space:]]/ { print; next }
  f { exit }
' "$control")"

if [ -z "$depends" ]; then
  echo "FAIL: no Depends field found in $control"
  fail=1
elif printf '%s\n' "$depends" | grep -qi 'libsystemd'; then
  echo "FAIL: Depends mentions libsystemd"
  printf '%s\n' "$depends"
  fail=1
fi

# The packaged version must be 1.0.1-1+supermox1 (changelog header).
if ! head -n 1 "$changelog" | grep -q '1\.0\.1-1+supermox1'; then
  echo "FAIL: changelog version is not 1.0.1-1+supermox1"
  head -n 1 "$changelog"
  fail=1
fi

# The crate source must be present, including sys.rs.
if [ ! -f "$sysrs" ]; then
  echo "FAIL: $sysrs does not exist"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: proxmox-systemd packaging passes"
