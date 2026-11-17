#!/usr/bin/env bash
# Offline check for patches/qemu-server/0004-bound-cpu-flag-probe.patch (#12).
#
# The fixture is the verbatim excerpt of the pinned qemu-server source:
# src/PVE/QemuServer.pm lines 2989-3062, i.e. the doc comment above
# query_supported_cpu_flags through the end of the query_supported_run_qemu
# closure. It starts at 2989 rather than at the first changed line because the
# patch carries three lines of context, so 0004 must apply to it with --fuzz=0.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$PWD"

patchfile="patches/qemu-server/0004-bound-cpu-flag-probe.patch"
fixture="tests/fixtures/qemu-server-cpu-flag-probe.pl"
root="build/test-qmp-probe-bound"
tree="$root/tree"
target="$tree/src/PVE/QemuServer.pm"

if [ ! -f "$patchfile" ]; then
  echo "FAIL: patch missing: $patchfile"
  exit 1
fi
if [ ! -f "$fixture" ]; then
  echo "FAIL: fixture missing: $fixture"
  exit 1
fi

rm -rf "$root"
mkdir -p "$tree/src/PVE"
cp "$fixture" "$target"

rc=0
out="$( ( cd "$tree" && patch -p1 --forward --batch --fuzz=0 < "$repo_root/$patchfile" ) 2>&1 )" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: $patchfile does not apply to the fixture (exit $rc)"
  printf '%s\n' "$out"
  exit 1
fi

fail=0

check_file() {
  local desc="$1"
  shift
  if ! grep -q "$@" -- "$target"; then
    echo "FAIL: patched text missing: $desc"
    fail=1
  fi
}

line_of() {
  local pat="$1"
  grep -nE -- "$pat" "$target" | head -1 | cut -d: -f1
}

# --- the QMP query is bounded -------------------------------------------------
check_file "CPU_FLAG_PROBE_TIMEOUT is a named constant" \
  -E '^my \$CPU_FLAG_PROBE_TIMEOUT = [0-9]+;'

call_block="$(awk '/mon_cmd\(/,/^ *\);/' "$target")"
if ! printf '%s\n' "$call_block" | grep -qF -- "'query-cpu-model-expansion'"; then
  echo "FAIL: no mon_cmd call for query-cpu-model-expansion"
  fail=1
fi
if ! printf '%s\n' "$call_block" | grep -qE -- 'timeout => \$CPU_FLAG_PROBE_TIMEOUT'; then
  echo "FAIL: the query-cpu-model-expansion call sets no bounded timeout"
  printf '%s\n' "$call_block"
  fail=1
fi
if ! printf '%s\n' "$call_block" | grep -qE -- 'noerr => 1'; then
  echo "FAIL: the query-cpu-model-expansion call sets no noerr"
  printf '%s\n' "$call_block"
  fail=1
fi

# a timeout must be reported as a failed probe, never as an empty flag list
check_file "a QMP error or timeout is reported as a failed probe" \
  -E 'die .*cmd_result->\{error\}'

# --- the teardown runs on every exit path -------------------------------------
check_file "the probe pid is read from the pidfile" \
  -F 'IO::File->new("<$pidfile")'
check_file "the probe pid gets SIGTERM" -F "kill 'TERM', \$pid;"
check_file "the probe pid gets SIGKILL" -F "kill 'KILL', \$pid;"
check_file "vm_stop still force-stops vmid -1" \
  -F 'vm_stop(undef, $fakevmid, 1, 1, 10, 0, 1);'

err_line="$(line_of '^ *my \$err = \$@;$')"
kill_line="$(line_of '^ *\$kill_probe_vm->\(\);$')"
stop_line="$(line_of '^ *vm_stop\(undef, \$fakevmid, 1, 1, 10, 0, 1\);$')"
die_line="$(line_of '^ *die \$err if \$err;$')"

if [ -z "$err_line" ] || [ -z "$kill_line" ] || [ -z "$stop_line" ] || [ -z "$die_line" ]; then
  echo "FAIL: could not locate the teardown order markers"
  fail=1
elif [ "$err_line" -lt "$kill_line" ] && [ "$kill_line" -lt "$stop_line" ] && \
     [ "$stop_line" -lt "$die_line" ]; then
  :
else
  echo "FAIL: teardown is not on the timeout path (err=$err_line kill=$kill_line stop=$stop_line die=$die_line)"
  fail=1
fi

# the QEMU exit code must be checked inside the guarded block, so a failed
# startup also reaches the teardown instead of dying before it
rc_line="$(line_of '^ *my \$rc = run_command\(\$cmd, noerr => 1, quiet => 0\);$')"
die_rc_line="$(line_of '^ *die "QEMU flag querying VM exited with code " \. \$rc if \$rc;$')"
if [ -z "$rc_line" ] || [ -z "$die_rc_line" ] || ! [ "$rc_line" -lt "$die_rc_line" ]; then
  echo "FAIL: the QEMU exit code check is not guarded ahead of the teardown"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: 0004 applies to the pinned fixture and bounds the probe (timeout, noerr, pidfile TERM/KILL, vm_stop on every path)"

# --- against the real pinned source, when it is checked out -------------------
co="upstream/pxvirt/packages/qemu-server/qemu-server"
if [ -d "$co" ]; then
  if ! diff -u <(sed -n '2989,3062p' "$co/src/PVE/QemuServer.pm") "$fixture" > "$root/fixture.diff"; then
    echo "FAIL: fixture no longer matches the pinned qemu-server source (lines 2989-3062)"
    cat "$root/fixture.diff"
    exit 1
  fi

  rc=0
  out="$(bash scripts/apply-patches.sh "$root/patched" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: scripts/apply-patches.sh failed (exit $rc)"
    printf '%s\n' "$out"
    exit 1
  fi
  patched_src="$root/patched/qemu-server/qemu-server/src/PVE/QemuServer.pm"
  if ! grep -qE -- 'timeout => \$CPU_FLAG_PROBE_TIMEOUT' "$patched_src"; then
    echo "FAIL: apply-patches.sh did not apply 0004 to the real qemu-server source"
    exit 1
  fi
  # upstream's shape must survive the patch: both accel passes, the lock, the warnings
  for want in \
    'warning: failed querying supported tcg flags' \
    'warning: failed querying supported kvm flags' \
    'PVE::QemuConfig->lock_config' \
    'query_supported_run_qemu->\(0\)' \
    'query_supported_run_qemu->\(1\)'; do
    if ! grep -qE -- "$want" "$patched_src"; then
      echo "FAIL: patched qemu-server lost upstream shape: $want"
      exit 1
    fi
  done

  echo "OK: fixture matches the pinned source and apply-patches.sh applies 0004 with upstream's shape intact"
else
  echo "SKIP: $co absent - fixture-vs-pinned and apply-patches.sh checks not run"
fi

rm -rf "$root"
echo "OK: qmp probe bounded (tests/test-qmp-probe-bound.sh)"
