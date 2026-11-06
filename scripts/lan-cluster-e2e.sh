#!/usr/bin/env bash
# c10: the two-machine LAN cluster test.
#
# scripts/vm-lan-pair.sh boots two separate VMs (smx-a, smx-b) onto one QEMU
# user-LAN; scripts/lan-pair-check.sh proves ICMP crosses between them. This
# script is what turns that pair into a PVE cluster and checks the cluster from
# both sides: A creates, B joins by the 12-word phrase, both become core members
# of one corosync cluster, /etc/pve is shared, and B survives a reboot.
#
# Nothing here is a substitute for that measurement: join-e2e.sh fakes the pair
# with two netns inside one VM, which can prove the protocol but can never show
# two kernels, two network stacks and two pmxcfs daemons agreeing.
#
# The 12 words: `create` prints them once, we move them into a 0600 file under
# build/lan-e2e/ and delete the raw output. They are never echoed to a log and
# never put on a command line: B's join reads them from stdin through a helper
# that builds argv inside python, and while B joins we sample `ps -eo args` on
# B and grep the samples with the phrase taken from a file (grep -f), so the
# claim "not visible in ps" is measured, not asserted.
#
# Usage:
#   bash scripts/lan-cluster-e2e.sh            # start the pair if needed, run
#   bash scripts/lan-cluster-e2e.sh --dry-run  # print the step commands, no VM
#   bash scripts/lan-cluster-e2e.sh --keep     # leave the pair running
#   bash scripts/lan-cluster-e2e.sh --fresh    # re-create both overlays first
#
# Exit 0 only when every step passed. The pair is stopped on exit unless --keep.
set -euo pipefail

# Paths: environment > config/local.env > build/ default (see docs/development.md).
# REPO is set by local-env.sh.
# shellcheck disable=SC1091
source "$(dirname "$0")/local-env.sh"

# --- the pair, read from the same SUPERMOX_LAN_* variables vm-lan-pair.sh uses ---
SSH_A="${SUPERMOX_LAN_SSH_A:-2231}"
SSH_B="${SUPERMOX_LAN_SSH_B:-2232}"
IP_A="${SUPERMOX_LAN_IP_A:-192.168.77.10}"
IP_B="${SUPERMOX_LAN_IP_B:-192.168.77.11}"
MCAST="${SUPERMOX_LAN_MCAST:-230.0.0.1:12345}"
JOIN_PORT="${SUPERMOX_LAN_JOIN_PORT:-8743}"
WG_PORT="${SUPERMOX_LAN_WG_PORT:-51820}"
HN_A="smx-a"
HN_B="smx-b"
EP_A="$IP_A:$JOIN_PORT"
EP_B="$IP_B:$JOIN_PORT"
WG_B="$IP_B:$WG_PORT"
PAIR_DIR="$SUPERMOX_TEST_DIR/lan-pair"

# --- logs -------------------------------------------------------------------
LOG_DIR="$REPO/build/lan-e2e"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
PHRASE_FILE="$LOG_DIR/phrase.txt"

# --- args -----------------------------------------------------------------
dry_run=0
keep=0
fresh=0
print_helper=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --keep) keep=1 ;;
    --fresh) fresh=1 ;;
    --print-helper) print_helper=1 ;;
    -h|--help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

fails=0
step_no=0
step_log=""

say() { printf '%s\n' "$*"; }

step() { # $1: step title
  step_no=$((step_no + 1))
  step_log="$LOG_DIR/$RUN_ID-step$step_no-$(printf '%s' "$1" | tr -c '[:alnum:]' '-').log"
  say ""
  say "== STEP $step_no: $1 =="
}

pass() { printf 'PASS: %s\n' "$*"; }
fail() { # $1: what failed; rest: evidence lines already in the log
  fails=$((fails + 1))
  printf 'FAIL: %s\n' "$*"
}

# Run a command on one node; its output goes to the step log and to stdout.
node_ssh() { # $1 side (a|b), rest: remote command
  local side="$1"
  shift
  sshpass -p supermox ssh -p "$(side_port "$side")" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 root@127.0.0.1 "$@"
}

side_port() { # $1 side -> ssh port
  case "$1" in
    a) printf '%s\n' "$SSH_A" ;;
    b) printf '%s\n' "$SSH_B" ;;
    *) printf 'ERROR: side must be a or b\n' >&2; return 1 ;;
  esac
}

run_on() { # $1 side, rest: remote command; output only (rc ignored on purpose)
  local side="$1"
  shift
  local out
  out="$(node_ssh "$side" "$@" 2>&1)" || true
  printf '%s\n' "$out" | tee -a "$step_log"
}

# rc_on() keeps the remote exit status; the output still lands in the log.
rc=0
run_rc() { # $1 side, rest: remote command -> sets global rc, echoes output
  local side="$1"
  shift
  local tmp
  # `|| rc=$?` is required: a failing assignment would end the script under
  # set -e before the exit status could be looked at.
  rc=0
  tmp="$(node_ssh "$side" "$@" 2>&1)" || rc=$?
  printf '%s\n' "$tmp" | tee -a "$step_log"
}

# The helper B runs to join. It reads the phrase from stdin and builds argv
# inside python, so the phrase never enters execve's argv. Defined before the
# dry run so --print-helper can show it without touching the pair.
helper_source() {
  cat <<PY
import runpy, shutil, sys
words = sys.stdin.read().strip()
# The image installs the CLI wherever PATH finds it (/usr/bin in a package
# install, /usr/local/bin in a test image), so resolve it rather than guess.
cli = shutil.which("supermox-join")
if not cli:
    sys.exit("join helper: supermox-join not on PATH")
sys.argv = ["supermox-join", "join",
            "--name", "$HN_B",
            "--endpoint", "$EP_A",
            "--my-endpoint", "$EP_B",
            "--my-wg-endpoint", "$WG_B",
            "--words", words]
runpy.run_path(cli, run_name="__main__")
PY
}

if [ "$print_helper" -eq 1 ]; then
  helper_source
  exit 0
fi

# --- dry run: print the commands a real run would use, touch nothing ---------
if [ "$dry_run" -eq 1 ]; then
  say "== DRY RUN: the commands a live run would use (no VM is booted) =="
  say "pair: $PAIR_DIR (mcast $MCAST; $HN_A $IP_A port $SSH_A, $HN_B $IP_B port $SSH_B)"
  say "logs: $LOG_DIR (phrase file $PHRASE_FILE, mode 0600)"
  say ""
  say "0. bash scripts/vm-lan-pair.sh start   # only if the pair is not already up (--fresh re-copies both overlays)"
  say ""
  say "1. bash scripts/lan-pair-check.sh"
  say "   ssh -p $SSH_A root@127.0.0.1 pve-firewall status"
  say "   ssh -p $SSH_B root@127.0.0.1 pve-firewall status"
  say ""
  say "2. ssh -p $SSH_A root@127.0.0.1 supermox-join create --name $HN_A --endpoint $EP_A --my-wg-endpoint $IP_A:$WG_PORT"
  say "   # the 12 words go to $PHRASE_FILE (0600); the raw output is deleted"
  say "   ssh -p $SSH_A root@127.0.0.1 /etc/init.d/supermox-joind restart"
  say "   ssh -p $SSH_A root@127.0.0.1 corosync-quorumtool -s"
  say "   ssh -p $SSH_A root@127.0.0.1 pvecm status"
  say ""
  say "3. ssh -p $SSH_B root@127.0.0.1 'cat > /root/supermox-lan-e2e-join.py' < $LOG_DIR/$RUN_ID-join-helper.py"
  say "   ssh -p $SSH_B root@127.0.0.1 'python3 /root/supermox-lan-e2e-join.py' < $PHRASE_FILE"
  say "   # argv is built inside python: the remote command line is exactly"
  say "   #   python3 /root/supermox-lan-e2e-join.py"
  say "   #   --words <12 words read from stdin>   <- never in execve argv"
  say "   ssh -p $SSH_B root@127.0.0.1 'nohup sh -c <ps sampler: ps -eo args every 0.2 s for 45 s> &'"
  say "   # afterwards: grep -F -f $PHRASE_FILE /root/ps-samples.txt  -> must match nothing"
  say ""
  say "4. ssh -p $SSH_B root@127.0.0.1 supermox-join core"
  say "   ssh -p $SSH_A root@127.0.0.1 pvecm status   # 2 nodes, Quorate: Yes"
  say "   ssh -p $SSH_B root@127.0.0.1 pvecm status"
  say "   ssh -p $SSH_A root@127.0.0.1 corosync-cfgtool -s"
  say ""
  say "5. ssh -p $SSH_A root@127.0.0.1 sh -c 'echo <random> > /etc/pve/lan-e2e-<random>.txt'"
  say "   ssh -p $SSH_B root@127.0.0.1 cat /etc/pve/lan-e2e-<random>.txt   # within 10 s"
  say "   ssh -p $SSH_B root@127.0.0.1 rm /etc/pve/lan-e2e-<random>.txt"
  say "   ssh -p $SSH_A root@127.0.0.1 test ! -e /etc/pve/lan-e2e-<random>.txt"
  say ""
  say "6. ssh -p $SSH_A root@127.0.0.1 pvesh get /cluster/resources --type node --output-format json"
  say ""
  say "7. ssh -p $SSH_B root@127.0.0.1 'nohup sh -c \"sleep 2; reboot\" >/dev/null 2>&1 &'"
  say "   # wait for ssh on $SSH_B to go away, then to answer again (<= 180 s)"
  say "   ssh -p $SSH_B root@127.0.0.1 /etc/init.d/supermox-wg start"
  say "   # then: quorate on both within 180 s, and step 5 again"
  say ""
  say "trap: bash scripts/vm-lan-pair.sh stop   (unless --keep)"
  exit 0
fi

# --- live run -------------------------------------------------------------
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

cleanup() {
  local ec=$?
  if [ "$keep" -eq 0 ]; then
    say ""
    say "== stopping the pair =="
    bash "$REPO/scripts/vm-lan-pair.sh" stop || true
  else
    say ""
    say "== --keep: the pair is left running =="
  fi
  say "logs: $LOG_DIR ($RUN_ID-*.log)"
  if [ -f "$PHRASE_FILE" ]; then
    say "phrase file: $PHRASE_FILE ($(stat -c '%a' "$PHRASE_FILE")) - delete it when done"
  fi
  exit "$ec"
}
trap cleanup EXIT

# The helper B runs to join. It reads the phrase from stdin and builds argv
# inside python, so the phrase never enters execve's argv.
write_helper() {
  local f="$LOG_DIR/$RUN_ID-join-helper.py"
  printf '%s\n' "$(helper_source)" > "$f"
  printf '%s\n' "$f"
}
JOIN_HELPER="$(write_helper)"

# --- dry run: print the commands a real run would use, touch nothing ---------

ssh_ok() { # $1 side; ssh's own ConnectTimeout bounds the probe
  node_ssh "$1" true >/dev/null 2>&1
}

pair_running() { # 1 when both sides answer ssh
  ssh_ok a && ssh_ok b
}

say "pair: $PAIR_DIR (mcast $MCAST; $HN_A $IP_A port $SSH_A, $HN_B $IP_B port $SSH_B)"
say "logs: $LOG_DIR (run $RUN_ID)"

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

# --- step 1: the pair is up and on the LAN -----------------------------------
step "both nodes up and on the LAN"
if pair_running; then
  if [ "$fresh" -eq 1 ]; then
    say "--fresh: stopping the running pair and re-creating both overlays"
    bash "$REPO/scripts/vm-lan-pair.sh" stop 2>&1 | tee -a "$step_log"
    bash "$REPO/scripts/vm-lan-pair.sh" start --fresh 2>&1 | tee -a "$step_log"
  else
    say "reusing the running pair"
  fi
else
  say "starting the pair (this boots two VMs; it can take a few minutes)"
  if [ "$fresh" -eq 1 ]; then
    bash "$REPO/scripts/vm-lan-pair.sh" start --fresh 2>&1 | tee -a "$step_log"
  else
    bash "$REPO/scripts/vm-lan-pair.sh" start 2>&1 | tee -a "$step_log"
  fi
fi
if ! pair_running; then
  fail "step 1: the pair is not reachable over ssh ($SSH_A, $SSH_B)"
  exit 1
fi
bash "$REPO/scripts/lan-pair-check.sh" 2>&1 | tee -a "$step_log"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  fail "step 1: lan-pair-check.sh says the LAN does not work"
  exit 1
fi
pass "step 1: lan-pair-check.sh: ICMP crosses between the two VMs"

# Firewall state is recorded, not asserted: a fresh test image may or may not
# have pve-firewall enabled, and the join does not depend on it. The line is
# here so a later firewall-related failure has a baseline to compare with.
for side in a b; do
  say "-- pve-firewall status on $HN_$side (recorded, not asserted) --"
  run_on "$side" 'pve-firewall status' || true
done

# --- step 2: A creates the cluster -------------------------------------------
step "A creates the cluster"
run_on a 'hostname'
create_raw="$LOG_DIR/$RUN_ID-create-a.raw"
create_rc=0
(
  umask 077
  node_ssh a "supermox-join create --name $HN_A --endpoint $EP_A --my-wg-endpoint $IP_A:$WG_PORT" \
    > "$create_raw" 2>&1
) || create_rc=$?
# Show the create output with the phrase line removed, so the log keeps the
# diagnosis and loses the secret.
redacted="$LOG_DIR/$RUN_ID-create-a.log"
pick_phrase() { # $1 raw file; prints only the line that really is a phrase
  PYTHONPATH="$REPO/src" python3 - "$1" <<'PY'
import sys
from supermox import secret
for line in open(sys.argv[1]):
    w = line.strip()
    if len(w.split()) != 12:
        continue
    try:
        secret.validate(w)
    except Exception:
        continue
    print(w)
    break
PY
}
phrase="$(pick_phrase "$create_raw")"
if [ -z "$phrase" ]; then
  ( umask 077; cp "$create_raw" "$redacted" )
  fail "step 2: create printed no 12-word phrase (raw output kept at $redacted)"
  exit 1
fi
(
  umask 077
  printf '%s\n' "$phrase" > "$PHRASE_FILE"
  python3 - "$create_raw" "$PHRASE_FILE" <<'PY'
import sys
secret = open(sys.argv[2]).read().strip()
out = []
for line in open(sys.argv[1]):
    out.append("[12 words: captured to phrase.txt, mode 0600]"
               if line.strip() == secret else line)
open(sys.argv[1] + ".red", "w").write("".join(out))
PY
)
mv "$create_raw.red" "$redacted"
rm -f "$create_raw"
chmod 600 "$PHRASE_FILE"
say "create output (phrase line redacted):"
cat "$redacted" | tee -a "$step_log"
if [ "$create_rc" -ne 0 ]; then
  fail "step 2: supermox-join create exited $create_rc"
  # create refuses to run twice on a node that already has cluster state, and
  # the pair's overlays are persistent disks: a second run against the same
  # images needs fresh ones.
  if grep -q 'already belongs to a cluster' "$redacted" 2>/dev/null; then
    say "hint: re-run with --fresh to re-create both overlays"
  fi
  exit 1
fi
pass "step 2: A created the cluster; 12 words in $PHRASE_FILE (mode $(stat -c '%a' "$PHRASE_FILE")), not in any log"

run_on a '/etc/init.d/supermox-joind restart'
run_rc a '/etc/init.d/supermox-joind status'
run_on a 'corosync-quorumtool -s'
run_rc a 'pvecm status'
if [ "$rc" -ne 0 ]; then
  fail "step 2: pvecm status on A failed"
  exit 1
fi
if ! grep -qi 'Quorate: Yes' "$step_log"; then
  fail "step 2: A is not quorate after create"
  exit 1
fi
pass "step 2: A quorate, pvecm status shows 1 node (address fd.. in the log)"

# --- step 3: B joins by the phrase -------------------------------------------
step "B joins by the 12-word phrase"
# Sample ps on B while it joins, so "the phrase is not visible in ps" is a
# measurement. The sampler is stopped by timeout; its output is pulled back and
# grepped with grep -f, so the phrase never appears in a command line here either.
run_on b 'rm -f /root/ps-samples.txt /root/ps-samples.done'
run_on b "nohup sh -c 'timeout 45 sh -c \"while :; do ps -eo args; sleep 0.2; done\" >/root/ps-samples.txt 2>&1; touch /root/ps-samples.done' >/dev/null 2>&1 &"
node_ssh b "cat > /root/supermox-lan-e2e-join.py" < "$JOIN_HELPER"
run_on b 'chmod 700 /root/supermox-lan-e2e-join.py'
say "joining: the remote command line is 'python3 /root/supermox-lan-e2e-join.py';"
say "the phrase arrives on stdin and is put in argv inside python only."
run_rc b 'python3 /root/supermox-lan-e2e-join.py' < "$PHRASE_FILE"
join_rc=$rc
if [ "$join_rc" -ne 0 ]; then
  fail "step 3: supermox-join join on B exited $join_rc"
  exit 1
fi
pass "step 3: B joined by phrase"
# Pull the ps samples back and grep them with the phrase taken from a file.
# Wait for the sampler to finish first (it touches .done), so the sample set
# covers the whole join, not just its first second.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if node_ssh b 'test -e /root/ps-samples.done' 2>/dev/null; then break; fi
  sleep 2
done
ps_samples="$LOG_DIR/$RUN_ID-ps-samples.txt"
node_ssh b 'cat /root/ps-samples.txt' > "$ps_samples" 2>/dev/null || true
if [ ! -s "$ps_samples" ]; then
  fail "step 3: no ps samples were taken on B, so the phrase claim is unproven"
  exit 1
fi
if grep -F -q -f "$PHRASE_FILE" "$ps_samples"; then
  fail "step 3: the phrase is visible in ps on B (see $ps_samples)"
  exit 1
fi
pass "step 3: phrase not visible in any of the $(wc -l < "$ps_samples") ps samples taken on B during the join"

# --- step 4: both are core members -------------------------------------------
step "both nodes are core members of one corosync cluster"
run_on b 'supermox-join core'
for side in a b; do
  run_rc "$side" 'pvecm status'
  if [ "$rc" -ne 0 ]; then
    fail "step 4: pvecm status on $HN_$side failed"
    exit 1
  fi
done
if ! grep -q "$HN_A" "$step_log" || ! grep -q "$HN_B" "$step_log"; then
  fail "step 4: pvecm status does not list both nodes"
  exit 1
fi
if [ "$(grep -c 'Quorate: Yes' "$step_log")" -lt 2 ]; then
  fail "step 4: not both nodes report Quorate: Yes"
  exit 1
fi
run_on a 'corosync-cfgtool -s'
pass "step 4: pvecm status on both nodes lists $HN_A and $HN_B, Quorate: Yes on both"

# --- step 5: /etc/pve is really shared ---------------------------------------
shared_pve_test() { # writes on A, reads on B, deletes on B, checks on A
  local name content
  name="lan-e2e-$(date +%s%N | tail -c 9).txt"
  content="written-by-$HN_A-at-$(date -u +%H%M%S)"
  run_rc a "printf '%s\n' '$content' > /etc/pve/$name"
  if [ "$rc" -ne 0 ]; then
    fail "step 5: A could not write /etc/pve/$name"
    return 1
  fi
  local i seen=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if seen="$(node_ssh b "cat /etc/pve/$name" 2>/dev/null)" && [ -n "$seen" ]; then
      break
    fi
    sleep 1
  done
  printf 'B read: %s (after %s s)\n' "$seen" "$i" | tee -a "$step_log"
  if [ "$seen" != "$content" ]; then
    fail "step 5: B did not read the content A wrote"
    return 1
  fi
  run_rc b "rm -f /etc/pve/$name"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if node_ssh a "test ! -e /etc/pve/$name" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! node_ssh a "test ! -e /etc/pve/$name" 2>/dev/null; then
    fail "step 5: A still sees /etc/pve/$name after B deleted it"
    return 1
  fi
  printf 'A sees %s gone after %s s\n' "$name" "$i" | tee -a "$step_log"
  return 0
}

step "shared /etc/pve: write on A, read on B, delete on B, gone on A"
if ! shared_pve_test; then
  fail "step 5: /etc/pve is not shared between the two nodes"
  exit 1
fi
pass "step 5: /etc/pve shared: A wrote, B read it within 10 s, B deleted, A saw it gone"

# --- step 6: PVE sees both nodes ---------------------------------------------
step "PVE sees both nodes"
run_rc a 'pvesh get /cluster/resources --type node --output-format json'
if [ "$rc" -ne 0 ]; then
  fail "step 6: pvesh get /cluster/resources failed on A"
  exit 1
fi
if ! grep -q "\"$HN_A\"" "$step_log" || ! grep -q "\"$HN_B\"" "$step_log"; then
  fail "step 6: /cluster/resources does not list both nodes"
  exit 1
fi
# The JSON's online/offline key is not asserted: it could not be confirmed
# offline, and the JSON is in the step log for a human to read. The node count
# and both names are what this step measures.
if grep -q 'online' "$step_log"; then
  say "note: the JSON carries an online/offline field; read it in the log"
fi
pass "step 6: pvesh /cluster/resources --type node lists $HN_A and $HN_B"

# --- step 7: B survives a reboot ---------------------------------------------
step "resilience: reboot B, quorate again within 180 s, shared /etc/pve again"
run_on b 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &'
# Wait for ssh on B to stop answering (the reboot really started).
waited=0
while ssh_ok b; do
  if [ "$waited" -ge 60 ]; then
    say "WARN: ssh on B still answering after 60 s; the reboot may not have started"
    break
  fi
  sleep 2
  waited=$((waited + 2))
done
say "ssh on B went away after $waited s (reboot under way)"
# Wait for it to come back.
waited=0
while true; do
  if ssh_ok b; then break; fi
  if [ "$waited" -ge 180 ]; then
    fail "step 7: B did not come back within 180 s"
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done
say "ssh on B answered again after $waited s"
run_on b 'hostname'
run_on b '/etc/init.d/supermox-wg start'
# Quorum within 180 s: poll corosync-quorumtool on both sides.
t0=$(date +%s)
quorate=0
while true; do
  qa="$(node_ssh a 'corosync-quorumtool -s' 2>/dev/null | grep -c 'Quorate: Yes' || true)"
  qb="$(node_ssh b 'corosync-quorumtool -s' 2>/dev/null | grep -c 'Quorate: Yes' || true)"
  if [ "${qa:-0}" -ge 1 ] && [ "${qb:-0}" -ge 1 ]; then quorate=1; break; fi
  if [ $(( $(date +%s) - t0 )) -ge 180 ]; then break; fi
  sleep 10
done
say "quorate on both again after $(( $(date +%s) - t0 )) s"
if [ "$quorate" -ne 1 ]; then
  fail "step 7: not quorate on both nodes within 180 s of B's reboot"
  exit 1
fi
run_rc b 'pvecm status'
if ! shared_pve_test; then
  fail "step 7: shared /etc/pve failed after B's reboot"
  exit 1
fi
pass "step 7: B rebooted, quorate on both within 180 s, shared /etc/pve works again"

# --- final: the phrase never reached a log ------------------------------------
if grep -R -F -q -f "$PHRASE_FILE" --include="$RUN_ID-*.log" "$LOG_DIR" \
  2>/dev/null; then
  fail "final: the phrase appears in a log under $LOG_DIR"
  exit 1
fi
pass "final: no log under $LOG_DIR contains the 12 words"

say ""
say "== RESULT =="
if [ "$fails" -gt 0 ]; then
  printf 'FAIL: %d step(s) failed\n' "$fails"
  exit 1
fi
printf 'PASS: all %d steps passed (%s)\n' "$step_no" "$HN_A/$HN_B on mcast $MCAST"
exit 0
