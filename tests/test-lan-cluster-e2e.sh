#!/usr/bin/env bash
# Offline gate test for scripts/lan-cluster-e2e.sh (c10).
#
# It never boots the pair: this PC cannot hold Strata plus two VMs, so the gate
# asserts the PLAN from --dry-run output instead - that all seven steps are
# driven, that they name the pair's real addresses, ports and endpoints, and
# above all that the 12-word join phrase never enters a command line: every
# printed line is run through supermox.secret.validate, so a phrase in the
# plan fails the gate even though nothing is executed.
#
# What --dry-run cannot prove (a cluster that really spans two kernels) is the
# live run's job on a machine that can hold the pair.
set -euo pipefail

cd "$(dirname "$0")/.."

# The assertions are about the script's own defaults, so the caller's SUPERMOX_*
# environment must not leak in (config/local.env points SUPERMOX_TEST_DIR at a
# data disk on some machines). Unset every SUPERMOX_* variable first.
while IFS= read -r _smx_var; do
  unset "$_smx_var"
done < <(compgen -e | grep -E '^SUPERMOX_[A-Za-z_][A-Za-z0-9_]*$')
unset _smx_var

e2e="scripts/lan-cluster-e2e.sh"

fail=0
ok() { printf 'OK: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

if [ ! -f "$e2e" ]; then
  bad "$e2e does not exist"
  printf 'FAIL: %d check(s) failed\n' "$fail"
  exit 1
fi

out="build/test-lan-cluster-e2e.out"
mkdir -p build
rc=0
bash "$e2e" --dry-run > "$out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  bad "--dry-run exited $rc"
else
  ok "--dry-run exits 0 without booting anything"
fi

# --- every step of the plan is present ----------------------------------------
for n in 1 2 3 4 5 6 7; do
  if grep -q "^$n\. " "$out"; then
    ok "step $n is in the plan"
  else
    bad "step $n is missing from the plan"
  fi
done

# --- the plan names the pair's real wiring ------------------------------------
for needle in '192.168.77.10' '192.168.77.11' '2231' '2232' '8743' 'smx-a' 'smx-b'; do
  if grep -q -- "$needle" "$out"; then
    ok "plan mentions $needle"
  else
    bad "plan does not mention $needle"
  fi
done
for needle in 'lan-pair-check.sh' 'supermox-join create' 'supermox-join core' \
  'corosync-quorumtool' 'pvecm status' '/etc/pve/' \
  'pvesh get /cluster/resources --type node' 'reboot' 'vm-lan-pair.sh stop'; do
  if grep -qF -- "$needle" "$out"; then
    ok "plan mentions $needle"
  else
    bad "plan does not mention $needle"
  fi
done

# --- the phrase never enters a command line ----------------------------------
# 1. No printed line is a valid 12-word join phrase.
if PYTHONPATH=src python3 - "$out" <<'PY'
import sys
from supermox import secret
bad = False
for line in open(sys.argv[1]):
    for cand in [line.strip()]:
        if len(cand.split()) == 12:
            try:
                secret.validate(cand)
            except Exception:
                continue
            print("phrase in plan: %s" % cand)
            bad = True
sys.exit(1 if bad else 0)
PY
then
  ok "no printed command contains a 12-word phrase"
else
  bad "a 12-word phrase appears in the printed plan"
fi

# 2. The join is driven through a helper that reads stdin and builds argv itself.
if grep -qF -- 'python3 /root/supermox-lan-e2e-join.py' "$out" \
  && grep -qF -- '< ' "$out" && grep -qF -- 'phrase.txt' "$out"; then
  ok "join command feeds the phrase on stdin, not as an argument"
else
  bad "join command does not show the phrase arriving on stdin"
fi

# 3. The helper itself: it must compile, read stdin, and carry no phrase.
helper="build/test-lan-cluster-e2e-helper.py"
if bash "$e2e" --print-helper > "$helper" 2>&1; then
  ok "--print-helper emits the join helper"
else
  bad "--print-helper failed"
fi
if python3 -m py_compile "$helper" 2>/dev/null; then
  ok "the join helper is valid python"
else
  bad "the join helper does not compile"
fi
if grep -q 'sys.stdin.read' "$helper" && grep -q 'runpy.run_path' "$helper"; then
  ok "the join helper reads stdin and builds argv inside python"
else
  bad "the join helper does not read the phrase from stdin"
fi
for flag in '"join"' '"--name"' '"--endpoint"' '"--my-endpoint"' \
  '"--my-wg-endpoint"' '"--words", words'; do
  if grep -qF -- "$flag" "$helper"; then
    ok "helper passes $flag"
  else
    bad "helper is missing $flag"
  fi
done
if PYTHONPATH=src python3 - "$helper" <<'PY'
import sys
from supermox import secret
bad = False
for line in open(sys.argv[1]):
    for s in line.strip().split('"'):
        if len(s.split()) == 12:
            try:
                secret.validate(s)
            except Exception:
                continue
            print("phrase literal in helper: %s" % s)
            bad = True
sys.exit(1 if bad else 0)
PY
then
  ok "no phrase literal in the join helper"
else
  bad "a 12-word phrase literal sits in the join helper"
fi
if grep -qE -- '--words[= ]?\$' "$out"; then
  bad "the plan puts --words with a value on a command line"
else
  ok "no --words <value> on any printed command line"
fi

# 4. The phrase path, executed offline: a stand-in supermox-join on PATH lets
#    the helper really run, so we can see where the phrase ends up. Same
#    measurement step 3 makes on B, minus the VM.
fake_bin="build/test-lan-cluster-e2e-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/supermox-join" <<'PY'
import os, subprocess, sys
with open(os.environ["SMX_FAKE_ARGV"], "w") as f:
    f.write("\n".join(sys.argv) + "\n")
ps = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True)
with open(os.environ["SMX_FAKE_PS"], "w") as f:
    f.write(ps.stdout)
PY
chmod 755 "$fake_bin/supermox-join"
phrase_file="build/test-lan-cluster-e2e-phrase.txt"
PYTHONPATH=src python3 -c 'from supermox import secret; print(secret.generate())' \
  > "$phrase_file"
chmod 600 "$phrase_file"
rm -f build/test-lan-cluster-e2e-argv.txt build/test-lan-cluster-e2e-ps.txt
if PATH="$PWD/$fake_bin:$PATH" SMX_FAKE_ARGV="$PWD/build/test-lan-cluster-e2e-argv.txt" \
   SMX_FAKE_PS="$PWD/build/test-lan-cluster-e2e-ps.txt" \
   python3 "$helper" < "$phrase_file"; then
  ok "the join helper runs against a stand-in CLI and exits 0"
else
  bad "the join helper failed against a stand-in CLI"
fi
if grep -qF -f "$phrase_file" build/test-lan-cluster-e2e-argv.txt; then
  ok "the phrase reaches the CLI's argv, so a real join would get it"
else
  bad "the phrase never reached the CLI: the join would have failed"
fi
if grep -qF -f "$phrase_file" build/test-lan-cluster-e2e-ps.txt; then
  bad "the phrase is visible in ps while the join runs"
else
  ok "the phrase is absent from every ps line taken during the join"
fi

# --- the secret's home is root-only, and the pair is always stopped ----------
if grep -qF -- '0600' "$out" && grep -qF -- 'phrase' "$out"; then
  ok "plan stores the phrase in a 0600 file under build/lan-e2e/"
else
  bad "plan does not store the phrase in a 0600 file"
fi
if grep -q 'trap cleanup EXIT' "$e2e" \
  && grep -q 'vm-lan-pair.sh" stop' "$e2e"; then
  ok "the pair is stopped by an EXIT trap"
else
  bad "the pair is not stopped by an EXIT trap"
fi

# --- --dry-run touched nothing ------------------------------------------------
# A live run leaves logs under build/lan-e2e/, so "touched nothing" means "added
# nothing": the file count there before and after the dry run has to match.
# `|| true` inside the braces: pipefail would otherwise fail the assignment when
# build/lan-e2e does not exist yet, and set -e would end the test there.
before="$( { ls build/lan-e2e 2>/dev/null || true; } | wc -l)"
bash "$e2e" --dry-run >/dev/null 2>&1 || true
after="$( { ls build/lan-e2e 2>/dev/null || true; } | wc -l)"
if [ "$before" != "$after" ]; then
  bad "--dry-run created state under build/lan-e2e/"
else
  ok "--dry-run created no VM state"
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  printf 'FAIL: %d check(s) failed\n' "$fail"
  exit 1
fi
printf 'PASS: lan-cluster-e2e plan is complete and phrase-safe\n'
