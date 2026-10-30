#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/check-overrides.sh"
root="build/test-check-overrides"
rm -rf "$root"
mkdir -p "$root"

fail=0

# 1) temp copy of the real file with one bad line appended -> must FAIL
bad="$root/bad-overrides.txt"
cp config/upstream-overrides.txt "$bad"
printf 'pve-common https://git.proxmox.com/git/pve-common.git zbadcommit  # deliberately malformed commit\n' >> "$bad"

rc=0
out="$(bash "$script" "$bad" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: bad overrides file exited 0, expected nonzero"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^FAIL pve-common'; then
  echo "FAIL: bad overrides run did not report a FAIL for pve-common"
  printf '%s\n' "$out"
  fail=1
fi

# 2) the real file -> must not FAIL
rc=0
out="$(bash "$script" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: real overrides file exited $rc, expected 0"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -q '^FAIL '; then
  echo "FAIL: real overrides run reported a FAIL line"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -qE '^(OK|WARN|SKIP) '; then
  echo "FAIL: real overrides run printed no OK/WARN/SKIP lines"
  printf '%s\n' "$out"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: check-overrides.sh FAILs on a malformed line and passes on the real upstream-overrides.txt"
