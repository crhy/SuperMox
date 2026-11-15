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

# --arch selects the Waydroid image for the node's architecture: an arm64
# node must get the aarch64 image, never the amd64 one (crhy/SuperMox#6).
out="$(bash "$script" --dry-run --arch arm64 --cache "$cache" 2>&1)" || {
  echo "FAIL: --dry-run --arch arm64 exited non-zero"
  printf '%s\n' "$out"
  exit 1
}
check_has "waydroid init -s VANILLA -a aarch64"
check_has "apt-cache policy waydroid (waydroid >= 1.6.3 must be installable on arm64 nodes)"
# armhf runs the same aarch64 image.
out="$(bash "$script" --dry-run --arch armhf --cache "$cache" 2>&1)" || {
  echo "FAIL: --dry-run --arch armhf exited non-zero"
  fail=1
}
check_has "waydroid init -s VANILLA -a aarch64"

# The default --arch is dpkg --print-architecture, so on this amd64 host the
# plan still names the x86_64 image.
out="$(bash "$script" --dry-run --cache "$cache" 2>&1)" || {
  echo "FAIL: --dry-run exited non-zero"
  fail=1
}
if [ "$(dpkg --print-architecture)" = amd64 ]; then
  check_has "waydroid init -s VANILLA -a x86_64"
fi

# An architecture outside scripts/arch.sh's vocabulary is refused with arch.sh's
# own wording and exit code, not silently mapped onto some image.
want="$(SUPERMOX_ARCH=sparc64 bash -c 'source scripts/arch.sh; supermox_arch_known' 2>&1)" || true
out="$(bash "$script" --dry-run --arch sparc64 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: --arch sparc64 accepted"
  fail=1
fi
if [ "$rc" -ne 2 ]; then
  echo "FAIL: --arch sparc64 exited $rc, expected 2 (scripts/arch.sh's code)"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -qF -- "$want"; then
  echo "FAIL: --arch sparc64 message does not match scripts/arch.sh: [$want]"
  printf '%s\n' "$out"
  fail=1
fi

# Waydroid publishes x86_64 and aarch64 images only, so the other architectures
# SuperMox targets are refused before the script touches anything.
for arch in riscv64 loong64; do
  out="$(bash "$script" --dry-run --arch "$arch" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: --arch $arch accepted although waydroid has no such image"
    fail=1
  fi
  check_has "waydroid publishes no $arch image"
  check_lacks "waydroid init"
done

# The ~1 GB image download must not be planned on a node where the waydroid
# package itself is not installable - the arm64 availability gap the issue
# names. A PATH stub keeps this offline; apt-cache reports no candidate.
stub="build/test-android-setup/stub"
mkdir -p "$stub"
cat > "$stub/apt-cache" <<'EOF'
#!/bin/sh
printf 'waydroid:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n'
EOF
chmod 755 "$stub/apt-cache"
out="$(PATH="$stub:$PATH" bash "$script" --dry-run --arch arm64 --cache "$cache" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: arm64 plan accepted although apt-cache reports no candidate"
  printf '%s\n' "$out"
  fail=1
fi
check_has "no waydroid candidate for arm64 nodes"
check_has "refusing to download the aarch64 image"
check_lacks "waydroid init"

# A candidate below the floor the package declares is refused too.
cat > "$stub/apt-cache" <<'EOF'
#!/bin/sh
printf 'waydroid:\n  Installed: (none)\n  Candidate: 1.5.0+ds-1\n'
EOF
out="$(PATH="$stub:$PATH" bash "$script" --dry-run --arch arm64 --cache "$cache" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: waydroid candidate 1.5.0 accepted below the declared floor"
  fail=1
fi
check_has "older than 1.6.3"
check_lacks "waydroid init"

# The floor the script checks must stay the floor the package declares.
if ! grep -q 'waydroid (>= 1.6.3)' packaging/supermox-android/debian/control; then
  echo "FAIL: packaging/supermox-android/debian/control no longer requires waydroid (>= 1.6.3)"
  fail=1
fi
if ! grep -q '^WAYDROID_MIN_VERSION="1.6.3"$' "$script"; then
  echo "FAIL: $script no longer checks the 1.6.3 floor from debian/control"
  fail=1
fi

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
