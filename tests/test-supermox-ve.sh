#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dir="packaging/supermox-ve/debian"
control="$dir/control"
rules="$dir/rules"

fail=0

if [ ! -f "$control" ]; then
  echo "FAIL: $control does not exist"
  exit 1
fi

# Extract the Depends block (the Depends: line plus its indented continuation
# lines) and assert it never mentions systemd.
depends="$(awk '
  /^Depends:/ { f=1; print; next }
  f && /^[[:space:]]/ { print; next }
  f { exit }
' "$control")"

if [ -z "$depends" ]; then
  echo "FAIL: no Depends field found in $control"
  fail=1
elif printf '%s\n' "$depends" | grep -qi 'systemd'; then
  echo "FAIL: Depends mentions systemd"
  printf '%s\n' "$depends"
  fail=1
fi

# Conflicts must list systemd-sysv (and systemd).
if ! grep -qE '^Conflicts:.*systemd-sysv' "$control"; then
  echo "FAIL: control missing Conflicts: systemd-sysv"
  fail=1
fi

# rules must be executable.
if [ ! -x "$rules" ]; then
  echo "FAIL: $rules is not executable"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-ve packaging passes"
