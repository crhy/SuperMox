#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="packaging/supermox-tmpfiles/usr/bin/systemd-tmpfiles"
if [ ! -f "$script" ]; then
  echo "FAIL: $script missing"
  exit 1
fi

root="build/test-tmpfiles/root"
rm -rf "build/test-tmpfiles"
mkdir -p "$root"

conf="build/test-tmpfiles/sample.conf"
cat > "$conf" <<'EOF'
d /run/tdir 0750 root root - -
f /run/tdir/file 0644 root root - -
L /run/tdir/link - - - - /run/tdir/file
z /run/tdir/file 0600 - - - -
f /run/tdir/victim 0644 root root - -
r /run/tdir/victim - - - - -
EOF

fail=0

sh "$script" --root "$root" --create "$conf"

# d: directory created
if [ ! -d "$root/run/tdir" ]; then
  echo "FAIL: d did not create /run/tdir"
  fail=1
fi
dmode="$(stat -c '%a' "$root/run/tdir" 2>/dev/null || echo none)"
if [ "$dmode" != "750" ]; then
  echo "FAIL: /run/tdir mode is $dmode, expected 750"
  fail=1
fi

# f: file created
if [ ! -f "$root/run/tdir/file" ]; then
  echo "FAIL: f did not create /run/tdir/file"
  fail=1
fi

# L: symlink created pointing at the argument
if [ ! -L "$root/run/tdir/link" ]; then
  echo "FAIL: L did not create symlink /run/tdir/link"
  fail=1
else
  tgt="$(readlink "$root/run/tdir/link")"
  if [ "$tgt" != "/run/tdir/file" ]; then
    echo "FAIL: link target is $tgt, expected /run/tdir/file"
    fail=1
  fi
fi

# z: mode set to 0600 (overrides the 0644 from f)
fmode="$(stat -c '%a' "$root/run/tdir/file" 2>/dev/null || echo none)"
if [ "$fmode" != "600" ]; then
  echo "FAIL: file mode is $fmode, expected 600 (z)"
  fail=1
fi

# r is a no-op under --create: victim still present
if [ ! -f "$root/run/tdir/victim" ]; then
  echo "FAIL: r removed victim during --create"
  fail=1
fi

# --remove: r removes victim
sh "$script" --root "$root" --remove "$conf"
if [ -e "$root/run/tdir/victim" ]; then
  echo "FAIL: --remove did not remove victim"
  fail=1
fi

# unknown type warns but does not fail the caller
uc="build/test-tmpfiles/unknown.conf"
printf 'X /run/tdir/nope - - - - -\n' > "$uc"
rc=0
sh "$script" --root "$root" --create "$uc" 2>/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: unknown type made the script exit $rc"
  fail=1
fi

# --boot --create skips entries that carry an age
bc="build/test-tmpfiles/boot.conf"
printf 'd /run/bootdir 0750 root root - -\nd /run/agedir 0750 root root 1d -\n' > "$bc"
sh "$script" --root "$root" --boot --create "$bc"
if [ ! -d "$root/run/bootdir" ]; then
  echo "FAIL: --boot did not create ageless /run/bootdir"
  fail=1
fi
if [ -d "$root/run/agedir" ]; then
  echo "FAIL: --boot created aged /run/agedir"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-tmpfiles handles d f L z r, unknown types, and --boot"
