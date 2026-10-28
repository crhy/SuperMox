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

# 1e: a systemd unit file present under lib/systemd/system fails --image
e="$root/e"
mkdir -p "$e/var/lib/dpkg" "$e/sbin" "$e/lib/systemd/system"
printf 'Package: sysvinit-core\nStatus: install ok installed\n\n' > "$e/var/lib/dpkg/status"
printf '#!/sbin/init\n' > "$e/sbin/init"
printf '[Unit]\nDescription=x\n' > "$e/lib/systemd/system/foo.service"
run --image "$e"
assert_rc 1
assert_has "systemd unit tree present: lib/systemd/system/foo.service"

# --source allowlist: an allowlisted file is not counted
al="$root/allowlist.txt"
s2="$root/src2"
mkdir -p "$s2/sub"
printf 'sub/*  # test fixture\n' > "$al"
printf '[Unit]\nDescription=x\n' > "$s2/sub/foo.service"
printf '1\n' > "$root/baseline-allow.txt"
export SYSTEMD_ALLOWLIST_FILE="$al"
export SYSTEMD_BASELINE_FILE="$root/baseline-allow.txt"
run --source "$s2"
assert_rc 0
assert_has "ALLOWED 1"
assert_has "COUNT 0"
unset SYSTEMD_ALLOWLIST_FILE
unset SYSTEMD_BASELINE_FILE

# allowlist line without a "# reason" exits 2
printf 'sub/*\n' > "$al"
export SYSTEMD_ALLOWLIST_FILE="$al"
run --source "$s2"
assert_rc 2
unset SYSTEMD_ALLOWLIST_FILE

# script works when run from build/ (config/ and build/ resolve from repo root)
# uses the raw (unpatched) upstream, which still has 74 references; pin a
# fixture baseline so this check is independent of the repo ratchet baseline.
mkdir -p build
printf '74\n' > "$root/baseline-raw.txt"
export SYSTEMD_BASELINE_FILE="$PWD/$root/baseline-raw.txt"
rc=0
out="$(cd build && bash ../scripts/check-no-systemd.sh --source ../upstream/pxvirt/packages 2>&1)" || rc=$?
unset SYSTEMD_BASELINE_FILE
assert_rc 0
assert_has "COUNT 74"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: check-no-systemd.sh image and source modes behave correctly"
