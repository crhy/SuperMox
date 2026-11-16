#!/usr/bin/env bash
# Behavioural test for the container -> session handover in
# init.d/waydroid-container (crhy/SuperMox#7, step 2 of "make it shippable":
# decide and implement the handover in the init script, then test start,
# stop and reboot).
#
# What it guards: the session half (`waydroid session start`, the layer that
# bind-mounts the Wayland socket and serves `waydroid app install`) used to
# be absent from the service script altogether - `grep -c session` was 0 -
# so nothing proved the container was RUNNING before a session was started,
# nothing refused when the compositor was missing, and `status` could not
# say which half was down.
#
# Sandbox under build/ in the style of tests/test-android-setup.sh. The PATH
# is built ONLY from the sandbox bin: the runner's PATH does not carry
# /usr/sbin, so the real start-stop-daemon cannot be assumed (that is what
# made the parked attempt unrunnable). Fake waydroid, lxc-info,
# start-stop-daemon, pgrep, pkill and kill live in the sandbox bin; the
# coreutils the script and /lib/lsb/init-functions need are linked in from
# absolute paths, never from $PATH.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/waydroid-container"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-waydroid-session"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/bin_nolxc" "$tmp/run" "$tmp/xdg" \
  "$tmp/var/lib/waydroid/images"

bin="$tmp/bin"
nolxc="$tmp/bin_nolxc"
calls="$tmp/calls"
procs="$tmp/procs"
logf="$tmp/daemons.log"
pidfile="$tmp/run/waydroid-container.pid"
session_pidfile="$tmp/run/waydroid-session.pid"
cfg="$tmp/var/lib/waydroid/waydroid.cfg"

# Fake waydroid: records every call, answers `status` with the state each
# half is supposed to report, and on `container start` / `session start`
# either dies at once (mode=die) or stays up (mode=alive) as the case needs.
cat > "$bin/waydroid" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${WAYDROID_CALLS:?}"
case "$1" in
  status)
    printf 'Container: %s\n' "${FAKE_CONTAINER_STATE:-STOPPED}"
    printf 'Session: %s\n' "${FAKE_SESSION_STATE:-STOPPED}"
    exit 0
    ;;
  container)
    case "$2" in
      start)
        [ "${WAYDROID_CONTAINER_MODE:-alive}" = die ] && exit 0
        printf '%s|%s\n' "$$" "$0 $*" >> "${WAYDROID_PROCS:?}"
        exec sleep 120
        ;;
      stop) exit 0 ;;
    esac
    ;;
  session)
    case "$2" in
      start)
        [ "${WAYDROID_SESSION_MODE:-alive}" = die ] && exit 0
        printf '%s|%s\n' "$$" "$0 $*" >> "${WAYDROID_PROCS:?}"
        exec sleep 120
        ;;
      stop) exit 0 ;;
    esac
    ;;
esac
exit 0
EOF

# Fake lxc-info: records that the container manager was asked for the LXC
# state, and answers with the state the case asks for.
cat > "$bin/lxc-info" <<'EOF'
#!/bin/sh
printf 'lxc-info %s\n' "$*" >> "${WAYDROID_CALLS:?}"
printf '%s\n' "${FAKE_LXC_STATE:-STOPPED}"
EOF

# Fake start-stop-daemon: emulates the two calls the script makes
# (--start --background --make-pidfile --pidfile F --exec E -- ARGS, and
# --stop --retry=TERM/20/KILL/5 --pidfile F). The daemon it spawns must
# not hold the caller's stdout open, or the test's command substitution
# would wait for a 120 s sleep.
cat > "$bin/start-stop-daemon" <<'EOF'
#!/bin/sh
printf 'start-stop-daemon %s\n' "$*" >> "${WAYDROID_CALLS:?}"
mode=
pidfile=
exec=
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --start) mode=start ;;
    --stop) mode=stop ;;
    --pidfile) pidfile="$2"; shift 2; continue ;;
    --exec) exec="$2"; shift 2; continue ;;
    --retry) shift 2; continue ;;
    --retry=*) ;;
    --quiet | --background | --make-pidfile | --okstart) ;;
    *) ;;
  esac
  shift
done
if [ "$mode" = start ]; then
  if [ -n "$pidfile" ] && [ -f "$pidfile" ] &&
    kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    exit 0 # already running, like the real one
  fi
  "$exec" "$@" </dev/null >>"${WAYDROID_LOG:-/dev/null}" 2>&1 &
  printf '%s\n' "$!" > "$pidfile"
  exit 0
fi
if [ "$mode" = stop ]; then
  if [ -n "$pidfile" ] && [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      i=0
      while [ "$i" -lt 20 ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
        i=$((i + 1))
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
      exit 0
    fi
  fi
  exit 1 # no live pid in the pidfile, like the real one
fi
exit 2
EOF

# Fake pgrep/pkill (installed under both names): the script finds a daemon
# whose pidfile is gone by its command line, so the sandbox keeps a registry
# of the processes it spawned, as "pid|command line".
cat > "$bin/pgrep" <<'EOF'
#!/bin/sh
mode=pgrep
case "$0" in *pkill*) mode=pkill ;; esac
pat=
while [ $# -gt 0 ]; do
  case "$1" in
    -*) ;;
    *) pat="$1"; break ;;
  esac
  shift
done
rc=1
if [ -f "${WAYDROID_PROCS:-/nonexistent}" ]; then
  while IFS='|' read -r pid cmd; do
    case "$cmd" in
      *"$pat"*)
        if kill -0 "$pid" 2>/dev/null; then
          printf '%s\n' "$pid"
          rc=0
          [ "$mode" = pkill ] && kill -TERM "$pid" 2>/dev/null
        fi
        ;;
    esac
  done < "${WAYDROID_PROCS:-/nonexistent}"
fi
exit "$rc"
EOF
cp "$bin/pgrep" "$bin/pkill"

# Fake kill: `kill` is a shell builtin, so the script itself never goes
# through PATH for it; this keeps the sandbox PATH complete and puts any
# signal request in the call log.
cat > "$bin/kill" <<'EOF'
#!/bin/sh
printf 'kill %s\n' "$*" >> "${WAYDROID_CALLS:-/dev/null}"
/bin/kill "$@"
EOF

# The fakes are invoked through PATH by the service script, so they must
# be executable.
chmod +x "$bin/waydroid" "$bin/lxc-info" "$bin/start-stop-daemon" \
  "$bin/pgrep" "$bin/pkill" "$bin/kill"

# A PATH that is ONLY the sandbox bin, so link the coreutils the script
# and /lib/lsb/init-functions need from absolute paths.
missing=""
for c in sh cat rm sed grep tr head sleep chmod ln mkdir; do
  hit=""
  for d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -x "$d/$c" ]; then
      hit="$d/$c"
      break
    fi
  done
  if [ -n "$hit" ]; then
    ln -s "$hit" "$bin/$c"
  else
    missing="$missing $c"
  fi
done
if [ -n "$missing" ]; then
  echo "FAIL: cannot build the sandbox PATH (missing:$missing)"
  exit 1
fi

# The same PATH with no lxc-info anywhere: the node where the lxc tools
# are not installed and the container state must come from `waydroid
# status`.
for f in "$bin"/*; do
  case "$f" in
    */lxc-info) continue ;;
  esac
  ln -s "$f" "$nolxc/${f##*/}"
done

touch "$cfg" "$tmp/var/lib/waydroid/images/system.img" \
  "$tmp/var/lib/waydroid/images/vendor.img"

# Case state, reset by reset().
lxc_state=STOPPED
container_state=STOPPED
session_state=STOPPED
container_mode=alive
session_mode=alive
wayland_display=""
sandbox_bin="$bin"

reap() {
  if [ -f "$procs" ]; then
    while IFS='|' read -r pid _; do
      kill -9 "$pid" 2>/dev/null || true
    done < "$procs"
  fi
}
cleanup() {
  reap
  rm -rf "$tmp"
}
trap cleanup EXIT

reset() {
  reap
  rm -f "$procs" "$calls" "$pidfile" "$session_pidfile"
  lxc_state=STOPPED
  container_state=STOPPED
  session_state=STOPPED
  container_mode=alive
  session_mode=alive
  wayland_display=""
  sandbox_bin="$bin"
}

# Run the service script with the sandbox PATH only. WAYDROID_PROVE_TRIES=2
# keeps a failing prove loop short (the script's default is 10 tries of 1 s).
run_init() {
  local sub="$1"
  shift
  PATH="$sandbox_bin" \
    WAYDROID_BIN="$bin/waydroid" \
    WAYDROID_PIDFILE="$pidfile" \
    WAYDROID_SESSION_PIDFILE="$session_pidfile" \
    WAYDROID_CONF="$cfg" \
    WAYDROID_IMG_DIR="$tmp/var/lib/waydroid/images" \
    WAYDROID_LXC_NAME=waydroid \
    WAYDROID_PROVE_TRIES=2 \
    WAYDROID_CALLS="$calls" \
    WAYDROID_PROCS="$procs" \
    WAYDROID_LOG="$logf" \
    FAKE_LXC_STATE="$lxc_state" \
    FAKE_CONTAINER_STATE="$container_state" \
    FAKE_SESSION_STATE="$session_state" \
    WAYDROID_CONTAINER_MODE="$container_mode" \
    WAYDROID_SESSION_MODE="$session_mode" \
    WAYLAND_DISPLAY="$wayland_display" \
    XDG_RUNTIME_DIR="$tmp/xdg" \
    sh "$src" "$sub" "$@"
}

# A Wayland socket in XDG_RUNTIME_DIR, the way a compositor leaves one.
# A plain file is not enough: the script checks for a socket.
mksock() {
  rm -f "$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"
  else
    echo "FAIL: python3 needed to create a unix socket in the sandbox"
    exit 1
  fi
}

fail=0

check_has() {
  local needle="$1"
  if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output missing: $needle"
    fail=1
  fi
}

check_lacks() {
  local needle="$1"
  if printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output should not contain: $needle"
    fail=1
  fi
}

check_rc() {
  local want="$1" got="$2" label="$3"
  if [ "$got" != "$want" ]; then
    echo "FAIL: $label exited $got, expected $want"
    fail=1
  fi
}

# A call log line proving the session half was started.
started_session() {
  grep -qF -- 'session start' "$calls" 2>/dev/null
}

# ---------------------------------------------------------------------------
# start: the container half must be proven, and must not start a session.
reset
lxc_state=RUNNING
out="$(run_init start 2>&1)" || true
if [ ! -f "$pidfile" ]; then
  echo "FAIL: start recorded no container pidfile"
  fail=1
fi
if started_session; then
  echo "FAIL: start started the session half by itself"
  fail=1
fi
check_has "Starting waydroid-container (container half)"
check_lacks "session half"

# start must fail when the container never reaches RUNNING, and must name
# the half that failed and tear the container down.
reset
lxc_state=STOPPED
out="$(run_init start 2>&1)" && rc=0 || rc=$?
check_rc 1 "$rc" "start with a STOPPED container"
check_has "container half failed to come up"
if ! grep -qF -- 'container stop' "$calls" 2>/dev/null; then
  echo "FAIL: the failed start did not call 'container stop'"
  fail=1
fi
if [ -e "$pidfile" ]; then
  echo "FAIL: pidfile left behind after a failed start"
  fail=1
fi

# ---------------------------------------------------------------------------
# session-start refused while the container half is down.
reset
lxc_state=STOPPED
out="$(run_init session-start 2>&1)" && rc=0 || rc=$?
check_rc 1 "$rc" "session-start with the container down"
check_has "session half refused, container half is STOPPED"
if started_session; then
  echo "FAIL: session-start spawned a session with the container down"
  fail=1
fi
if [ -e "$session_pidfile" ]; then
  echo "FAIL: session-start recorded a pidfile with the container down"
  fail=1
fi

# session-start refused with the container RUNNING but no Wayland socket.
reset
lxc_state=RUNNING
out="$(run_init session-start 2>&1)" && rc=0 || rc=$?
check_rc 1 "$rc" "session-start with no Wayland socket"
check_has "session half refused, no Wayland socket"
if started_session; then
  echo "FAIL: session-start spawned a session with no compositor"
  fail=1
fi

# A compositor named by WAYLAND_DISPLAY counts even when its socket is
# not under XDG_RUNTIME_DIR (seatd + weston on a headless node).
reset
lxc_state=RUNNING
session_state=RUNNING
wayland_display=wayland-0
out="$(run_init session-start 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "session-start with WAYLAND_DISPLAY set and no socket file"
if ! started_session; then
  echo "FAIL: session-start refused a compositor named by WAYLAND_DISPLAY"
  fail=1
fi

# session-start succeeds when both halves' preconditions hold, and records
# a session pid.
reset
lxc_state=RUNNING
session_state=RUNNING
mksock "$tmp/xdg/wayland-0.sock"
out="$(run_init session-start 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "session-start with a RUNNING container and a socket"
if ! started_session; then
  echo "FAIL: session-start never spawned 'session start'"
  fail=1
fi
if [ ! -f "$session_pidfile" ]; then
  echo "FAIL: session-start recorded no session pidfile"
  fail=1
fi
if ! kill -0 "$(cat "$session_pidfile" 2>/dev/null)" 2>/dev/null; then
  echo "FAIL: the session pid session-start recorded is not alive"
  fail=1
fi

# session-start must fail, and name the session half, when the session
# daemon dies at once.
reset
lxc_state=RUNNING
session_state=STOPPED
session_mode=die
mksock "$tmp/xdg/wayland-0.sock"
out="$(run_init session-start 2>&1)" && rc=0 || rc=$?
check_rc 1 "$rc" "session-start with a session daemon that dies"
check_has "session half failed to come up"
if [ -e "$session_pidfile" ]; then
  echo "FAIL: session pidfile left behind after a failed session-start"
  fail=1
fi
if ! grep -qF -- 'session stop' "$calls" 2>/dev/null; then
  echo "FAIL: the failed session-start did not call 'session stop'"
  fail=1
fi

# ---------------------------------------------------------------------------
# session-stop on a live session pidfile: TERM through the pidfile, and
# the container half must be left alone.
reset
lxc_state=RUNNING
session_state=RUNNING
mksock "$tmp/xdg/wayland-0.sock"
run_init session-start >/dev/null 2>&1 || true
spid="$(cat "$session_pidfile" 2>/dev/null || true)"
out="$(run_init session-stop 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "session-stop on a live session pidfile"
if ! grep -qF -- "--pidfile $session_pidfile" "$calls" 2>/dev/null; then
  echo "FAIL: session-stop did not go through the session pidfile"
  fail=1
fi
if kill -0 "$spid" 2>/dev/null; then
  echo "FAIL: session-stop left the session daemon running"
  fail=1
fi
if grep -qF -- 'container stop' "$calls" 2>/dev/null; then
  echo "FAIL: session-stop touched the container half"
  fail=1
fi
if [ -e "$session_pidfile" ]; then
  echo "FAIL: session-stop left the session pidfile behind"
  fail=1
fi

# session-stop with only a stale session pidfile (the pid is dead): it must
# fall back to the manager, not report a dead pid as a stop.
reset
lxc_state=RUNNING
printf '999999\n' > "$session_pidfile"
out="$(run_init session-stop 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "session-stop with a stale session pidfile"
if ! grep -qF -- 'session stop' "$calls" 2>/dev/null; then
  echo "FAIL: session-stop with a stale pidfile did not call 'session stop'"
  fail=1
fi
if [ -e "$session_pidfile" ]; then
  echo "FAIL: the stale session pidfile survived session-stop"
  fail=1
fi

# ---------------------------------------------------------------------------
# stop tears the session down BEFORE the container.
reset
lxc_state=RUNNING
session_state=RUNNING
mksock "$tmp/xdg/wayland-0.sock"
run_init start >/dev/null 2>&1 || true
run_init session-start >/dev/null 2>&1 || true
spid="$(cat "$session_pidfile" 2>/dev/null || true)"
cpid="$(cat "$pidfile" 2>/dev/null || true)"
out="$(run_init stop 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "stop with both halves up"
if kill -0 "$spid" 2>/dev/null || kill -0 "$cpid" 2>/dev/null; then
  echo "FAIL: stop left a daemon of a half still running"
  fail=1
fi
# `stop` must send TERM through the SESSION pidfile first, and only then
# touch the container pidfile.
line_session="$(grep -nF -- "--stop --quiet --retry=TERM/20/KILL/5 --pidfile $session_pidfile" "$calls" | head -1 | cut -d: -f1 || true)"
line_container="$(grep -nF -- "--stop --quiet --retry=TERM/20/KILL/5 --pidfile $pidfile" "$calls" | head -1 | cut -d: -f1 || true)"
if [ -z "$line_session" ] || [ -z "$line_container" ]; then
  echo "FAIL: stop did not TERM both halves through their pidfiles"
  fail=1
elif [ "$line_session" -gt "$line_container" ]; then
  echo "FAIL: stop tore the container down before the session"
  fail=1
fi
if [ -e "$session_pidfile" ] || [ -e "$pidfile" ]; then
  echo "FAIL: stop left a pidfile behind"
  fail=1
fi

# ---------------------------------------------------------------------------
# status names both halves.
reset
lxc_state=STOPPED
out="$(run_init status 2>&1)" && rc=0 || rc=$?
check_rc 3 "$rc" "status with nothing running"
check_has "waydroid-container container is not running"
check_has "waydroid-container session is not running"

reset
lxc_state=RUNNING
run_init start >/dev/null 2>&1 || true
out="$(run_init status 2>&1)" && rc=0 || rc=$?
check_rc 1 "$rc" "status with the container up and no session"
check_has "waydroid-container container is running"
check_has "waydroid-container session is not running"
check_lacks "session is running (pid"

reset
lxc_state=RUNNING
session_state=RUNNING
mksock "$tmp/xdg/wayland-0.sock"
run_init start >/dev/null 2>&1 || true
run_init session-start >/dev/null 2>&1 || true
out="$(run_init status 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "status with both halves up"
check_has "waydroid-container container is running"
check_has "waydroid-container session is running"
out="$(run_init session-status 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "session-status with the session up"
check_has "waydroid-container session is running"

# ---------------------------------------------------------------------------
# The reboot case: /run is cleared, so both pidfiles are gone while the
# daemons survive. status must still name both halves as running, and
# session-stop must fall back to the manager instead of doing nothing.
reset
lxc_state=RUNNING
session_state=RUNNING
mksock "$tmp/xdg/wayland-0.sock"
run_init start >/dev/null 2>&1 || true
run_init session-start >/dev/null 2>&1 || true
rm -f "$pidfile" "$session_pidfile"
out="$(run_init status 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "status after a reboot (pidfiles gone, daemons up)"
check_has "waydroid-container container is running (pid"
check_has "no pidfile"
check_has "waydroid-container session is running (pid"
out="$(run_init session-stop 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "session-stop after a reboot"
if ! grep -qF -- 'session stop' "$calls" 2>/dev/null; then
  echo "FAIL: session-stop after a reboot did not fall back to 'session stop'"
  fail=1
fi

# The same reboot for the container half, on a node without the lxc tools:
# the state comes from `waydroid status`, and stop must still find the
# daemon by its command line.
reset
lxc_state=STOPPED
container_state=RUNNING
session_state=RUNNING
sandbox_bin="$nolxc"
mksock "$tmp/xdg/wayland-0.sock"
run_init start >/dev/null 2>&1 || true
run_init session-start >/dev/null 2>&1 || true
rm -f "$pidfile" "$session_pidfile"
out="$(run_init status 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "status after a reboot without the lxc tools"
check_has "waydroid-container container is running (pid"
out="$(run_init stop 2>&1)" && rc=0 || rc=$?
check_rc 0 "$rc" "stop after a reboot without the lxc tools"
if ! grep -qF -- 'container stop' "$calls" 2>/dev/null; then
  echo "FAIL: stop after a reboot did not fall back to 'container stop'"
  fail=1
fi

reap

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: waydroid-container owns the container -> session handover and reports both halves"
