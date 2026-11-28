#!/usr/bin/env bash
set -euo pipefail

# Offline test for scripts/supermox-reap-orphans.
#
# A PVE forking daemon's workers have a FULL command line of exactly "<name> worker"
# and, once the master dies, a parent of pid 1. We reproduce that with setsid +
# perl setproctitle (verified: `perl -e '$0="X"; sleep 300'` gives /proc/PID/cmdline
# exactly "X", and setsid reparents the child to pid 1). The helper must kill ONLY
# the exact "<name> worker" match; "<name> worker2" and "<name>" must survive.

cd "$(dirname "$0")/.."

helper="scripts/supermox-reap-orphans"
if [ ! -f "$helper" ]; then
  echo "FAIL: helper $helper missing"
  exit 1
fi

name="smxreaptest"
title_worker="$name worker"
title_worker2="$name worker2"
title_bare="$name"

fail=0

# Spawn a detached process whose full cmdline is exactly $1, alive for 300s.
# $2 (optional) makes it ignore SIGTERM so the KILL path is exercised.
spawn() {
  local title="$1" ignore="${2:-}"
  if [ -n "$ignore" ]; then
    setsid perl -e "\$SIG{TERM}=\"IGNORE\"; \$0 = \"$title\"; sleep 300" &
  else
    setsid perl -e "\$0 = \"$title\"; sleep 300" &
  fi
}

# pid whose FULL cmdline is exactly $1 (empty if none).
pid_of() { pgrep -x -f "$1" | head -1 || true; }

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

cleanup() {
  for t in "$title_worker" "$title_worker2" "$title_bare"; do
    for p in $(pgrep -x -f "$t" || true); do
      kill -KILL "$p" 2>/dev/null || true
    done
  done
  rm -f build/reap-orphans.pid 2>/dev/null || true
}
trap cleanup EXIT

# --- Case 1: master missing (no pidfile) -> reap the exact worker only ---
spawn "$title_worker"
spawn "$title_worker2"
spawn "$title_bare"
sleep 1

wp=$(pid_of "$title_worker")
w2p=$(pid_of "$title_worker2")
bp=$(pid_of "$title_bare")
if [ -z "$wp" ] || [ -z "$w2p" ] || [ -z "$bp" ]; then
  echo "FAIL: could not start all three fake processes"
  exit 1
fi

# Reparent pid for the helper (setsid child is normally pid 1; be robust).
ppid=$(ps -o ppid= -p "$wp" | tr -d ' ')
SUPERMOX_REAP_PARENT="$ppid" sh "$helper" "$name"

sleep 1
if alive "$wp"; then
  echo "FAIL: exact '$title_worker' was NOT killed"
  fail=1
fi
if ! alive "$w2p"; then
  echo "FAIL: '$title_worker2' was killed but must survive"
  fail=1
fi
if ! alive "$bp"; then
  echo "FAIL: '$title_bare' was killed but must survive"
  fail=1
fi
echo "OK: reaped exact '$title_worker'; '$title_worker2' and '$title_bare' survived"

# --- Case 2: live master in pidfile -> helper must do nothing ---
sleep 300 &
master=$!
echo "$master" > build/reap-orphans.pid
spawn "$title_worker"
sleep 1
wp2=$(pid_of "$title_worker")
if [ -z "$wp2" ]; then
  echo "FAIL: could not start worker for guard test"
  exit 1
fi
ppid2=$(ps -o ppid= -p "$wp2" | tr -d ' ')
SUPERMOX_REAP_PARENT="$ppid2" sh "$helper" "$name" build/reap-orphans.pid
sleep 1
if ! alive "$wp2"; then
  echo "FAIL: helper killed a worker while the master was alive"
  fail=1
else
  echo "OK: live-master guard left the worker alone"
fi
kill "$master" 2>/dev/null || true
rm -f build/reap-orphans.pid

# --- Case 3: worker ignores SIGTERM -> helper must escalate to SIGKILL ---
spawn "$title_worker" ignore
sleep 1
wp3=$(pid_of "$title_worker")
if [ -z "$wp3" ]; then
  echo "FAIL: could not start TERM-ignoring worker"
  exit 1
fi
ppid3=$(ps -o ppid= -p "$wp3" | tr -d ' ')
start=$(date +%s)
SUPERMOX_REAP_PARENT="$ppid3" sh "$helper" "$name"
elapsed=$(( $(date +%s) - start ))
sleep 0.5
if alive "$wp3"; then
  echo "FAIL: TERM-ignoring worker survived the KILL escalation"
  fail=1
else
  echo "OK: TERM-ignoring worker killed via SIGKILL (helper took ${elapsed}s)"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: supermox-reap-orphans passes"
