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

# The package owns /etc/supermox/sync-users, the list of users that get a
# Syncthing instance, and nothing else creates it: the init script and the CLI
# both read it and fail without it.  So the package needs a postinst that
# creates it, keeps an existing one, and carries the #DEBHELPER# token dh_install
# uses to insert the enable/start snippets (0.1.7 removed an older postinst that
# hand-rolled those, so it must not hand-roll them again).
postinst="$dir/postinst"
if [ ! -f "$postinst" ]; then
  echo "FAIL: $postinst does not exist: nothing creates /etc/supermox/sync-users"
  fail=1
else
  if [ ! -x "$postinst" ]; then
    echo "FAIL: $postinst is not executable"
    fail=1
  fi
  if ! grep -q '#DEBHELPER#' "$postinst"; then
    echo "FAIL: $postinst has no #DEBHELPER# token"
    fail=1
  fi
  if ! grep -q '/etc/supermox/sync-users' "$postinst"; then
    echo "FAIL: $postinst does not create /etc/supermox/sync-users"
    fail=1
  fi
  if ! grep -qE '! -e[[:space:]]+/etc/supermox/sync-users' "$postinst"; then
    echo "FAIL: $postinst can overwrite an existing sync-users"
    fail=1
  fi
  if grep -qE 'update-rc\.d|invoke-rc\.d' "$postinst";
  then
    echo "FAIL: $postinst hand-rolls rc links or service starts"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-ve packaging passes"
