#!/usr/bin/env bash
# Behavioural test for init.d/pve-cluster (task c04: pmxcfs daemonises itself
# and leaves no usable pidfile, so the old script's stop killed nothing, its
# status said "not running" while pmxcfs ran, and its restart started a SECOND
# pmxcfs on one FUSE mount -- every read of /etc/pve then blocks. PVE's own
# finish_join calls PVE::SysvService::stop('pve-cluster'), so cluster join is
# blocked until stop/start/status are correct.)
#
# What this guards:
#   * `start` twice starts pmxcfs exactly once and leaves exactly one running;
#   * `start` writes the pidfile with the daemon's pid once /etc/pve is mounted;
#   * `stop` with NO pidfile but a running pmxcfs stops it and exits 0;
#   * `stop` when nothing runs exits 0 (SysvService::stop must not die);
#   * `stop` clears a stale fuse mount, but never unmounts under a live pmxcfs;
#   * `stop` removes the pidfile;
#   * `status` is LSB 0 only when pmxcfs runs AND /etc/pve is mounted, LSB 3
#     when it does not run and also when it runs with the mount gone;
#   * `restart` leaves exactly one pmxcfs and one start;
#   * the storage.cfg seeding from f24 still runs (empty file seeded, a
#     populated file never touched);
#   * corosync is started before pmxcfs.
#
# pmxcfs, findmnt, umount, start-stop-daemon and the logpipe wrapper are stubs
# on PATH under build/; no root, no fuse, no real /etc/pve, no real pmxcfs.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/pve-cluster"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-init-pve-cluster.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/etc/pve" "$tmp/var/lib/corosync" "$tmp/run/corosync"

# --- stub pmxcfs: like the real one, the foreground process exits and a
# detached child keeps running; the child is what pidof must find. ----------
cat > "$tmp/bin/pmxcfs" <<'EOF'
#!/bin/sh
if [ "${PMX_CHILD:-}" = "1" ]; then
  while :; do sleep 1; done
fi
PMX_CHILD=1 "$0" >/dev/null 2>&1 &
exit 0
EOF

# --- stub start-stop-daemon: --start always runs the --exec program (the
# real one does too), --stop kills what pidof finds for it, TERM then KILL.
cat > "$tmp/bin/start-stop-daemon" <<'EOF'
#!/bin/sh
mode=""
exec_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --start | --stop | --status)
      mode="${1#--}"
      shift
      ;;
    --exec)
      exec_path="$2"
      shift 2
      ;;
    --retry) shift 2 ;;
    --pidfile | --quiet | --background | --okpid) shift ;;
    *) shift ;;
  esac
done

pids="$(pidof -x "$exec_path" 2>/dev/null || true)"
case "$mode" in
  start)
    printf 'start\n' >> "${PMX_STATE:?}/starts"
    "$exec_path" >/dev/null 2>&1 &
    exit 0
    ;;
  stop)
    [ -n "$pids" ] || exit 1
    if [ "${PMX_NO_KILL:-}" = "1" ]; then
      exit 1
    fi
    kill $pids 2>/dev/null
    i=0
    while [ "$i" -lt 20 ]; do
      pids="$(pidof -x "$exec_path" 2>/dev/null || true)"
      [ -n "$pids" ] || break
      sleep 0.1
      i=$((i + 1))
    done
    if [ -n "$pids" ]; then
      kill -9 $pids 2>/dev/null
      sleep 0.2
    fi
    exit 0
    ;;
  status)
    [ -n "$pids" ] || exit 3
    exit 0
    ;;
esac
exit 0
EOF

# --- stub findmnt: mounted iff the state file says so. -----------------------
cat > "$tmp/bin/findmnt" <<'EOF'
#!/bin/sh
[ -f "${PMX_STATE:?}/mounted" ]
EOF

# --- stub umount: records that the script asked for it. ---------------------
cat > "$tmp/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount\n' >> "${PMX_STATE:?}/actions"
EOF

# --- logpipe wrapper: drop the tag, run the command. ------------------------
cat > "$tmp/bin/supermox-logpipe" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF

# --- corosync stub: records that it was started. ---------------------------
cat > "$tmp/bin/corosync-init" <<'EOF'
#!/bin/sh
printf 'corosync\n' >> "${PMX_STATE:?}/actions"
EOF

chmod +x "$tmp/bin/pmxcfs" "$tmp/bin/start-stop-daemon" "$tmp/bin/findmnt" \
  "$tmp/bin/umount" "$tmp/bin/supermox-logpipe" "$tmp/bin/corosync-init"

export PMX_STATE="$tmp/state"
export PATH="$tmp/bin:$PATH"
export DAEMON="$tmp/bin/pmxcfs"
export PIDFILE="$tmp/run/pve-cluster.pid"
export PVE_DIR="$tmp/etc/pve"
export COROSYNC_STATE_DIR="$tmp/var/lib/corosync"
export COROSYNC_RUN_DIR="$tmp/run/corosync"
export COROSYNC_SCRIPT="$tmp/bin/corosync-init"
export LOGPIPE="$tmp/bin/supermox-logpipe"

fail=0

running() { pidof -x "$DAEMON" 2>/dev/null || true; }
nrunning() { local p; p="$(running)"; [ -z "$p" ] && { echo 0; return; }; echo "$(echo "$p" | wc -w)"; }
mount_on() { touch "$PMX_STATE/mounted"; }
mount_off() { rm -f "$PMX_STATE/mounted"; }
starts() { [ -f "$PMX_STATE/starts" ] && wc -l < "$PMX_STATE/starts" || echo 0; }
actions() { [ -f "$PMX_STATE/actions" ] && cat "$PMX_STATE/actions" || true; }

run() {
  local rc=0
  sh "$src" "$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

reset() {
  local p
  p="$(running)"
  for p in $p; do kill -9 "$p" 2>/dev/null || true; done
  rm -f "$PMX_STATE/mounted" "$PMX_STATE/starts" "$PMX_STATE/actions" "$PIDFILE"
  rm -f "$PVE_DIR/storage.cfg"
}

# --- case 1: start twice -> pmxcfs started exactly once, one process -------
reset
mount_on
rc="$(run start)"
if [ "$rc" != 0 ]; then
  echo "FAIL: first start exited $rc, expected 0"
  fail=1
fi
if [ "$(starts)" != 1 ]; then
  echo "FAIL: pmxcfs started $(starts) times by one start, expected 1"
  fail=1
fi
if [ "$(nrunning)" != 1 ]; then
  echo "FAIL: $(nrunning) pmxcfs processes after the first start, expected 1"
  fail=1
fi
if [ ! -f "$PIDFILE" ]; then
  echo "FAIL: start wrote no pidfile; stop and status cannot find the daemon"
  fail=1
fi
pid_in_file="$(cat "$PIDFILE")"
if [ "$pid_in_file" != "$(running)" ]; then
  echo "FAIL: pidfile holds '$pid_in_file', the running pmxcfs is '$(running)'"
  fail=1
fi
rc="$(run start)"
if [ "$rc" != 0 ]; then
  echo "FAIL: starting an already running service exited $rc, expected LSB 0"
  fail=1
fi
if [ "$(starts)" != 1 ]; then
  echo "FAIL: second start started a SECOND pmxcfs (starts=$(starts)); two pmxcfs on one mount wedges /etc/pve"
  fail=1
fi
if [ "$(nrunning)" != 1 ]; then
  echo "FAIL: $(nrunning) pmxcfs processes after two starts, expected 1"
  fail=1
fi
if ! grep -q '^corosync$' <<<"$(actions)"; then
  echo "FAIL: start did not start corosync, pmxcfs needs it running first"
  fail=1
fi

# --- case 2: status is LSB 0 while running and mounted ---------------------
if [ "$(run status)" != 0 ]; then
  echo "FAIL: status exited non-zero while pmxcfs runs and /etc/pve is mounted"
  fail=1
fi

# --- case 3: status is LSB 3 when pmxcfs runs but the mount is gone -------
mount_off
rc="$(run status)"
if [ "$rc" != 3 ]; then
  echo "FAIL: status exit code is $rc with a live pmxcfs and no mount, expected LSB 3"
  fail=1
fi
mount_on

# --- case 4: stop with no pidfile but a running pmxcfs -> stopped, rc 0 ---
rm -f "$PIDFILE"
rc="$(run stop)"
if [ "$rc" != 0 ]; then
  echo "FAIL: stop exited $rc with a running pmxcfs and no pidfile, expected 0"
  fail=1
fi
if [ -n "$(running)" ]; then
  echo "FAIL: stop left pmxcfs running: $(running)"
  fail=1
fi
if [ -e "$PIDFILE" ]; then
  echo "FAIL: stop left a pidfile behind"
  fail=1
fi

# --- case 5: stop again (nothing running) is still LSB 0 ------------------
rc="$(run stop)"
if [ "$rc" != 0 ]; then
  echo "FAIL: stop with nothing running exited $rc; PVE::SysvService::stop would die on it"
  fail=1
fi

# --- case 6: stop never unmounts under a live pmxcfs, clears a stale one --
reset
mount_on
if [ "$(run start)" != 0 ]; then
  echo "FAIL: start for the mount cases exited non-zero"
  fail=1
fi
# A daemon that survives TERM/KILL: stop must report failure and must NOT
# unmount /etc/pve from under a pmxcfs that is still running.
rc="$(PMX_NO_KILL=1 run stop)"
if [ "$rc" != 1 ]; then
  echo "FAIL: stop exited $rc while pmxcfs survived TERM/KILL, expected 1"
  fail=1
fi
if grep -q '^umount$' <<<"$(actions)"; then
  echo "FAIL: stop unmounted /etc/pve while pmxcfs was still running"
  fail=1
fi
# Now the daemon is gone but the mount is left behind: stop must clear it.
for p in $(running); do kill -9 "$p" 2>/dev/null || true; done
sleep 0.3
if [ "$(run stop)" != 0 ]; then
  echo "FAIL: stop exited non-zero in the stale-mount case"
  fail=1
fi
if ! grep -q '^umount$' <<<"$(actions)"; then
  echo "FAIL: stop did not clear the stale fuse mount; every later read of /etc/pve blocks"
  fail=1
fi

# --- case 7: restart leaves exactly one pmxcfs and one extra start -------
reset
mount_on
if [ "$(run start)" != 0 ]; then
  echo "FAIL: start before restart exited non-zero"
  fail=1
fi
before="$(starts)"
if [ "$(run restart)" != 0 ]; then
  echo "FAIL: restart exited non-zero"
  fail=1
fi
if [ "$(starts)" != "$((before + 1))" ]; then
  echo "FAIL: restart produced $(( $(starts) - before )) new pmxcfs, expected exactly 1"
  fail=1
fi
if [ "$(nrunning)" != 1 ]; then
  echo "FAIL: $(nrunning) pmxcfs processes after restart, expected 1"
  fail=1
fi
if [ "$(run status)" != 0 ]; then
  echo "FAIL: status is not LSB 0 after a restart"
  fail=1
fi

# --- case 8: status LSB 3 when nothing runs --------------------------------
reset
mount_on
if [ "$(run status)" != 3 ]; then
  echo "FAIL: status exit code is not LSB 3 with no pmxcfs running"
  fail=1
fi

# --- case 9: storage.cfg seeding still works (f24 behaviour) ---------------
reset
mount_on
if [ "$(run start)" != 0 ]; then
  echo "FAIL: start for the storage.cfg case exited non-zero"
  fail=1
fi
if [ ! -s "$PVE_DIR/storage.cfg" ]; then
  echo "FAIL: start did not seed an empty storage.cfg; pct create and the web UI then fail"
  fail=1
fi
if ! grep -q 'dir: local' "$PVE_DIR/storage.cfg"; then
  echo "FAIL: seeded storage.cfg has no 'dir: local' stanza"
  fail=1
fi
printf 'dir: other\n path /srv/other\n' > "$PVE_DIR/storage.cfg"
if [ "$(run restart)" != 0 ]; then
  echo "FAIL: restart over an existing storage.cfg exited non-zero"
  fail=1
fi
if [ "$(cat "$PVE_DIR/storage.cfg")" != "dir: other
 path /srv/other" ]; then
  echo "FAIL: an existing storage.cfg was overwritten"
  fail=1
fi

# --- case 10: an unknown action is a usage error --------------------------
rc="$(run bogus)"
if [ "$rc" = 0 ]; then
  echo "FAIL: unknown action exited 0"
  fail=1
fi

# --- case 11: the LSB header still orders this after corosync -------------
if ! grep -qE '^# Required-Start:.*corosync supermox-corosync' "$src"; then
  echo "FAIL: LSB header no longer requires corosync supermox-corosync"
  fail=1
fi

# --- cleanup: no stub pmxcfs may outlive this test ------------------------
leftover="$(running)"
if [ -n "$leftover" ]; then
  for p in $leftover; do kill -9 "$p" 2>/dev/null || true; done
fi
sleep 0.2
if [ -n "$(running)" ]; then
  echo "FAIL: stub pmxcfs processes still running after cleanup"
  fail=1
fi

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/pve-cluster starts pmxcfs once, stops it by executable, reports LSB 0/3 correctly and never leaves a second pmxcfs or a stale /etc/pve mount behind"
