#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/supermox-android-setup.sh"
if [ ! -f "$script" ]; then
  echo "FAIL: $script missing"
  exit 1
fi

fail=0

check_has() {
  local needle="$1"
  if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output missing: $needle"
    fail=1
  fi
}

check_lacks() {
  local needle="$1"
  if printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output should not contain: $needle"
    fail=1
  fi
}

# --dry-run must plan everything and touch nothing.
cache="build/test-android-setup/cache"
rm -rf build/test-android-setup
mkdir -p build/test-android-setup

out="$(bash "$script" --dry-run --cache "$cache" 2>&1)" || {
  echo "FAIL: --dry-run exited non-zero"
  printf '%s\n' "$out"
  exit 1
}

check_has "binder_linux"
check_has "waydroid init"
check_has "sha256"
check_has "waydroid-container"
check_has "Lawnchair"
check_has "waydroid.active_apps"
# A dry run must not create its cache dir or download anything.
if [ -e "$cache" ]; then
  echo "FAIL: --dry-run created $cache"
  fail=1
fi
check_lacks "downloading"

# The pinned digest has to be a full sha256, not a truncated one.
pin="$(grep -m1 '^LAWNCHAIR_SHA256=' "$script" | sed 's/^[^=]*="//; s/"$//')"
if [ "${#pin}" -ne 64 ]; then
  echo "FAIL: pinned sha256 is ${#pin} chars, expected 64"
  fail=1
fi
case "$pin" in
  *[!0-9a-f]*) echo "FAIL: pinned sha256 is not lowercase hex"; fail=1 ;;
esac

# A custom APK URL without its own digest must be refused, not built against
# the pinned digest of the default URL.
out="$(bash "$script" --dry-run --lawnchair-url https://example.invalid/x.apk 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: custom --lawnchair-url accepted without --sha256"
  fail=1
fi
check_has "needs --sha256"

# Bad variant is rejected.
out="$(bash "$script" --dry-run --variant BETA 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: --variant BETA accepted"
  fail=1
fi
check_has "VANILLA or MAINLINE"

# Unknown option is rejected rather than ignored.
out="$(bash "$script" --no-such-flag 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: unknown flag accepted"
  fail=1
fi

# --help works and does not need root.
out="$(bash "$script" --help 2>&1)" || {
  echo "FAIL: --help exited non-zero"
  exit 1
}
check_has "usage: supermox-android-setup"

# --no-lawnchair skips the launcher steps but keeps the container ones.
out="$(bash "$script" --dry-run --no-lawnchair 2>&1)" || {
  echo "FAIL: --dry-run --no-lawnchair exited non-zero"
  exit 1
}
check_has "binder_linux"
check_lacks "waydroid app install"

# The service script the setup tool expects must exist and be registered.
if [ ! -f init.d/waydroid-container ]; then
  echo "FAIL: init.d/waydroid-container missing"
  fail=1
fi
if ! grep -q '^supermox-android supermox-android waydroid-container$' config/init-scripts.txt; then
  echo "FAIL: waydroid-container not registered in config/init-scripts.txt"
  fail=1
fi
if ! grep -q '^supermox-android scripts/supermox-android-setup.sh usr/sbin/supermox-android-setup$' config/shipped-scripts.txt; then
  echo "FAIL: setup script not registered in config/shipped-scripts.txt"
  fail=1
fi

rm -rf build/test-android-setup

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-android-setup plans binder_linux, waydroid init and a sha256-verified launcher"
