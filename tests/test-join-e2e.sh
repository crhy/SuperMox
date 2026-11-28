#!/usr/bin/env bash
# Offline gate test for scripts/join-e2e.sh (c11).
#
# The live run boots a VM, which the gate never does. What the gate pins is the
# three things that made the live run lie about the join protocol:
#
#   1. every supermox-join call passes --no-corosync. The three "nodes" are
#      network namespaces of ONE VM, while corosync and pmxcfs are per-VM: one
#      /etc/corosync, one pmxcfs mount, one nodelist for the whole machine.
#      Measured in the test VM, without the flag the cluster step dies
#      ("pmxcfs keeps the cluster filesystem read-only until the cluster is
#      quorate") before create prints its 12 words, so nothing past step 6 runs.
#      A cluster whose secret nobody has is worse than no cluster.
#   2. the 12 words are taken out of create's output by their SHAPE, wherever
#      they are in it. `tail -n1` picked up the cluster step's last line, and
#      node-b was then told "join needs --words or --uri".
#   3. the run restores the VM's own /etc/supermox and /etc/wireguard through
#      an EXIT trap and stops what it started. Measured 2026-11-06: the run
#      left node-a's cluster in the test image, vm-lan-pair.sh built both LAN
#      VMs as overlays of that same rootfs.img, and smx-a then said "this node
#      already belongs to a cluster". One test must not change what the next
#      one means.
#
# Corosync itself is proven by scripts/lan-cluster-e2e.sh on two real VMs, and
# by tests/py/test_corosync_cluster.py; the words-first order is pinned in
# tests/py/test_join_cli.py.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
ok() { printf 'OK: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

e2e="scripts/join-e2e.sh"
cli="bin/supermox-join"
if [ ! -f "$e2e" ]; then
  bad "$e2e does not exist"
  printf 'FAIL: %d check(s) failed\n' "$fail"
  exit 1
fi

# --- 1. every call skips the cluster step ------------------------------------
# Backslash-continuations are joined first, or a call written over four lines
# is read as four lines and the flag on the last one is invisible.
joined="$(awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }' "$e2e")"

calls="$(printf '%s\n' "$joined" | grep -cE 'supermox-join" (create|join|conf)' || true)"
flagged="$(printf '%s\n' "$joined" | grep -E 'supermox-join" (create|join|conf)' \
  | grep -c -- '--no-corosync' || true)"
if [ "$calls" -eq 0 ]; then
  bad 'no supermox-join create/join/conf call found in join-e2e.sh'
elif [ "$calls" -ne "$flagged" ]; then
  bad "only $flagged of $calls supermox-join calls pass --no-corosync"
else
  ok "all $calls supermox-join calls pass --no-corosync"
fi
for sub in create join conf; do
  n="$(printf '%s\n' "$joined" | grep -cE "supermox-join\" $sub" || true)"
  if [ "$n" -eq 0 ]; then
    bad "join-e2e.sh never calls supermox-join $sub"
  fi
done

# The reason has to be in the file, not only in this test: a reader of join-e2e
# who sees --no-corosync everywhere will otherwise be tempted to remove it.
head_lines="$(head -n 40 "$e2e")"
if printf '%s\n' "$head_lines" | grep -qiE 'corosync'; then
  ok 'join-e2e.sh explains in its header why it skips the cluster step'
else
  bad 'join-e2e.sh header does not mention corosync'
fi

# --- 2. the phrase is found by shape, not by position -----------------------
if printf '%s\n' "$joined" | grep -qE 'supermox-join" create.*\|[[:space:]]*tail'; then
  bad 'join-e2e.sh still pipes create through tail'
fi
if printf '%s\n' "$joined" | grep -qE 'NF == 12'; then
  ok 'the 12 words are picked out of create output by their shape'
else
  bad 'join-e2e.sh has no shape-based 12-word parser'
fi

# --- 3. what the run changes, it puts back -----------------------------------
if printf '%s\n' "$joined" | grep -qE 'trap [a-z_A-Z]+ EXIT'; then
  ok 'join-e2e.sh installs an EXIT trap'
else
  bad 'join-e2e.sh has no EXIT trap; a FAIL mid-run would leave a cluster behind'
fi
for pat in 'supermox-joind stop' 'supermox-wg stop' 'ip netns del' 'tar -xzf'; do
  if printf '%s\n' "$joined" | grep -qF -- "$pat"; then
    :
  else
    bad "join-e2e.sh does not undo $pat"
  fi
done
ok 'the trap stops both daemons, removes the namespaces and restores the state dirs'

# The backup must be taken before the first write, or the restore puts back
# the mess this very run made.
backup_at="$(grep -n 'tar -czf' "$e2e" | head -n1 | cut -d: -f1)"
create_at="$(grep -n 'supermox-join" create' "$e2e" | head -n1 | cut -d: -f1)"
if [ -z "$backup_at" ] || [ -z "$create_at" ] || [ "$backup_at" -ge "$create_at" ]; then
  bad 'join-e2e.sh backs up the VM state after it already wrote to it'
fi
ok 'the VM state is backed up before join-e2e.sh writes anything'

# --- 4. create prints the words before the cluster step (c11 headline) ------
if [ ! -f "$cli" ]; then
  bad "$cli does not exist"
else
  block="$(awk '/^def cmd_create\(/{f=1;next} /^def /{f=0} f' "$cli")"
  phrase_at="$(printf '%s\n' "$block" | grep -nF 'print(phrase)' | head -n1 | cut -d: -f1)"
  step_at="$(printf '%s\n' "$block" | grep -nF '_ensure_cluster' | head -n1 | cut -d: -f1)"
  if [ -z "$phrase_at" ] || [ -z "$step_at" ] || [ "$phrase_at" -ge "$step_at" ]; then
    bad 'cmd_create prints the 12 words after the cluster step, not before it'
  else
    ok 'cmd_create prints the 12 words before the cluster step runs'
  fi
  if printf '%s\n' "$block" | grep -qF 'no_corosync'; then
    ok 'cmd_create honours --no-corosync'
  else
    bad 'cmd_create ignores --no-corosync'
  fi
fi

if [ "$fail" -ne 0 ]; then
  printf 'FAIL: %d check(s) failed\n' "$fail"
  exit 1
fi
echo "All join-e2e checks passed."
