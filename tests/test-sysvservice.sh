#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d upstream/pxvirt/packages/pve-common ]; then
  echo "SKIP"
  exit 0
fi

rm -rf build/patched
if ! bash scripts/apply-patches.sh build/patched >/dev/null; then
  echo "FAIL: apply-patches.sh failed"
  exit 1
fi

srcdir="build/patched/pve-common/pve-common/src"
if [ ! -f "$srcdir/PVE/SysvService.pm" ]; then
  echo "FAIL: SysvService.pm not present after applying patches"
  exit 1
fi

root="$PWD"
tdir="$root/build/test-sysv"
rm -rf "$tdir"
mkdir -p "$tdir/init.d" "$tdir/rc2.d"
log="$tdir/calls.log"
: > "$log"

export PVE_SYSV_INITD_DIR="$tdir/init.d"
export PVE_SYSV_UPDATE_RC_D="$tdir/update-rc.d"
export PVE_SYSV_RC_DIR="$tdir"
export PVE_SYSV_TEST_LOG="$log"

# running service, supports reload, has a Short-Description header
cat > "$tdir/init.d/pve-demo" <<'EOF'
#!/bin/sh
NAME=pve-demo
#  Short-Description: Demo PVE service
printf '%s %s\n' "$NAME" "$1" >> "$PVE_SYSV_TEST_LOG"
case "$1" in
  start) exit 0 ;;
  stop) exit 0 ;;
  restart) exit 0 ;;
  reload) exit 0 ;;
  status) exit 0 ;;
  *) exit 0 ;;
esac
EOF

# stopped service: status exits 3, still supports reload
cat > "$tdir/init.d/pve-stopped" <<'EOF'
#!/bin/sh
NAME=pve-stopped
printf '%s %s\n' "$NAME" "$1" >> "$PVE_SYSV_TEST_LOG"
case "$1" in
  start) exit 0 ;;
  stop) exit 0 ;;
  restart) exit 0 ;;
  reload) exit 0 ;;
  status) exit 3 ;;
  *) exit 0 ;;
esac
EOF

# service with no reload support (no "reload)" or "reload|" anywhere)
cat > "$tdir/init.d/pve-noreload" <<'EOF'
#!/bin/sh
NAME=pve-noreload
printf '%s %s\n' "$NAME" "$1" >> "$PVE_SYSV_TEST_LOG"
case "$1" in
  start) exit 0 ;;
  stop) exit 0 ;;
  restart) exit 0 ;;
  status) exit 0 ;;
  *) exit 0 ;;
esac
EOF

# fake update-rc.d that just logs its arguments
cat > "$tdir/update-rc.d" <<'EOF'
#!/bin/sh
printf 'update-rc.d %s\n' "$*" >> "$PVE_SYSV_TEST_LOG"
exit 0
EOF

chmod +x "$tdir/init.d/pve-demo" "$tdir/init.d/pve-stopped" "$tdir/init.d/pve-noreload" "$tdir/update-rc.d"
ln -s "$tdir/init.d/pve-demo" "$tdir/rc2.d/S99pve-demo"

out=""
rc=0
out="$(perl -I "$srcdir" tests/perl/test-sysvservice.pl 2>&1)" || rc=$?

if printf '%s' "$out" | grep -q "Can't locate"; then
  if printf '%s' "$out" | grep -qE "Can't locate PVE/"; then
    echo "FAIL: a PVE module could not be located"
    printf '%s\n' "$out"
    exit 1
  fi
  echo "SKIP: missing perl module"
  exit 0
fi

if [ "$rc" -ne 0 ]; then
  echo "FAIL: test-sysvservice.pl exited $rc"
  printf '%s\n' "$out"
  exit 1
fi

if ! printf '%s' "$out" | grep -q '^ALL OK$'; then
  echo "FAIL: test-sysvservice.pl did not report ALL OK"
  printf '%s\n' "$out"
  exit 1
fi

printf '%s\n' "$out"
echo "OK: PVE::SysvService behaves correctly"
