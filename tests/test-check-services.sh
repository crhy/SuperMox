#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# tests/test-check-services.sh — offline tests for scripts/check-services.sh.
#
# f10d-4: the release check walked /etc/rc2.d, so a service script that was
# installed but never enabled (no S link) was not merely idle, it was invisible.
# The expected set now comes from config/init-scripts.txt, so these tests pin
# that an installed-but-not-enabled script fails the check, that a package
# absent from this node is a SKIP rather than a FAIL, and that comments in the
# list cannot become services.
#
# Everything runs against a fake /etc under build/: SERVICES_ETC_ROOT points the
# check at it, SERVICES_EXPECT_FILE at a copy of the list format, SERVICES_DPKG
# at a stub package query. No real service is touched.

root="$PWD/build/test-check-services"
rm -rf "$root"
mkdir -p "$root/etc/init.d" "$root/etc/rc2.d" "$root/etc/rcS.d" "$root/bin"

mk_script() { # name status_rc
  local f="$root/etc/init.d/$1" rc="$2"
  cat > "$f" <<EOF
#!/bin/sh
case "\$1" in
  status) exit $rc ;;
esac
exit 0
EOF
  chmod 0755 "$f"
}

mk_script good 0
mk_script broken 1
mk_script idle 1
mk_script unenabled 0
mk_script gone 0
mk_script boot 3

ln -s ../init.d/good "$root/etc/rc2.d/S20good"
ln -s ../init.d/broken "$root/etc/rc2.d/S20broken"
ln -s ../init.d/idle "$root/etc/rc2.d/S20idle"
# boot: Default-Start: S, so it is enabled in rcS.d only and its status exits 3
# forever (like Debian's networking); it must not be a FAIL and must not be
# status-checked. unenabled: installed, no S link. gone: its package is not
# installed here.
ln -s ../init.d/boot "$root/etc/rcS.d/S09boot"

cat > "$root/init-scripts.txt" <<'EOF'
# comment line, ignored
pkgA pkgA good
pkgB pkgB broken          # inline comment, ignored
pkgC pkgC idle
pkgD pkgD unenabled
pkgE pkgE gone
pkgF pkgF boot
EOF

cat > "$root/bin/dpkg" <<'EOF'
#!/bin/sh
[ "$1" = pkgE ] && exit 1
exit 0
EOF
chmod 0755 "$root/bin/dpkg"

run_check() {
  SERVICES_ETC_ROOT="$root/etc" \
  SERVICES_EXPECT_FILE="$root/init-scripts.txt" \
  SERVICES_ALLOW="idle" \
  SERVICES_DPKG="$root/bin/dpkg" \
    bash scripts/check-services.sh
}

out=""
rc=0
out="$(run_check 2>&1)" && rc=0 || rc=$?

fail=0
want_line() {
  if printf '%s\n' "$out" | grep -qF -- "$1"; then
    printf 'PASS: %s\n' "$2"
  else
    printf 'FAIL: %s: "%s" missing\n' "$2" "$1"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  fi
}
want_absent() {
  if printf '%s\n' "$out" | grep -qF -- "$1"; then
    printf 'FAIL: %s: "%s" present\n' "$2" "$1"
    printf '%s\n' "$out"
    fail=$((fail + 1))
  else
    printf 'PASS: %s\n' "$2"
  fi
}

if [ "$rc" -ne 1 ]; then
  printf 'FAIL: a shipped script without an S link must fail the check (rc %s)\n' "$rc"
  fail=$((fail + 1))
else
  printf 'PASS: installed but not enabled fails the check\n'
fi
want_line 'PASS: good status' 'an enabled running service passes'
want_line 'FAIL: broken status' 'an enabled service that is not running fails'
want_line 'IDLE: idle status (enabled, idle by design)' 'an allowlisted idle service is reported, not failed'
want_line 'FAIL: unenabled: installed but not enabled (no S link in rc2.d or rcS.d)' 'the invisible service is now visible'
want_line 'plus 1 boot-time service(s) (rcS.d)' 'a Default-Start: S task counts as enabled'
want_absent 'FAIL: boot status' 'a boot-time task is not status-checked'
want_absent 'boot: installed but not enabled' 'an rcS.d-only service is not reported as missing'
want_line 'SKIP: gone (package pkgE not installed on this node)' 'a package absent from this node is a SKIP'
want_absent 'good: installed but not enabled' 'an enabled service is not reported as missing'
want_line 'checked 3 enabled service(s)' 'the enabled set is counted'
want_line 'expected 6 shipped service(s)' 'the shipped set is counted, comments stripped'

# A node where every shipped script is enabled: the same check must pass.
ln -s ../init.d/unenabled "$root/etc/rc2.d/S20unenabled"
mk_script broken 0   # the service fixed: same tree, now every status exits 0
out="$(run_check 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'FAIL: a fully enabled node failed the check (rc %s)\n' "$rc"
  printf '%s\n' "$out"
  fail=$((fail + 1))
else
  printf 'PASS: fully enabled node passes\n'
fi

# A root with no init.d is a setup error, not a passing check.
out="$(SERVICES_ETC_ROOT="$root/nope" SERVICES_EXPECT_FILE="$root/init-scripts.txt" \
  bash scripts/check-services.sh 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 2 ]; then
  printf 'FAIL: a missing init.d should exit 2, got %s\n' "$rc"
  fail=$((fail + 1))
else
  printf 'PASS: missing init.d is a setup error\n'
fi

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf 'PASS: check-services service coverage\n'
