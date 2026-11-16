#!/usr/bin/env bash
# release-check.sh: step registry, recorded failures, and a dry run that never touches a VM.
# Runs offline: the live steps are forced to fail by pointing them at an ssh port nothing
# listens on, which is exactly the case the harness must survive without stopping the rest.
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/release-check.sh"
root="build/test-release-check"
fail=0
out=""
rc=0

if [ ! -f "$script" ]; then
  echo "FAIL: $script does not exist"
  exit 1
fi

if ! bash -n "$script"; then
  echo "FAIL: $script is not valid bash syntax"
  exit 1
fi

if ! shellcheck -S warning "$script"; then
  echo "FAIL: shellcheck -S warning $script"
  exit 1
fi

rm -rf "$root"
mkdir -p "$root/bin"

run() {
  rc=0
  out="$(bash "$script" "$@" 2>&1)" || rc=$?
}

# Same, but with a fake sshpass first on PATH: it records any attempt to reach the VM.
run_dry() {
  rc=0
  out="$(env PATH="$PWD/$root/bin:$PATH" SUPERMOX_FAKE_SSHPASS_LOG="$PWD/$root/sshpass.log" \
    bash "$script" "$@" 2>&1)" || rc=$?
}

assert_rc() {
  local want="$1"
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: exit code $rc, expected $want"
    printf '%s\n' "$out"
    fail=1
  fi
}

assert_has() {
  local needle="$1"
  if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output missing: $needle"
    printf '%s\n' "$out"
    fail=1
  fi
}

assert_lacks() {
  local needle="$1"
  if printf '%s\n' "$out" | grep -qF -- "$needle"; then
    echo "FAIL: output contains: $needle"
    printf '%s\n' "$out"
    fail=1
  fi
}

# 1. --list: the registry, first-history first so its failure cannot hide the others.
run --list
assert_rc 0
assert_has "first-history"
assert_has "check-no-systemd"
assert_has "check-overrides"
assert_has "vm-smoke"
if [ "$(printf '%s\n' "$out" | head -1)" != "first-history" ]; then
  echo "FAIL: first-history is not the first step in --list"
  printf '%s\n' "$out"
  fail=1
fi

# 2. --dry-run: plans the steps and performs no VM call at all. The fake sshpass logs
#    anything that tries to reach the VM; its log must stay absent.
printf '#!/usr/bin/env bash\nprintf "called\\n" >> "$SUPERMOX_FAKE_SSHPASS_LOG"\nexit 0\n' > "$root/bin/sshpass"
chmod +x "$root/bin/sshpass"
run_dry --dry-run
assert_rc 0
assert_has "DRY-RUN first-history"
assert_has "DRY-RUN vm-smoke"
assert_has "no VM call made"
assert_lacks "PASS first-history"
if [ -f "$root/sshpass.log" ]; then
  echo "FAIL: --dry-run reached the VM (fake sshpass was called)"
  fail=1
fi
run_dry --dry-run --only first-history
assert_rc 0
assert_has "DRY-RUN first-history"
assert_lacks "DRY-RUN vm-smoke"
if [ -f "$root/sshpass.log" ]; then
  echo "FAIL: --dry-run --only reached the VM (fake sshpass was called)"
  fail=1
fi

# 3. A forced-failing step (no VM on this port) is recorded, the steps after it still run,
#    and only the overall exit status is non-zero.
export SUPERMOX_VM_SSH_PORT=2299
export SUPERMOX_RELEASE_HISTORY_TIMEOUT=1
export SUPERMOX_RELEASE_HISTORY_POLL=1
run --only first-history,check-no-systemd,check-overrides
assert_rc 1
assert_has "== first-history =="
assert_has "FAIL first-history"
assert_has "ssh not answering on port 2299"
assert_has "== check-no-systemd =="
assert_has "PASS check-no-systemd"
assert_has "== check-overrides =="
assert_has "PASS check-overrides"
assert_has "release-check: 3 steps attempted, 1 failed"

# 4. With every selected step passing, the run exits 0.
run --only check-no-systemd,check-overrides
assert_rc 0
assert_has "release-check: 2 steps attempted, 0 failed"

# 5. An unknown step name is rejected before anything runs.
run --only not-a-step
assert_rc 2
assert_has "unknown step: not-a-step"
assert_lacks "release-check:"

# 6. first-history reports the evidence SuperMox#12 names.
for needle in 'pgrep -a pvestatd' '<defunct>' '.qmp' '/var/lib/rrdcached/db' '/etc/init.d/pvestatd'; do
  if ! grep -qF -- "$needle" "$script"; then
    echo "FAIL: $script does not report: $needle"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: release-check.sh lists first-history first, dry-runs without a VM call, records a failing step and still runs the steps after it"
