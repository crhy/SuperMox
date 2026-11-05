#!/usr/bin/env bash
# release-check.sh — one command that proves a release candidate: the offline
# gate, then every live suite against a test VM this script starts and always
# stops again (trap, so a failing step or Ctrl-C leaves no VM behind).
#
# Steps, in order: gate, vm-status, vm-boot, manager-live, join-e2e,
# no-systemd, services. Each prints PASS:/FAIL:/SKIP: and the run continues
# after a FAIL, so one run reports everything that is broken; the summary
# table at the end decides the exit code (1 if anything FAILED, and a SKIP of
# a step that applies counts as a failure unless --allow-skip).
#
# --help prints the step list, the flags and every RELEASE_CHECK_* override.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Paths and machine-local settings (SUPERMOX_TEST_DIR, SUPERMOX_IMG).
# shellcheck source=./local-env.sh
source "$repo_root/scripts/local-env.sh"

usage() {
    cat <<'USAGE'
usage: bash scripts/release-check.sh [--offline] [--allow-skip] [--help]

Prove a release candidate: the offline gate, then every live suite against a
test VM this script starts and always stops again (trap, so Ctrl-C and a
failing step still leave no VM behind).

Steps, in order. Each prints PASS:/FAIL:/SKIP: and the run continues after a
FAIL, so one run reports everything that is broken:

  gate          bash scripts/check.sh; its output must end with
                "All checks passed."
  vm-status     bash scripts/vm-status.sh must report no SuperMox VM running:
                this script owns the test VM it boots, so a VM already up
                means someone else is working and this is a FAIL.
  vm-boot       boot the test VM from $SUPERMOX_TEST_DIR (ssh port 2224,
                RAM from $SUPERMOX_VM_RAM default 2048, host 18006 forwarded
                to the guest), wait for ssh, then for
                https://127.0.0.1:18006/ answering (5 min max).
  manager-live  bash tests/manager-live.sh (timeout 3600)
  join-e2e      bash scripts/join-e2e.sh (timeout 1200)
  no-systemd    scripts/check-no-systemd.sh --image / inside the VM
  services      every enabled /etc/init.d service reports status rc 0

Flags:
  --offline     run only the gate step; the other steps are recorded as not
                applicable (applies=0) and are not counted.
  --allow-skip  let a SKIP pass. Without it a step that applies but did not
                run counts as a failure, so a check that verified nothing
                cannot exit 0.

Environment overrides (tests/test-release-check.sh uses them to exercise the
step logic without a VM; the *_TIMEOUT ones tune a slow host):
  RELEASE_CHECK_GATE, RELEASE_CHECK_VM_STATUS, RELEASE_CHECK_BOOT,
  RELEASE_CHECK_LIVE, RELEASE_CHECK_JOIN, RELEASE_CHECK_NO_SYSTEMD,
  RELEASE_CHECK_SERVICES, RELEASE_CHECK_SERVICES_ALLOW (init scripts that
  are enabled but idle by design; default supermox-wg, which waits for a
  join, networking (PVE keeps the host NIC 'manual' in /etc/network/interfaces
  and brings it up through its own sdn fabrics, so ifupdown2's status says
  'not up' even though eth0 works), rsync (Debian ships RSYNC_ENABLE=false)
  and smartmontools (smartd exits when the machine has no SMART-capable
  device, which a VM has)), RELEASE_CHECK_GATE_TIMEOUT (1800), RELEASE_CHECK_LIVE_TIMEOUT
  (3600), RELEASE_CHECK_JOIN_TIMEOUT (1200), RELEASE_CHECK_BOOT_TIMEOUT
  (900), RELEASE_CHECK_API_TIMEOUT (300).

The test VM disk is SUPERMOX_TEST_DIR (see config/local.env) and must already
hold a prepared image: scripts/vm-test-install.sh puts PVE, the SuperMox
packages and the live-test code on it, and the live tests need all three.
On the development PC start it with SUPERMOX_VM_RAM=2048.
USAGE
}

offline=0
allow_skip=0
while [ $# -gt 0 ]; do
    case "$1" in
        --offline) offline=1 ;;
        --allow-skip) allow_skip=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'usage: bash scripts/release-check.sh [--offline] [--allow-skip] [--help] (see --help)\n' >&2
           exit 2 ;;
    esac
    shift
done

test_dir="${SUPERMOX_TEST_DIR:?SUPERMOX_TEST_DIR is unset (set it in config/local.env)}"
ssh_port="${SUPERMOX_TEST_SSH_PORT:-2224}"
api_host="127.0.0.1"
api_port="18006"
# pveproxy listens on 8006 inside the VM; the live tests talk to it on the
# host at $api_port, so the hostfwd maps one to the other.
guest_api_port="8006"

gate_timeout="${RELEASE_CHECK_GATE_TIMEOUT:-1800}"
live_timeout="${RELEASE_CHECK_LIVE_TIMEOUT:-3600}"
join_timeout="${RELEASE_CHECK_JOIN_TIMEOUT:-1200}"
boot_timeout="${RELEASE_CHECK_BOOT_TIMEOUT:-900}"
api_timeout="${RELEASE_CHECK_API_TIMEOUT:-300}"

gate_cmd="${RELEASE_CHECK_GATE:-bash scripts/check.sh}"
status_cmd="${RELEASE_CHECK_VM_STATUS:-bash scripts/vm-status.sh}"
boot_cmd="${RELEASE_CHECK_BOOT:-}"
live_cmd="${RELEASE_CHECK_LIVE:-bash tests/manager-live.sh}"
join_cmd="${RELEASE_CHECK_JOIN:-bash scripts/join-e2e.sh}"
no_systemd_cmd="${RELEASE_CHECK_NO_SYSTEMD:-}"
services_cmd="${RELEASE_CHECK_SERVICES:-}"
# supermox-wg exits 3 until a join has put its overlay interface up, which a
# single-node test VM never does; every other enabled service must run.
services_allow="${RELEASE_CHECK_SERVICES_ALLOW:-supermox-wg networking rsync smartmontools}"

names=()
results=()
applies=()

record() {
    names+=("$1")
    results+=("$2")
    applies+=("$3")
    local verdict="${2%% (*}" reason=""
    if [ "$2" != "$verdict" ]; then
        reason=" ${2#"$verdict" }"
    fi
    printf '%s: %s%s\n' "$verdict" "$1" "$reason"
}

# Run one step's command from the repo root, print its output, record the
# result. ``applies_here`` 0 means the step does not apply in this mode at all;
# ``needs_vm`` 1 with no VM booted records a SKIP of a step that does apply, which
# is still a failure unless --allow-skip.
run_cmd() {
    local name="$1" limit="$2" cmd="$3" applies_here="$4" needs_vm="$5"
    local reason="${6:-}"
    local rc=0 out
    printf '\n== %s ==\n' "$name"
    if [ "$applies_here" -eq 0 ]; then
        record "$name" "SKIP ($reason)" 0
        return
    fi
    if [ "$needs_vm" -eq 1 ] && [ "$vm_up" -eq 0 ]; then
        record "$name" "SKIP ($reason)" 1
        return
    fi
    out="$(cd "$repo_root" && timeout "$limit" bash -c "$cmd" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then
        record "$name" "PASS" "$applies_here"
    else
        record "$name" "FAIL (rc $rc)" "$applies_here"
    fi
}

# ------------------------------------------------------------------- gate
# check.sh prints its success line last, so a run that stopped early cannot
# pass on a zero exit code alone.
gate_step() {
    local rc=0 out
    printf '\n== gate ==\n'
    out="$(cd "$repo_root" && timeout "$gate_timeout" bash -c "$gate_cmd" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        record "gate" "FAIL (rc $rc)" 1
        return
    fi
    if [ "$(printf '%s\n' "$out" | awk 'NF { line = $0 } END { print line }')" != "All checks passed." ]; then
        record "gate" "FAIL (output does not end with \"All checks passed.\")" 1
        return
    fi
    record "gate" "PASS" 1
}

# ------------------------------------------------------------------ VM steps
vm_started=0

vm_ssh() {
    SUPERMOX_VM_SSH_PORT="$ssh_port" bash "$repo_root/scripts/vm-ssh.sh" "$@"
}

# Every VM helper takes the test VM's data dir and ssh port: vm-start.sh, vm-stop.sh
# and vm-wait-ssh.sh read SUPERMOX_VM_DIR, and leaving it at the build VM's
# dir would stop the wrong VM. Exported per call, never globally, so the gate
# step still sees the machine's own local.env.
vm_cmd() {
    SUPERMOX_VM_DIR="$test_dir" SUPERMOX_VM_SSH_PORT="$ssh_port" "$@"
}

# Always stop the test VM on exit, including after a failure or Ctrl-C.
stop_vm() {
    [ "$vm_started" -eq 1 ] || return 0
    printf '\n== stop test VM ==\n'
    if vm_cmd bash "$repo_root/scripts/vm-stop.sh"; then
        printf 'the test VM is stopped\n'
    else
        printf 'WARN: vm-stop.sh failed; the test VM may still be running\n'
    fi
}
trap stop_vm EXIT

# vm-status must be clean before anything is booted: the VM this script stops
# on exit has to be the VM this script started.
vm_status_step() {
    local rc=0 out
    printf '\n== vm-status ==\n'
    out="$(cd "$repo_root" && timeout 120 bash -c "$status_cmd" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        record "vm-status" "FAIL (rc $rc)" 1
        return 1
    fi
    if printf '%s\n' "$out" | grep -qxF 'no SuperMox VM running'; then
        record "vm-status" "PASS" 1
        return 0
    fi
    if printf '%s\n' "$out" | grep -q 'VM running'; then
        printf 'FAIL: vm-status: a SuperMox VM is already running; stop it first\n'
        record "vm-status" "FAIL (a VM is already running)" 1
        return 1
    fi
    printf 'FAIL: vm-status: unexpected output: %s\n' "$out"
    record "vm-status" "FAIL (unexpected output)" 1
    return 1
}

# Boot the VM, wait for ssh, then for the API. A VM that answers ssh but has
# no PVE on it fails here rather than in every live test that follows.
boot_step() {
    local waited=0
    vm_up=0
    printf '\n== vm-boot ==\n'
    if [ -n "$boot_cmd" ]; then
        local rc=0 out
        out="$(cd "$repo_root" && timeout "$boot_timeout" bash -c "$boot_cmd" 2>&1)" || rc=$?
        printf '%s\n' "$out"
        if [ "$rc" -ne 0 ]; then
            record "vm-boot" "FAIL (rc $rc)" 1
        else
            vm_up=1
            record "vm-boot" "PASS" 1
        fi
        return
    fi
    if [ ! -f "$test_dir/rootfs.img" ]; then
        printf 'FAIL: vm-boot: %s/rootfs.img does not exist\n' "$test_dir"
        record "vm-boot" "FAIL (no test VM disk)" 1
        return
    fi
    # The subshell keeps the RAM and hostfwd overrides local: bash leaves
    # assignments before a function call set in the calling shell.
    if ! ( SUPERMOX_VM_RAM="${SUPERMOX_VM_RAM:-2048}" \
        SUPERMOX_VM_FWD="${SUPERMOX_VM_FWD:-tcp:${api_host}:${api_port}-:${guest_api_port}}" \
        vm_cmd bash "$repo_root/scripts/vm-start.sh" --background ); then
        record "vm-boot" "FAIL (vm-start.sh)" 1
        return
    fi
    vm_started=1
    while :; do
        # The subshell: an assignment before a function call would otherwise
        # stay set in this script, and vm_cmd's own prefix assignments apply
        # only to the helper it runs.
        if ( SUPERMOX_WAIT_SECS=100 vm_cmd bash "$repo_root/scripts/vm-wait-ssh.sh" ); then
            break
        fi
        waited=$((waited + 100))
        if [ "$waited" -ge "$boot_timeout" ]; then
            printf 'FAIL: vm-boot: ssh never answered within %ss\n' "$boot_timeout"
            record "vm-boot" "FAIL (ssh not answering)" 1
            return
        fi
    done
    if ! vm_ssh 'test -x /etc/init.d/pveproxy'; then
        printf 'FAIL: vm-boot: no PVE on this VM disk; prepare it with scripts/vm-test-install.sh first\n'
        record "vm-boot" "FAIL (no PVE installed)" 1
        return
    fi
    local deadline=$((SECONDS + api_timeout)) ok=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -ksS -o /dev/null --max-time 10 "https://${api_host}:${api_port}/"; then
            ok=1
            break
        fi
        sleep 5
    done
    if [ "$ok" -ne 1 ]; then
        printf 'FAIL: vm-boot: https://%s:%s/ never answered within %ss\n' \
            "$api_host" "$api_port" "$api_timeout"
        record "vm-boot" "FAIL (API not answering)" 1
        return
    fi
    vm_up=1
    record "vm-boot" "PASS" 1
}

# The installed system, not our source tree, must be free of systemd.
no_systemd_step() {
    printf '\n== no-systemd ==\n'
    if [ -n "$no_systemd_cmd" ]; then
        local rc=0 out
        out="$(cd "$repo_root" && timeout 300 bash -c "$no_systemd_cmd" 2>&1)" || rc=$?
        printf '%s\n' "$out"
        if [ "$rc" -eq 0 ]; then
            record "no-systemd" "PASS" 1
        else
            record "no-systemd" "FAIL (rc $rc)" 1
        fi
        return
    fi
    if [ "$vm_up" -eq 0 ]; then
        record "no-systemd" "SKIP (no VM)" 1
        return
    fi
    sshpass -p supermox scp -P "$ssh_port" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$repo_root/scripts/check-no-systemd.sh" \
        "$repo_root/config/systemd-image-allowlist.txt" \
        root@127.0.0.1:/root/ >/dev/null
    # The allowlist is passed explicitly: the script derives its repo root from
    # its own location, and on the VM there is no config/ next to it.
    if vm_ssh "SYSTEMD_IMAGE_ALLOWLIST_FILE=/root/systemd-image-allowlist.txt bash /root/check-no-systemd.sh --image /"; then
        record "no-systemd" "PASS" 1
    else
        record "no-systemd" "FAIL (systemd in the installed system)" 1
    fi
}

# Every service script SuperMox ships must be enabled (an S link in rc2.d) and
# must report status rc 0, or be idle by design and allowlisted; every enabled
# script must do the same, Debian's own included. sysvinit depends on that exit
# code, so a script that always exits 0 hides a failed start from the boot log.
# The work lives in scripts/check-services.sh so the same check can run against
# a fake tree in a test (f10d-4: walking rc2.d alone cannot see a script that
# was installed but never enabled).
services_step() {
    printf '\n== services ==\n'
    if [ -n "$services_cmd" ]; then
        run_cmd "services" 60 "$services_cmd" 1 0 ""
        return
    fi
    if [ "$vm_up" -eq 0 ]; then
        record "services" "SKIP (no VM)" 1
        return
    fi
    # Both the checker and the shipped-script list are copied over: on the VM
    # there is no repo, and the expected set must be the list the packaging
    # copies from, not something the checker guesses.
    sshpass -p supermox scp -P "$ssh_port" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$repo_root/scripts/check-services.sh" \
        "$repo_root/config/init-scripts.txt" \
        root@127.0.0.1:/root/ >/dev/null
    if vm_ssh "SERVICES_ALLOW='$services_allow' SERVICES_EXPECT_FILE=/root/init-scripts.txt bash /root/check-services.sh"; then
        record "services" "PASS" 1
    else
        record "services" "FAIL (a service is not running or not enabled)" 1
    fi
}

# ------------------------------------------------------------------ summary
summary() {
    local i failures=0
    printf '\n== summary ==\n'
    printf '%-14s %s\n' 'STEP' 'RESULT'
    for i in "${!names[@]}"; do
        printf '%-14s %s\n' "${names[i]}" "${results[i]}"
    done
    for i in "${!results[@]}"; do
        case "${results[i]}" in
            FAIL*) failures=$((failures + 1)) ;;
            SKIP*)
                if [ "${applies[i]}" -eq 1 ] && [ "$allow_skip" -eq 0 ]; then
                    failures=$((failures + 1))
                fi
                ;;
        esac
    done
    if [ "$failures" -eq 0 ]; then
        printf 'release-check: PASS\n'
        return 0
    fi
    printf 'release-check: FAIL (%d step(s) not verified)\n' "$failures"
    return 1
}

vm_up=0

gate_step

if [ "$offline" -eq 1 ]; then
    record "vm-status" "SKIP (offline)" 0
    record "vm-boot" "SKIP (offline)" 0
    record "manager-live" "SKIP (offline)" 0
    record "join-e2e" "SKIP (offline)" 0
    record "no-systemd" "SKIP (offline)" 0
    record "services" "SKIP (offline)" 0
    summary
    exit $?
fi

for tool in sshpass curl; do
    command -v "$tool" >/dev/null 2>&1 || printf 'WARN: %s is not installed\n' "$tool"
done

if vm_status_step; then
    boot_step
else
    record "vm-boot" "SKIP (a VM was already up, or vm-status failed)" 1
fi
run_cmd "manager-live" "$live_timeout" "$live_cmd" 1 1 "no VM booted"
run_cmd "join-e2e" "$join_timeout" "$join_cmd" 1 1 "no VM booted"
no_systemd_step
services_step

summary
exit $?
