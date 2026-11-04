#!/usr/bin/env bash
# Behavioural test for init.d/waydroid-container.
#
# What this guards (r13 rows 5 and 10):
#   * `start` must not report success when the LXC container never reaches
#     RUNNING. lxc-start -F returns only once the container is up, and a
#     container that dies at once leaves both pidfiles looking fine, so the
#     old script exited 0 on a dead Android layer (the t60b failure).
#   * `status` must distinguish the three real states: both up (0), daemon
#     alive but container down (1, LSB "dead but pid file exists"), nothing
#     running (3).
#
# Everything the script touches is stubbed: it calls lxc-start/lxc-info through
# overridable paths and lxc-stop/mount/umount/mountpoint/modprobe/start-stop-daemon
# through PATH, and its pid/state files live under build/. No root, no loop
# mounts, no real container.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/waydroid-container"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-init-waydroid.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/run" "$tmp/lxc/waydroid" "$tmp/rootfs" \
  "$tmp/images" "$tmp/state"

# The container's state, as lxc-info would report it. The stubs read/write
# these files; "mode" decides what a fresh lxc-start does.
state_dir="$tmp/state"
printf 'Does not exist\n' > "$state_dir/state"

# --- stubs ---------------------------------------------------------------

# lxc-info -n waydroid -P <path> -s : prints the recorded state.
cat > "$tmp/bin/lxc-info" <<EOF
#!/bin/sh
cat "$state_dir/state"
case "\$(cat "$state_dir/state")" in *RUNNING*) exit 0 ;; *) exit 1 ;; esac
EOF

# lxc-start -n waydroid -P <path> -F -- /init : brings the container up
# according to the mode file, then stays in the foreground like -F does.
cat > "$tmp/bin/lxc-start" <<EOF
#!/bin/sh
case "\$(cat "$state_dir/mode")" in
  running) sleep 1; printf 'RUNNING\n' > "$state_dir/state" ;;
  stopped) printf 'STOPPED\n' > "$state_dir/state" ;;
esac
sleep 600
EOF

# waydroid container start : the D-Bus manager daemon, foreground.
cat > "$tmp/bin/waydroid" <<EOF
#!/bin/sh
[ "\$1" = container ] || exit 0
case "\$2" in
  start) sleep 600 ;;
  stop) printf 'stopped\n' >> "$state_dir/calls" ;;
esac
exit 0
EOF

# start-stop-daemon: enough of --start/--background/--make-pidfile/--stop.
cat > "$tmp/bin/start-stop-daemon" <<'EOF'
#!/bin/bash
action=""
pidfile=""
exec_path=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --start) action=start; shift ;;
    --stop) action=stop; shift ;;
    --pidfile) pidfile="$2"; shift 2 ;;
    --exec) exec_path="$2"; shift 2 ;;
    --retry=*|--user=*|--signal=*) shift ;;
    --background|--make-pidfile|--quiet) shift ;;
    --) shift; args=("$@"); break ;;
    *) shift ;;
  esac
done
case "$action" in
  start)
    [ -n "$exec_path" ] || exit 2
    "$exec_path" "${args[@]}" >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$pidfile"
    exit 0
    ;;
  stop)
    [ -f "$pidfile" ] || exit 0
    pid=$(cat "$pidfile")
    kill -TERM "$pid" 2>/dev/null || exit 1
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$pid" 2>/dev/null || true
    exit 0
    ;;
esac
exit 0
EOF

# Everything else the script calls: record and succeed (mount needs root for
# real), except mountpoint, which must say "not a mountpoint" so the script
# takes its mount path.
for c in lxc-stop mount umount modprobe; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$state_dir" > "$tmp/bin/$c"
done
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/mountpoint"

# waydroid-net.sh (the veth bridge helper) is only checked for -x and run.
printf '#!/bin/sh\necho "net $*" >> "%s/calls"\n' "$state_dir" > "$tmp/bin/waydroid-net.sh"
chmod +x "$tmp/bin"/*

# --- service environment -------------------------------------------------
printf 'x\n' > "$tmp/images/system.img"
printf 'x\n' > "$tmp/images/vendor.img"

svc_env=(
  "PATH=$tmp/bin:$PATH"
  "WAYDROID_BIN=$tmp/bin/waydroid"
  "WAYDROID_PIDFILE=$tmp/run/waydroid-container.pid"
  "WAYDROID_CONTAINER_PIDFILE=$tmp/run/waydroid-container.lxc.pid"
  "WAYDROID_CONF=$tmp/images/system.img"
  "WAYDROID_IMG_DIR=$tmp/images"
  "WAYDROID_LXC_DIR=$tmp/lxc"
  "WAYDROID_ROOTFS=$tmp/rootfs"
  "WAYDROID_NET_SH=$tmp/bin/waydroid-net.sh"
  "WAYDROID_LXC_BIN=$tmp/bin/lxc-start"
  "WAYDROID_LXC_INFO=$tmp/bin/lxc-info"
  "WAYDROID_WAIT_SECS=3"
)

fail=0

kill_stubs() {
  pkill -f "$tmp/bin/waydroid container start" 2>/dev/null || true
  pkill -f "$tmp/bin/lxc-start" 2>/dev/null || true
  rm -f "$tmp/run/waydroid-container.pid" "$tmp/run/waydroid-container.lxc.pid"
}
trap kill_stubs EXIT

run_svc() {
  env "${svc_env[@]}" sh "$1" "${@:2}"
}

# Case 1: the container reaches RUNNING -> start 0, status 0.
printf 'running\n' > "$state_dir/mode"
if ! run_svc "$src" start; then
  echo "FAIL: start exited non-zero although the container reached RUNNING"
  fail=1
fi
if [ "$(cat "$state_dir/state")" != "RUNNING" ]; then
  echo "FAIL: container state is not RUNNING after a good start"
  fail=1
fi
if ! run_svc "$src" status; then
  echo "FAIL: status exited non-zero with daemon and container up"
  fail=1
fi

# Case 2: the container stays STOPPED -> start must fail (1) and undo what
# it started, and status must report the half-broken state as 1.
printf 'stopped\n' > "$state_dir/mode"
printf 'Does not exist\n' > "$state_dir/state"
if run_svc "$src" start; then
  echo "FAIL: start reported success while the container stayed STOPPED"
  fail=1
fi
if [ "$(cat "$state_dir/state")" != "STOPPED" ]; then
  echo "FAIL: container did not end up STOPPED in the failing case"
  fail=1
fi
if [ -f "$tmp/run/waydroid-container.pid" ]; then
  pid=$(cat "$tmp/run/waydroid-container.pid")
  if kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: failed start left the manager daemon running"
    fail=1
  fi
fi
if [ -f "$tmp/run/waydroid-container.lxc.pid" ]; then
  pid=$(cat "$tmp/run/waydroid-container.lxc.pid")
  if kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: failed start left the lxc-start process running"
    fail=1
  fi
fi
# Half-broken state: daemon alive, container STOPPED -> LSB 1.
"$tmp/bin/waydroid" container start >/dev/null 2>&1 &
printf '%s\n' "$!" > "$tmp/run/waydroid-container.pid"
printf 'STOPPED\n' > "$state_dir/state"
status_out=$(run_svc "$src" status; echo "rc=$?")
rc=${status_out##*rc=}
if [ "$rc" != "1" ]; then
  echo "FAIL: status exited $rc with the daemon alive but the container STOPPED (want 1)"
  fail=1
fi
case "$status_out" in
  *STOPPED*) ;;
  *) echo "FAIL: status did not say the container is down: $status_out"; fail=1 ;;
esac

# Case 4: container RUNNING but the manager daemon down -> the other half-state,
# also 1 (a container brought up by hand is not the service being healthy).
kill_stubs
printf 'RUNNING\n' > "$state_dir/state"
status_out=$(run_svc "$src" status; echo "rc=$?")
rc=${status_out##*rc=}
if [ "$rc" != "1" ]; then
  echo "FAIL: status exited $rc with the container RUNNING but no daemon (want 1)"
  fail=1
fi

# Case 3: nothing running -> status 3.
kill_stubs
printf 'Does not exist\n' > "$state_dir/state"
status_out=$(run_svc "$src" status; echo "rc=$?")
rc=${status_out##*rc=}
if [ "$rc" != "3" ]; then
  echo "FAIL: status exited $rc with nothing running (want 3)"
  fail=1
fi

rm -rf "$tmp"
trap - EXIT

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/waydroid-container reports a non-RUNNING container as a failure"
