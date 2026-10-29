#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="init.d/supermox-binfmt"
if [ ! -f "$script" ]; then
  echo "FAIL: $script missing"
  exit 1
fi

root="build/test-supermox-binfmt/root"
rm -rf "build/test-supermox-binfmt"
mkdir -p "$root/proc/sys/fs/binfmt_misc" \
  "$root/usr/lib/binfmt.d" "$root/etc/binfmt.d" "$root/run/binfmt.d"

# Fake binfmt_misc mount point: register is a plain file we can append to.
reg="$root/proc/sys/fs/binfmt_misc/register"
: > "$reg"

# Pretend the filesystem is already mounted so start() does not call mount.
printf 'proc /proc proc 0 0\nbinfmt_misc %s binfmt_misc 0 0\n' "$root/proc/sys/fs/binfmt_misc" \
  > "$root/proc/mounts"

# An entry that is already registered: start must not send it again.
mkdir "$root/proc/sys/fs/binfmt_misc/qemu-pre"

# Same file name in three directories: the later directory must win.
cat > "$root/usr/lib/binfmt.d/qemu-arm64.conf" <<'EOF'
# shipped by the qemu-user-binfmt package
:qemu-pre:M::\x7fELF::/usr/bin/qemu-arm64:PCF
:qemu-arm64:M::FROM-USR-LIB::/usr/bin/qemu-arm64:POC
EOF

cat > "$root/etc/binfmt.d/qemu-arm64.conf" <<'EOF'
:qemu-arm64:M::FROM-ETC::/usr/bin/qemu-arm64:POC
EOF

cat > "$root/run/binfmt.d/extra.conf" <<'EOF'

:qemu-riscv64:M::FROM-RUN::/usr/bin/qemu-riscv64:OC
EOF

fail=0

BINFMT_ROOT="$root" sh "$script" start

grep_test() {
  local desc="$1" pat="$2"
  if ! grep -qF -- "$pat" "$reg"; then
    echo "FAIL: $desc (no '$pat' in the fake register file)"
    printf '%s\n' "$reg content:"
    sed 's/^/  /' "$reg"
    fail=1
  fi
}

not_test() {
  local desc="$1" pat="$2"
  if grep -qF -- "$pat" "$reg"; then
    echo "FAIL: $desc ('$pat' is present)"
    fail=1
  fi
}

# The /etc copy of qemu-arm64.conf won over the /usr/lib one.
grep_test "/etc wins over /usr/lib" "FROM-ETC"
not_test "/usr/lib copy was used" "FROM-USR-LIB"

# The /run drop-in was registered too.
grep_test "/run drop-in registered" "FROM-RUN"

# The already-registered handler was skipped.
not_test "already-registered entry re-sent" "qemu-pre"

# Comments and blank lines are never sent to the register file.
if grep -qE '^[[:space:]]*(#|$)' "$reg"; then
  echo "FAIL: comment or blank line written to the register file"
  fail=1
fi

# Every registered line must carry a name field (starts with :name:).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    :?*:*) ;;
    *) echo "FAIL: bad binfmt rule written: $line"; fail=1 ;;
  esac
done < "$reg"

# stop is a no-op: the register file is untouched.
before="$(cat "$reg")"
BINFMT_ROOT="$root" sh "$script" stop
after="$(cat "$reg")"
if [ "$before" != "$after" ]; then
  echo "FAIL: stop changed the register file"
  fail=1
fi

# status lists the registered entries (qemu-pre is the fake one we created).
status_out="$(BINFMT_ROOT="$root" sh "$script" status 2>&1)"
if ! printf '%s\n' "$status_out" | grep -q 'qemu-pre'; then
  echo "FAIL: status did not list the registered entry qemu-pre"
  printf '%s\n' "$status_out"
  fail=1
fi
if printf '%s\n' "$status_out" | grep -qE 'register'; then
  echo "FAIL: status listed the pseudo-entry 'register'"
  fail=1
fi

# Re-running start must not duplicate an entry that is now present as a
# plain file in the mount point (simulates a second boot).
mkdir "$root/proc/sys/fs/binfmt_misc/qemu-riscv64"
BINFMT_ROOT="$root" sh "$script" start >/dev/null
if [ "$(grep -c 'FROM-RUN' "$reg")" != "1" ]; then
  echo "FAIL: second start duplicated qemu-riscv64"
  fail=1
fi

# Unknown action exits 2 with a usage line.
rc=0
BINFMT_ROOT="$root" sh "$script" bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" != "2" ]; then
  echo "FAIL: unknown action exited $rc, expected 2"
  fail=1
fi

# A missing binfmt_misc mount point is reported, not fatal for status.
rm -rf "build/test-supermox-binfmt/empty"
mkdir -p "build/test-supermox-binfmt/empty"
rc=0
BINFMT_ROOT="build/test-supermox-binfmt/empty" sh "$script" status >/dev/null 2>&1 || rc=$?
if [ "$rc" != "1" ]; then
  echo "FAIL: status with no mount point exited $rc, expected 1"
  fail=1
fi

# Without a binfmt_misc mount (and without root to mount one) start must fail
# rather than pretend the handlers were loaded. Skipped when the gate runs as
# root: the script would really mount binfmt_misc on a path under build/.
if [ "$(id -u)" != "0" ]; then
  mkdir -p "build/test-supermox-binfmt/unmounted/proc/sys/fs/binfmt_misc"
  printf 'proc /proc proc 0 0\n' > "build/test-supermox-binfmt/unmounted/proc/mounts"
  rc=0
  BINFMT_ROOT="build/test-supermox-binfmt/unmounted" sh "$script" start >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then
    echo "FAIL: start succeeded without a usable binfmt_misc register file"
    fail=1
  fi
fi

rm -rf "build/test-supermox-binfmt"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-binfmt registers binfmt.d rules, honours /etc over /usr/lib, skips registered entries"
