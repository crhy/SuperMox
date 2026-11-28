#!/usr/bin/env bash
# monthly-build.sh: ordered step registry, honest SKIP/FAIL per step, evidence kept.
#
# Runs offline. The VM steps are forced to skip the way tests/manager-live.sh already
# does it (no VM is up, scripts/vm-status.sh says so) plus SUPERMOX_TEST_DIR pointed at
# a directory that does not exist. A failing step is forced the way tests/test-init-
# networking.sh drops a fake command on PATH: a fake python3 that records the call and
# exits 3, so python-tests fails while the steps after it must still run.
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/monthly-build.sh"
root="build/test-monthly"
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

# Fake commands on PATH: each records that it was called. python3 exits 3, which is
# how python-tests is made to fail; sshpass and the qemu binaries must never be reached.
printf '#!/bin/bash\necho python3-called >> "%s/calls"\nexit 3\n' "$PWD/$root" > "$root/bin/python3"
printf '#!/bin/bash\necho sshpass-called >> "%s/calls"\n' "$PWD/$root" > "$root/bin/sshpass"
for q in qemu-system-x86_64 qemu-system-aarch64; do
  printf '#!/bin/bash\necho %s-called >> "%s/calls"\n' "$q" "$PWD/$root" > "$root/bin/$q"
done
chmod +x "$root/bin/python3" "$root/bin/sshpass" "$root/bin/qemu-system-x86_64" "$root/bin/qemu-system-aarch64"

run() {
  rc=0
  out="$(bash "$script" "$@" 2>&1)" || rc=$?
}

# The fakes first on PATH.
run_path() {
  rc=0
  out="$(env PATH="$PWD/$root/bin:$PATH" bash "$script" "$@" 2>&1)" || rc=$?
}

# The fakes, plus no test VM directory.
run_vm() {
  rc=0
  out="$(env PATH="$PWD/$root/bin:$PATH" SUPERMOX_TEST_DIR="$PWD/$root/no-such-test-dir" \
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

step_lines() {
  local f="$1"
  grep -cE '^[a-z-]+ (OK|FAIL|SKIP) ' "$f" 2>/dev/null || true
}

# 1. --list: the registry, offline steps before the VM steps, VM steps marked vm.
run --list
assert_rc 0
prev_kind="offline"
order_bad=0
while IFS= read -r l; do
  name="${l%% *}"
  kind="$(printf '%s' "$l" | awk '{ print $2 }')"
  case "$kind" in
    offline | vm) ;;
    *)
      echo "FAIL: --list line without an offline/vm kind: $l"
      order_bad=1
      ;;
  esac
  case "$name" in
    upstream-pins | no-systemd | python-tests | init-scripts | repo-layout | iso-prepare | \
    android-setup | apt-repo | arch | branding | build-deps-report | build-rootfs | \
    check-services | check-sh | dhcp-client-port | fetch-upstream | firewall-rules | \
    install-checkout | upstream-drift-check | \
    join-e2e | lan-cluster-e2e | local-env | monthly-build-selftest | node-caps | \
    patches | proxmox-systemd-crate | proxmox-systemd-pkg | pve-manager-sources | \
    reap-orphans | release-check | supermox-binfmt | supermox-dhcp-client | \
    supermox-manager | supermox-tmpfiles | sync-live | sysvservice | \
    vm-boot-iso | vm-build-tooling | vm-lan-pair | vm-scripts)
      if [ "$kind" != "offline" ]; then
        echo "FAIL: $name is not marked offline"
        order_bad=1
      fi
      if [ "$prev_kind" = "vm" ]; then
        echo "FAIL: offline step $name comes after a vm step"
        order_bad=1
      fi
      ;;
    vm-install | web-admin | hardware-matrix)
      if [ "$kind" != "vm" ]; then
        echo "FAIL: $name is not marked vm"
        order_bad=1
      fi
      ;;
    *)
      echo "FAIL: unexpected step in --list: $name"
      order_bad=1
      ;;
  esac
  prev_kind="$kind"
done <<< "$out"
if [ "$order_bad" -ne 0 ]; then
  fail=1
fi
if [ "$(printf '%s\n' "$out" | grep -cE '^[a-z0-9-]+ ')" -ne 43 ]; then
  echo "FAIL: --list did not print the 43 registry steps"
  printf '%s\n' "$out"
  fail=1
fi

# 2. --dry-run: prints the plan, runs nothing (the fakes stay uncalled), writes nothing.
rm -f "$root/calls"
run_path --line dryrun --dry-run
assert_rc 0
assert_has "DRY-RUN upstream-pins (offline): bash scripts/check-overrides.sh"
assert_has "DRY-RUN vm-install (vm): bash scripts/vm-test-install.sh"
assert_has "DRY-RUN web-admin (vm): bash tests/manager-live.sh"
assert_has "DRY-RUN hardware-matrix (vm):"
# f250: the newer 11.26 offline checks are in the plan too, before the VM steps.
assert_has "DRY-RUN dhcp-client-port (offline): bash tests/test-dhcp-client-port.sh"
assert_has "DRY-RUN local-env (offline): bash tests/test-local-env.sh"
assert_has "DRY-RUN install-checkout (offline): bash tests/test-install-checkout.sh"
assert_has "DRY-RUN upstream-drift-check (offline): bash tests/test-upstream-drift-check.sh"
assert_has "DRY-RUN reap-orphans (offline): bash tests/test-reap-orphans.sh"
assert_has "DRY-RUN supermox-tmpfiles (offline): bash tests/test-supermox-tmpfiles.sh"
if [ -f "$root/calls" ]; then
  echo "FAIL: --dry-run called a command on PATH"
  printf '%s\n' "$(cat "$root/calls")"
  fail=1
fi
if [ -e "build/monthly/dryrun" ]; then
  echo "FAIL: --dry-run created a state dir"
  fail=1
fi

# 3. The month line follows AGENTS.md: month number, two-digit year, 12.26 -> 1.27.
run --date 2026-12-31 --dry-run
assert_rc 0
assert_has "line 12.26 state dir build/monthly/12.26"
run --date 2027-01-01 --dry-run
assert_rc 0
assert_has "line 1.27 state dir build/monthly/1.27"
assert_lacks "13.26"
assert_lacks "line 01"

# 4. A step forced to fail: later steps still run, the exit status is non-zero.
state="$root/state-fail"
rm -rf "$state"
run_path --only python-tests,init-scripts,repo-layout --state-dir "$state"
if [ "$rc" -eq 0 ]; then
  echo "FAIL: a run with a failing step exited 0"
  printf '%s\n' "$out"
  fail=1
fi
assert_has "FAIL python-tests rc=3"
assert_has "OK init-scripts"
assert_has "OK repo-layout"
if ! grep -q 'python3-called' "$root/calls" 2>/dev/null; then
  echo "FAIL: the python-tests step did not run its command"
  fail=1
fi
if [ ! -f "$state/manifest.txt" ]; then
  echo "FAIL: no manifest.txt in $state"
  fail=1
fi
if [ "$(step_lines "$state/manifest.txt")" -ne 3 ]; then
  echo "FAIL: manifest.txt does not have one line per attempted step"
  printf '%s\n' "$(cat "$state/manifest.txt" 2>/dev/null)"
  fail=1
fi
if ! grep -qE '^python-tests FAIL 3 ' "$state/manifest.txt"; then
  echo "FAIL: manifest.txt does not record the failure with its exit code"
  printf '%s\n' "$(cat "$state/manifest.txt")"
  fail=1
fi
for f in python-tests init-scripts repo-layout; do
  if [ ! -f "$state/$f.log" ]; then
    echo "FAIL: no log for step $f"
    fail=1
  fi
done
if ! grep -qE '^pxvirt [0-9a-f]{40}$' "$state/manifest.txt"; then
  echo "FAIL: manifest.txt does not record the pinned PXVIRT commit"
  printf '%s\n' "$(cat "$state/manifest.txt")"
  fail=1
fi
if ! grep -qE '^timestamp [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$state/manifest.txt"; then
  echo "FAIL: manifest.txt does not record a UTC timestamp"
  fail=1
fi

# 5. The VM steps skip with the concrete missing prerequisite, never OK.
state_vm="$root/state-vm"
rm -rf "$state_vm"
run_vm --only vm-install,web-admin,hardware-matrix --state-dir "$state_vm" --line 12.26
assert_rc 0
assert_has "SKIP vm-install SUPERMOX_TEST_DIR absent:"
assert_has "SKIP web-admin scripts/vm-status.sh: no SuperMox VM running"
assert_has "SKIP hardware-matrix no hardware matrix here yet"
assert_lacks "OK vm-install"
assert_lacks "OK web-admin"
if grep -qE '^(vm-install|web-admin|hardware-matrix) OK' "$state_vm/manifest.txt"; then
  echo "FAIL: a VM step was recorded OK without a VM"
  printf '%s\n' "$(cat "$state_vm/manifest.txt")"
  fail=1
fi
if [ "$(step_lines "$state_vm/manifest.txt")" -ne 3 ]; then
  echo "FAIL: the VM run manifest does not have one line per attempted step"
  printf '%s\n' "$(cat "$state_vm/manifest.txt")"
  fail=1
fi
if ! grep -q '^line 12.26$' "$state_vm/manifest.txt"; then
  echo "FAIL: --line is not recorded in manifest.txt"
  printf '%s\n' "$(cat "$state_vm/manifest.txt")"
  fail=1
fi
while IFS= read -r l; do
  log="${l##* }"
  if [ ! -f "$log" ]; then
    echo "FAIL: manifest log path does not exist: $log"
    fail=1
  fi
done < <(grep -E '^[a-z-]+ (OK|FAIL|SKIP) ' "$state_vm/manifest.txt")

# 6. --only runs just that step: repo-layout alone passes and is the only line,
#    and python-tests alone reaches exactly one command (the fake python3).
state_one="$root/state-one"
rm -rf "$state_one"
run --only repo-layout --state-dir "$state_one"
assert_rc 0
assert_has "OK repo-layout"
if [ "$(step_lines "$state_one/manifest.txt")" -ne 1 ]; then
  echo "FAIL: --only repo-layout attempted more than one step"
  printf '%s\n' "$(cat "$state_one/manifest.txt")"
  fail=1
fi
for other in upstream-pins no-systemd python-tests init-scripts iso-prepare \
  android-setup apt-repo arch branding build-deps-report build-rootfs \
  check-services check-sh dhcp-client-port fetch-upstream firewall-rules \
  install-checkout \
  join-e2e lan-cluster-e2e local-env monthly-build-selftest node-caps \
  patches proxmox-systemd-crate proxmox-systemd-pkg pve-manager-sources \
  reap-orphans release-check supermox-binfmt supermox-dhcp-client \
  supermox-manager supermox-tmpfiles sync-live sysvservice upstream-drift-check \
  vm-boot-iso vm-build-tooling vm-lan-pair vm-scripts; do
  if [ -f "$state_one/$other.log" ]; then
    echo "FAIL: --only repo-layout also ran $other"
    fail=1
  fi
done

rm -f "$root/calls"
state_py="$root/state-py"
rm -rf "$state_py"
run_path --only python-tests --state-dir "$state_py"
if [ "$(grep -c 'python3-called' "$root/calls" 2>/dev/null || true)" -ne 1 ]; then
  echo "FAIL: --only python-tests did not run exactly one step command"
  printf '%s\n' "$(cat "$root/calls" 2>/dev/null)"
  fail=1
fi
if [ "$(step_lines "$state_py/manifest.txt")" -ne 1 ]; then
  echo "FAIL: --only python-tests attempted more than one step"
  printf '%s\n' "$(cat "$state_py/manifest.txt")"
  fail=1
fi
if ! grep -qE '^python-tests FAIL 3 ' "$state_py/manifest.txt"; then
  echo "FAIL: --only python-tests is not the step recorded in manifest.txt"
  printf '%s\n' "$(cat "$state_py/manifest.txt")"
  fail=1
fi
if [ -f "$state_py/repo-layout.log" ] || [ -f "$state_py/vm-install.log" ]; then
  echo "FAIL: --only python-tests wrote a log for another step"
  fail=1
fi

# 7. No VM work of any kind happened in this whole test file.
if [ -f "$root/calls" ] && grep -qE 'sshpass-called|qemu-system-.*-called' "$root/calls"; then
  echo "FAIL: a VM command was reached"
  printf '%s\n' "$(cat "$root/calls")"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: monthly-build.sh lists the 43-step registry (f082's 9 plus 11.26's newer offline checks plus f253's install-checkout) with the offline steps before the vm-marked ones, dry-runs without running or writing anything, names the month line 12.26 -> 1.27, records FAIL with the exit code and still runs the later steps, SKIPs each VM step naming the missing prerequisite, writes manifest.txt with a status and an existing log path per step, and --only runs just that step"
