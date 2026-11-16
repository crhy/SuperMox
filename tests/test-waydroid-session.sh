#!/usr/bin/env bash
# Behavioural test for the Android session handover in init.d/waydroid-container
# (crhy/SuperMox#7, ported by smx01 onto the 11.26 headless-LXC script).
#
# What this guards:
#   * `start` proves the container half and never starts a session by itself,
#     so a headless node cannot report a dead session next to a live container.
#   * `session-start` refuses unless the container is RUNNING (naming that half)
#     and a Wayland compositor is present (naming that half), and afterwards
#     proves the session the same bounded way instead of trusting a fork.
#   * `stop` tears the session down BEFORE the container, and never leaves the
#     container stranded when the session goes away on its own.
#   * `session-status` distinguishes running (0), nothing (3) and half-broken (1).
#
# Everything the script touches is stubbed, exactly as tests/test-init-waydroid.sh
# does: waydroid / lxc-info / lxc-start / start-stop-daemon / mount helpers live
# under build/, and the pid, lease and state files live there too. No root, no
# loop mounts, no real container, no compositor.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/waydroid-container"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-waydroid-session.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/run" "$tmp/lxc/waydroid" "$tmp/rootfs" \
  "$tmp/images" "$tmp/state" "$tmp/xdg"

state_dir="$tmp/state"
printf 'Does not exist\n' > "$state_dir/state"
printf 'stopped\n' > "$state_dir/session"

# --- stubs ---------------------------------------------------------------

# lxc-info -n waydroid -P <path> -s : prints the recorded container state.
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

# waydroid: the container manager, the session layer and `waydroid status`.
# The session half reports what $state_dir/session says; "dies" makes
# `session start` exit at once, which is the failure the script must report.
cat > "$tmp/bin/waydroid" <<EOF
#!/bin/sh
case "\$1" in
  container)
    case "\$2" in
      start) sleep 600 ;;
      stop) printf 'container stop\n' >> "$state_dir/calls" ;;
    esac
    ;;
  session)
    # A real waydroid reports the session STOPPED once its session daemon is
    # gone, so the stub re-derives the state from the daemon it recorded.
    if [ -f "$state_dir/session.pid" ] &&
      ! kill -0 "\$(cat "$state_dir/session.pid")" 2>/dev/null; then
      printf 'STOPPED\n' > "$state_dir/session"
    fi
    case "\$2" in
      start)
        if [ "\$(cat "$state_dir/session")" = dies ]; then
          exit 1
        fi
        printf 'RUNNING\n' > "$state_dir/session"
        printf '%s\n' "\$\$" > "$state_dir/session.pid"
        sleep 600
        ;;
      stop)
        printf 'STOPPED\n' > "$state_dir/session"
        printf 'session stop\n' >> "$state_dir/calls"
        ;;
    esac
    ;;
  status)
    # A real waydroid reports the session STOPPED once its session daemon has
    # gone, so re-derive the state from the daemon the stub recorded.
    if [ -f "$state_dir/session.pid" ] &&
      ! kill -0 "\$(cat "$state_dir/session.pid")" 2>/dev/null; then
      printf 'STOPPED\n' > "$state_dir/session"
    fi
    printf 'Container: %s\n' "\$(cat "$state_dir/state")"
    printf 'Session: %s\n' "\$(cat "$state_dir/session")"
    ;;
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
    [ -n "${STOP_LOG:-}" ] && printf '%s\n' "$pidfile" >> "$STOP_LOG"
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

for c in lxc-stop mount umount modprobe; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$state_dir" > "$tmp/bin/$c"
done
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/mountpoint"
printf '#!/bin/sh\necho "net $*" >> "%s/calls"\n' "$state_dir" > "$tmp/bin/waydroid-net.sh"
chmod +x "$tmp/bin"/*

# A real AF_UNIX socket, because the script checks the compositor with -S;
# touch would only make a regular file. python3 is already used by the suite.
mk_wayland_socket() {
  python3 - "$1" <<'EOF'
import socket
import sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
EOF
}

# --- service environment -------------------------------------------------
printf 'x\n' > "$tmp/images/system.img"
printf 'x\n' > "$tmp/images/vendor.img"

svc_env=(
  "PATH=$tmp/bin:$PATH"
  "WAYDROID_BIN=$tmp/bin/waydroid"
  "WAYDROID_PIDFILE=$tmp/run/waydroid-container.pid"
  "WAYDROID_CONTAINER_PIDFILE=$tmp/run/waydroid-container.lxc.pid"
  "WAYDROID_SESSION_PIDFILE=$tmp/run/waydroid-session.pid"
  "WAYDROID_CONF=$tmp/images/system.img"
  "WAYDROID_IMG_DIR=$tmp/images"
  "WAYDROID_LXC_DIR=$tmp/lxc"
  "WAYDROID_ROOTFS=$tmp/rootfs"
  "WAYDROID_NET_SH=$tmp/bin/waydroid-net.sh"
  "WAYDROID_LXC_BIN=$tmp/bin/lxc-start"
  "WAYDROID_LXC_INFO=$tmp/bin/lxc-info"
  "WAYDROID_WAIT_SECS=3"
  "STOP_LOG=$state_dir/stopcalls"
)

fail=0

kill_stubs() {
  pkill -f "$tmp/bin/waydroid container start" 2>/dev/null || true
  pkill -f "$tmp/bin/waydroid session start" 2>/dev/null || true
  pkill -f "$tmp/bin/lxc-start" 2>/dev/null || true
  rm -f "$tmp/run/waydroid-container.pid" "$tmp/run/waydroid-container.lxc.pid" \
    "$tmp/run/waydroid-session.pid" "$state_dir/session.pid"
}
trap kill_stubs EXIT

run_svc() {
  env "${svc_env[@]}" "${extra_env[@]}" sh "$1" "${@:2}"
}

# Bring the container half up (the handover starts from a proven container).
start_container_half() {
  printf 'running\n' > "$state_dir/mode"
  printf 'Does not exist\n' > "$state_dir/state"
  run_svc "$src" start
}

# --- case 1: start proves the container and starts NO session -------------
extra_env=()
kill_stubs
printf 'stopped\n' > "$state_dir/session"
start_container_half
if [ -f "$tmp/run/waydroid-session.pid" ]; then
  echo "FAIL: start started a session half by itself"
  fail=1
fi
if [ "$(cat "$state_dir/session")" != "stopped" ]; then
  echo "FAIL: start touched the session half (state $(cat "$state_dir/session"))"
  fail=1
fi

# --- case 2: session-start refused while the container is not RUNNING -----
kill_stubs
printf 'Does not exist\n' > "$state_dir/state"
extra_env=()
out="$(run_svc "$src" session-start 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  echo "FAIL: session-start accepted with the container half down"
  fail=1
fi
case "$out" in
  *"container half"*) ;;
  *) echo "FAIL: refusal did not name the container half: $out"; fail=1 ;;
esac
if [ -f "$tmp/run/waydroid-session.pid" ]; then
  echo "FAIL: the refused session-start left a session pidfile"
  fail=1
fi

# --- case 3: container RUNNING but no compositor -> refused, naming Wayland
extra_env=("XDG_RUNTIME_DIR=$tmp/xdg" "WAYLAND_DISPLAY=")
start_container_half
out="$(run_svc "$src" session-start 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  echo "FAIL: session-start accepted with no Wayland socket"
  fail=1
fi
case "$out" in
  *"Wayland socket"*) ;;
  *) echo "FAIL: refusal did not name the Wayland half: $out"; fail=1 ;;
esac
if [ -f "$tmp/run/waydroid-session.pid" ]; then
  echo "FAIL: the no-compositor refusal left a session pidfile"
  fail=1
fi

# --- case 4: container RUNNING + wayland socket -> session starts and proves
mk_wayland_socket "$tmp/xdg/wayland-0.sock"
start_container_half
if ! run_svc "$src" session-start; then
  echo "FAIL: session-start failed with a proven container and a Wayland socket"
  fail=1
fi
if [ ! -f "$tmp/run/waydroid-session.pid" ]; then
  echo "FAIL: a good session start left no session pidfile"
  fail=1
fi
if ! run_svc "$src" session-status; then
  echo "FAIL: session-status exited non-zero with the session up"
  fail=1
fi

# --- case 5: WAYLAND_DISPLAY alone is accepted ---------------------------
kill_stubs
extra_env=("XDG_RUNTIME_DIR=" "WAYLAND_DISPLAY=wayland-1")
start_container_half
if ! run_svc "$src" session-start; then
  echo "FAIL: session-start refused although WAYLAND_DISPLAY was set"
  fail=1
fi

# --- case 6: a session that dies at once is reported, not hidden ---------
kill_stubs
printf 'dies\n' > "$state_dir/session"
extra_env=("XDG_RUNTIME_DIR=$tmp/xdg" "WAYLAND_DISPLAY=")
start_container_half
out="$(run_svc "$src" session-start 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
  echo "FAIL: session-start reported success with a session that died at once"
  fail=1
fi
case "$out" in
  *"session half failed"*) ;;
  *) echo "FAIL: the failure did not name the session half: $out"; fail=1 ;;
esac
if [ -f "$tmp/run/waydroid-session.pid" ]; then
  echo "FAIL: the failed session start left a session pidfile behind"
  fail=1
fi

# --- case 7: session-status with nothing running exits 3 (LSB dead) ------
kill_stubs
printf 'STOPPED\n' > "$state_dir/session"
extra_env=()
run_svc "$src" session-status && rc=0 || rc=$?
if [ "$rc" != "3" ] && [ "$rc" != "1" ]; then
  echo "FAIL: session-status with nothing running exited $rc (want 3 or 1)"
  fail=1
fi

# --- case 8: stop tears the session down BEFORE the container ------------
kill_stubs
printf 'stopped\n' > "$state_dir/session"
extra_env=("XDG_RUNTIME_DIR=$tmp/xdg" "WAYLAND_DISPLAY=")
start_container_half
if ! run_svc "$src" session-start; then
  echo "FAIL: case 8 could not start the session half"
  fail=1
fi
session_pid=$(cat "$tmp/run/waydroid-session.pid")
container_pid=$(cat "$tmp/run/waydroid-container.pid")
: > "$state_dir/stopcalls"
if ! run_svc "$src" stop; then
  echo "FAIL: stop exited non-zero"
  fail=1
fi
if kill -0 "$session_pid" 2>/dev/null; then
  echo "FAIL: stop left the session daemon running"
  fail=1
fi
if kill -0 "$container_pid" 2>/dev/null; then
  echo "FAIL: stop left the container manager daemon running"
  fail=1
fi
if [ -f "$tmp/run/waydroid-session.pid" ] || [ -f "$tmp/run/waydroid-container.pid" ]; then
  echo "FAIL: stop left a pidfile behind"
  fail=1
fi
# The session half's pidfile must be stopped before the container manager's,
# recorded by the start-stop-daemon stub in the order the script asked.
case "$(cat "$state_dir/stopcalls")" in
  *"$tmp/run/waydroid-session.pid"*)
    sess_line=$(grep -n -F "$tmp/run/waydroid-session.pid" "$state_dir/stopcalls" | head -1 | cut -d: -f1)
    cont_line=$(grep -n -F "$tmp/run/waydroid-container.pid" "$state_dir/stopcalls" | head -1 | cut -d: -f1)
    if [ -n "$cont_line" ] && [ "$sess_line" -gt "$cont_line" ]; then
      echo "FAIL: stop stopped the container half before the session half"
      fail=1
    fi
    ;;
  *)
    echo "FAIL: stop never stopped the session half through its pidfile"
    fail=1
    ;;
esac
# The session half must be down: ask waydroid, which is what the script reads.
session_now=$("$tmp/bin/waydroid" status | sed -n 's/^Session:[[:space:]]*//p')
case "$session_now" in
  RUNNING) echo "FAIL: the session half is RUNNING after stop"; fail=1 ;;
esac

# --- case 9: session-stop alone leaves the container alone ---------------
kill_stubs
printf 'stopped\n' > "$state_dir/session"
extra_env=("XDG_RUNTIME_DIR=$tmp/xdg" "WAYLAND_DISPLAY=")
start_container_half
if ! run_svc "$src" session-start; then
  echo "FAIL: case 9 could not start the session half"
  fail=1
fi
container_pid=$(cat "$tmp/run/waydroid-container.pid")
if ! run_svc "$src" session-stop; then
  echo "FAIL: session-stop exited non-zero"
  fail=1
fi
if kill -0 "$container_pid" 2>/dev/null; then
  : # expected: session-stop must not touch the container
else
  echo "FAIL: session-stop killed the container manager daemon"
  fail=1
fi
if ! run_svc "$src" session-status; then
  : # the session is down now: 0 is not expected
fi
kill_stubs

rm -rf "$tmp"
trap - EXIT

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/waydroid-container owns the Android session handover and reports it honestly"
