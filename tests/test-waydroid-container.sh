#!/usr/bin/env bash
# Behavioural test for init.d/waydroid-container (crhy/SuperMox#7).
#
# The regression this guards: `start` reported success while the Android
# container was down. Nothing asked the container manager for the LXC state,
# so a daemon that stayed up next to a stopped container counted as a pass;
# and when the pidfile was absent the `[ -f "$PIDFILE" ]` guard short-circuited
# the liveness check into the same success path.
#
# Sandbox under build/ with fake `waydroid` and `lxc-info` on PATH, in the
# style of tests/test-init-networking.sh. No path rewriting is needed: the
# script takes its daemon, pidfile, config and image dir from the environment.
# WAYDROID_BIN must be an absolute path - start-stop-daemon resolves a relative
# --exec against / ("cannot stat //build/...").
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/waydroid-container"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-waydroid-container.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/bin_nolxc" "$tmp/tools" "$tmp/run" \
  "$tmp/var/lib/waydroid/images"

# The fake daemons note their own pid before waiting, so nothing outlives the
# test - on the way out as well as between cases.
reap() {
  if [ -f "$tmp/pids" ]; then
    while IFS= read -r p; do
      kill "$p" 2>/dev/null || true
    done < "$tmp/pids"
    # Wait for them to really go away, so a later `status` case cannot see a
    # fake daemon that is still dying.
    n=0
    while [ "$n" -lt 20 ]; do
      alive=0
      while IFS= read -r p; do
        if kill -0 "$p" 2>/dev/null; then
          alive=1
        fi
      done < "$tmp/pids"
      if [ "$alive" -eq 0 ]; then
        break
      fi
      sleep 0.1
      n=$((n + 1))
    done
  fi
}
cleanup() {
  reap
  rm -rf "$tmp"
}
trap cleanup EXIT

# Fake waydroid: records every call, and on `container start` behaves the way
# the case under test needs (WAYDROID_START_MODE: die | alive | drop_pidfile).
cat > "$tmp/bin/waydroid" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WAYDROID_CALLS"
case "$1" in
  "container")
    case "$2" in
      "start")
        case "${WAYDROID_START_MODE:-alive}" in
          die) exit 0 ;;
          drop_pidfile) sleep 3; rm -f "${WAYDROID_PIDFILE:-none}" ;;
        esac
        printf '%s\n' "$$" >> "$WAYDROID_PIDS"
        exec sleep 120
        ;;
      "stop") exit 0 ;;
    esac
    ;;
  "status") printf 'Container: %s\n' "${WAYDROID_STATUS_STATE:-STOPPED}" ;;
esac
exit 0
EOF
cp "$tmp/bin/waydroid" "$tmp/bin_nolxc/waydroid"
chmod +x "$tmp/bin/waydroid" "$tmp/bin_nolxc/waydroid"

# Fake lxc-info: records that it was asked, and answers with the state the
# case asks for.
cat > "$tmp/bin/lxc-info" <<'EOF'
#!/bin/sh
printf 'lxc-info %s\n' "$*" >> "$WAYDROID_CALLS"
printf '%s\n' "${FAKE_LXC_STATE:-STOPPED}"
EOF
chmod +x "$tmp/bin/lxc-info"

# A PATH with no lxc-info anywhere: the case where the lxc tools are not
# installed and container_running has to fall back to `waydroid status`.
for c in sh cat rm sleep grep tr chmod pgrep start-stop-daemon logger \
  tty stty sed expr date uname env; do
  p="$(command -v "$c" || true)"
  if [ -n "$p" ]; then
    ln -s "$p" "$tmp/tools/$c"
  fi
done
if [ ! -e "$tmp/tools/start-stop-daemon" ] || [ ! -e "$tmp/tools/sh" ]; then
  echo "FAIL: cannot build the sandbox PATH (sh or start-stop-daemon missing)"
  exit 1
fi

touch "$tmp/var/lib/waydroid/waydroid.cfg" \
  "$tmp/var/lib/waydroid/images/system.img" \
  "$tmp/var/lib/waydroid/images/vendor.img"

pidfile="$tmp/run/waydroid-container.pid"
run_path="$tmp/bin:$PATH"
start_mode=alive
lxc_state=STOPPED
status_state=STOPPED
fail=0

reset() {
  reap
  rm -f "$tmp/pids" "$tmp/calls" "$pidfile"
}

run_init() {
  PATH="$run_path" \
    WAYDROID_BIN="$tmp/bin/waydroid" \
    WAYDROID_PIDFILE="$pidfile" \
    WAYDROID_CONF="$tmp/var/lib/waydroid/waydroid.cfg" \
    WAYDROID_IMG_DIR="$tmp/var/lib/waydroid/images" \
    WAYDROID_CALLS="$tmp/calls" \
    WAYDROID_PIDS="$tmp/pids" \
    WAYDROID_START_MODE="$start_mode" \
    FAKE_LXC_STATE="$lxc_state" \
    WAYDROID_STATUS_STATE="$status_state" \
    sh "$src" "$@"
}

# Case a: the daemon dies at once. Must not report success.
reset
start_mode=die
rc=0
run_init start || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: start exited 0 with a daemon that dies at once"
  fail=1
fi
start_mode=alive

# Case b: daemon alive, container STOPPED. Must fail, ask the container
# manager, tear the container down and leave no pidfile behind.
reset
lxc_state=STOPPED
rc=0
run_init start || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: start exited 0 with a live daemon and a STOPPED container"
  fail=1
fi
if ! grep -q '^lxc-info ' "$tmp/calls" 2>/dev/null; then
  echo "FAIL: start never asked the container manager for the state"
  fail=1
fi
if ! grep -q '^container stop$' "$tmp/calls" 2>/dev/null; then
  echo "FAIL: the failed start did not call 'container stop'"
  fail=1
fi
if [ -e "$pidfile" ]; then
  echo "FAIL: pidfile left behind after a failed start"
  fail=1
fi

# Case c: daemon alive, container RUNNING. The only case that may succeed.
reset
lxc_state=RUNNING
if ! run_init start; then
  echo "FAIL: start exited non-zero with a live daemon and a RUNNING container"
  fail=1
fi
if grep -q '^container stop$' "$tmp/calls" 2>/dev/null; then
  echo "FAIL: a good start tore the container down"
  fail=1
fi

# Case d: the pidfile is gone after the start, which the old guard read as
# success. Must fail, and name the pid half.
reset
start_mode=drop_pidfile
lxc_state=STOPPED
rc=0
out="$(run_init start 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: start exited 0 with no pidfile after the start"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q 'no live pid'; then
  echo "FAIL: a missing pidfile after start was not reported as a pid failure"
  fail=1
fi

# Case e: status exits 3 when nothing is running.
reset
start_mode=alive
rc=0
run_init status || rc=$?
if [ "$rc" -ne 3 ]; then
  echo "FAIL: status exited $rc, expected 3, with nothing running"
  fail=1
fi

# Case f: no lxc-info on PATH. The state then comes from `waydroid status`:
# RUNNING passes, STOPPED fails.
reset
start_mode=alive
status_state=RUNNING
run_path="$tmp/bin_nolxc:$tmp/tools"
if ! run_init start; then
  echo "FAIL: start exited non-zero without lxc-info and Container: RUNNING"
  fail=1
fi
reset
status_state=STOPPED
if run_init start; then
  echo "FAIL: start exited 0 without lxc-info and Container: STOPPED"
  fail=1
fi

reap

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: waydroid-container start checks the pid and the container state"
