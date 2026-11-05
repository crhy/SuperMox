#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# f10d-2: init.d/supermox-joind must not report a successful start on a node
# that has no cluster. The daemon refuses to run there (src/supermox/joind.py
# main: NodeState.load() false), so a start that reports success leaves a
# pidfile for a process that already exited and hides the reason, because an
# init script's stderr is /dev/null at boot.
#
# Stubs: JOIND_BIN is a script that records its invocation and sleeps, so
# start-stop-daemon has a real process to record; JOIND_LOGPIPE is a stub that
# logs the tag it was given and execs the rest, which pins that the daemon's
# stderr is routed through supermox-logpipe without needing /run or syslog.
# The cluster test itself is the real one: PYTHONPATH points at src/ and
# SUPERMOX_ETC at a temp state dir, so "no cluster" and "cluster here" are
# exactly the states the daemon distinguishes.

# start-stop-daemon is called by name, in the init script and through the logpipe
# stub, exactly as the other 23 init scripts here call it: sysvinit runs init
# scripts with /usr/sbin and /sbin on PATH, a non-login shell (cron, an
# unattended upgrade, some CI runners) does not. Pin the environment the script
# is written for rather than inherit whatever shell runs the gate, and keep the
# real start-stop-daemon: --make-pidfile, --exec and --remove-pidfile are the
# options this test is about, so a stub would test the stub.
PATH="$PATH:/usr/sbin:/sbin"
export PATH
if ! command -v start-stop-daemon >/dev/null 2>&1; then
  echo "FAIL: start-stop-daemon is not installed; this test needs the real one"
  exit 1
fi

root="$(pwd)/build/test-init-joind"
rm -rf "$root"
mkdir -p "$root/state" "$root/state-member" "$root/state-broken" "$root/bin"

# The cluster check in the init script imports the real package, so the test
# points PYTHONPATH at src/ once for every joind call.
export PYTHONPATH="$PWD/src"

stub="$root/bin/daemon"
cat > "$stub" <<'EOF'
#!/bin/sh
printf 'started\n' >> "$JOIND_STUB_LOG"
sleep 30
EOF
chmod +x "$stub"

logpipe="$root/bin/logpipe"
cat > "$logpipe" <<'EOF'
#!/bin/sh
printf 'logpipe %s\n' "$1" >> "$JOIND_LOGPIPE_LOG"
shift
exec "$@"
EOF
chmod +x "$logpipe"

stub_log="$root/daemon-started"
logpipe_log="$root/logpipe-calls"
pidfile="$root/joind.pid"

cleanup() {
  # The stub daemon sleeps; make sure it is gone even if the test bailed out
  # before its own `stop` step.
  if [ -e "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
  fi
  pkill -f "$stub" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

run_joind() {
  local action="$1" state_dir="$2" out rc
  out="$(SUPERMOX_ETC="$state_dir" \
    JOIND_BIN="$stub" JOIND_PIDFILE="$pidfile" \
    JOIND_LOGPIPE="$logpipe" JOIND_LOGPIPE_LOG="$logpipe_log" \
    JOIND_STUB_LOG="$stub_log" \
    sh init.d/supermox-joind "$action" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# 1. No cluster: start must exit 0, say why, and leave no pidfile and no
# daemon. Anything else reports a service that is not there as running.
out="$(run_joind start "$root/state")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: joind start on a standalone node exited $rc: $out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qF 'no cluster here'; then
  echo "FAIL: joind start on a standalone node gave no reason: $out"
  exit 1
fi
if [ -e "$pidfile" ]; then
  echo "FAIL: joind start left a pidfile for a daemon that never ran"
  exit 1
fi
if [ -e "$stub_log" ]; then
  echo "FAIL: joind start exec'd the daemon although there is no cluster"
  exit 1
fi
if run_joind status "$root/state" >/dev/null; then
  echo "FAIL: joind status reports running on a standalone node"
  exit 1
fi
echo "OK: joind start on a standalone node: rc 0, reason printed, no pidfile, no daemon"

# 2. Stopping a service that never started is not an error.
if ! run_joind stop "$root/state" >/dev/null; then
  echo "FAIL: joind stop failed when nothing was running"
  exit 1
fi
echo "OK: joind stop with no pidfile exits 0"

# 3. A cluster member: the daemon must actually be started, through the
# logpipe wrapper, and status/stop must follow the pidfile.
SUPERMOX_ETC="$root/state-member" PYTHONPATH="$PWD/src" python3 - <<'EOF'
from supermox import secret, state
st = state.NodeState()
st.create_cluster(secret.generate(), "node1", ["127.0.0.1:8743"])
st.save()
EOF

out="$(run_joind start "$root/state-member")" || true
if [ ! -e "$stub_log" ]; then
  echo "FAIL: joind start on a cluster member did not exec the daemon: $out"
  exit 1
fi
if [ ! -e "$pidfile" ]; then
  echo "FAIL: joind start on a cluster member wrote no pidfile"
  exit 1
fi
if [ ! -e "$logpipe_log" ] || ! grep -q '^logpipe supermox-joind$' "$logpipe_log"; then
  echo "FAIL: the daemon was not started through supermox-logpipe"
  exit 1
fi
if ! run_joind status "$root/state-member" >/dev/null; then
  echo "FAIL: joind status does not report the running daemon"
  exit 1
fi
if ! run_joind stop "$root/state-member" >/dev/null; then
  echo "FAIL: joind stop failed on a running daemon"
  exit 1
fi
if [ -e "$pidfile" ]; then
  echo "FAIL: joind stop left the pidfile behind"
  exit 1
fi
if run_joind status "$root/state-member" >/dev/null; then
  echo "FAIL: joind status still reports running after stop"
  exit 1
fi
echo "OK: joind on a cluster member: daemon started via supermox-logpipe, status and stop follow the pidfile"

# 4. A probe that cannot answer must not keep a cluster member without its
# join daemon: the check is a convenience, the daemon's own guard is the backstop.
printf 'not json\n' > "$root/state-broken/cluster.keys"
chmod 0600 "$root/state-broken/cluster.keys"
rm -f "$stub_log"
out="$(run_joind start "$root/state-broken")" || true
if [ ! -e "$stub_log" ]; then
  echo "FAIL: joind start skipped the daemon on state it could not read: $out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qF 'cluster check failed'; then
  echo "FAIL: joind start did not report the failed check: $out"
  exit 1
fi
run_joind stop "$root/state-member" >/dev/null 2>&1 || true

if ! SUPERMOX_ETC="$root/state-member" JOIND_BIN="$stub" JOIND_PIDFILE="$pidfile" \
   JOIND_LOGPIPE="$logpipe" JOIND_LOGPIPE_LOG="$logpipe_log" \
   JOIND_STUB_LOG="$stub_log" JOIND_PYTHON=/bin/false \
   sh init.d/supermox-joind start >/dev/null 2>&1; then
  echo "FAIL: joind start failed when the probe could not run"
  exit 1
fi
run_joind stop "$root/state-member" >/dev/null 2>&1 || true
echo "OK: a cluster check that cannot answer starts the daemon anyway and says so"

exit 0
