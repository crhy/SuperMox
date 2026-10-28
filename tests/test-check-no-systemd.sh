#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/check-no-systemd.sh"
root="build/test-nosystemd"
rm -rf "$root"
mkdir -p "$root"

fail=0
out=""
rc=0

run() {
  rc=0
  out="$(bash "$script" "$@" 2>&1)" || rc=$?
}

assert_rc() {
  local want="$1"
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: exit code $rc, expected $want"
    printf '%s\n' "$out"
    fail=1
  fi
}

assert_has() {
  local needle="$1"
  if ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output missing: $needle"
    printf '%s\n' "$out"
    fail=1
  fi
}

# clean image: sysvinit-core installed, real sbin/init
c="$root/clean"
mkdir -p "$c/var/lib/dpkg" "$c/sbin"
printf 'Package: sysvinit-core\nStatus: install ok installed\n\n' > "$c/var/lib/dpkg/status"
printf '#!/sbin/init\n' > "$c/sbin/init"
run --image "$c"
assert_rc 0
assert_has "No systemd found in image."

# 1a: a systemd package is installed
a="$root/a"
mkdir -p "$a/var/lib/dpkg" "$a/sbin"
printf 'Package: libsystemd0\nStatus: install ok installed\n\n' > "$a/var/lib/dpkg/status"
printf '#!/sbin/init\n' > "$a/sbin/init"
run --image "$a"
assert_rc 1
assert_has "installed package matches systemd: libsystemd0"

# 1b: a systemd binary is present
b="$root/b"
mkdir -p "$b/var/lib/dpkg" "$b/sbin" "$b/bin"
printf 'Package: sysvinit-core\nStatus: install ok installed\n\n' > "$b/var/lib/dpkg/status"
printf '#!/sbin/init\n' > "$b/sbin/init"
printf '#!/bin/systemctl\n' > "$b/bin/systemctl"
run --image "$b"
assert_rc 1
assert_has "systemd binary present: bin/systemctl"

# 1c: sbin/init is a symlink whose target contains systemd
cc="$root/c"
mkdir -p "$cc/var/lib/dpkg" "$cc/sbin"
printf 'Package: sysvinit-core\nStatus: install ok installed\n\n' > "$cc/var/lib/dpkg/status"
ln -s /lib/systemd/systemd "$cc/sbin/init"
run --image "$cc"
assert_rc 1
assert_has "init symlink targets systemd"

# 1d: no init at all
d="$root/d"
mkdir -p "$d/var/lib/dpkg"
printf 'Package: sysvinit-core\nStatus: install ok installed\n\n' > "$d/var/lib/dpkg/status"
run --image "$d"
assert_rc 1
assert_has "no init at sbin/init"

# --source fixture: one .service file, baseline via env override
s="$root/src"
mkdir -p "$s"
printf '[Unit]\nDescription=x\n' > "$s/foo.service"
printf '1\n' > "$root/baseline-pass.txt"
printf '0\n' > "$root/baseline-fail.txt"

export SYSTEMD_BASELINE_FILE="$root/baseline-pass.txt"
run --source "$s"
assert_rc 0
assert_has "COUNT 1"

export SYSTEMD_BASELINE_FILE="$root/baseline-fail.txt"
run --source "$s"
assert_rc 1
assert_has "COUNT 1"
unset SYSTEMD_BASELINE_FILE

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: check-no-systemd.sh image and source modes behave correctly"
