#!/usr/bin/env bash
# Release check: the live release-audit steps as a registry, one function per step.
#
# A failing step is recorded and the run continues; the exit status is non-zero only
# after every step has been attempted. That is the point: SuperMox#12 (first boot after
# a fresh install files no RRD history) must not stop the other live steps from running,
# so it is recorded as its own `first-history` step.
#
# Live steps reach the VM only through scripts/vm-ssh.sh. This script never starts, stops
# or restarts a VM, never runs a second one, and never fixes anything: it reports.
# Everything runs under sysvinit; the service state read here is /etc/init.d/<svc> status.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Which VM to check: scripts/vm-ssh.sh and scripts/vm-smoke.sh both honour
# SUPERMOX_VM_SSH_PORT (2223 = build VM, 2224 = test VM).
SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2223}"
export SUPERMOX_VM_SSH_PORT="$SSH_PORT"

# How long first-history waits for the node archive. SuperMox#12 saw none after 424 s;
# a healthy boot files one about 35 s after power-on.
HISTORY_TIMEOUT="${SUPERMOX_RELEASE_HISTORY_TIMEOUT:-300}"
HISTORY_POLL="${SUPERMOX_RELEASE_HISTORY_POLL:-10}"

STEP_NAMES=(first-history check-no-systemd check-overrides vm-smoke)

remote() {
  bash "$repo_root/scripts/vm-ssh.sh" "$@"
}

ssh_ok() {
  timeout 10 bash "$repo_root/scripts/vm-ssh.sh" true >/dev/null 2>&1
}

# Print the evidence SuperMox#12 names: pvestatd's unbounded wait, the defunct probe
# kvm, the QMP socket the probe is stuck on. Read-only; pvestatd is not restarted.
probe_state() {
  remote bash -s <<'REMOTE' || true
printf '%s\n' '--- uptime (s) ---'
cut -d. -f1 /proc/uptime 2>/dev/null || true
printf '%s\n' '--- pgrep -a pvestatd ---'
pgrep -a pvestatd || printf 'no pvestatd process\n'
printf '%s\n' '--- /etc/init.d/pvestatd status ---'
if [ -x /etc/init.d/pvestatd ]; then /etc/init.d/pvestatd status; else printf 'no /etc/init.d/pvestatd\n'; fi
printf '%s\n' '--- pvestatd wait state ---'
for p in $(pgrep pvestatd); do
  printf 'pid %s wchan=%s\n' "$p" "$(cat "/proc/$p/wchan" 2>/dev/null)"
  cat "/proc/$p/stack" 2>/dev/null || true
done
printf '%s\n' '--- defunct kvm ---'
ps -eo pid,ppid,stat,args | awk '$3 ~ /^Z/ || /<defunct>/' | grep -i kvm || printf 'no defunct kvm\n'
printf '%s\n' '--- kvm probe processes ---'
pgrep -a kvm || printf 'no kvm process\n'
printf '%s\n' '--- QMP sockets under /var/run/qemu-server ---'
ls -l /var/run/qemu-server/ 2>/dev/null | head -20
ls /var/run/qemu-server/*.qmp 2>/dev/null || printf 'no .qmp socket\n'
printf '%s\n' '--- pvestatd log tail ---'
tail -n 20 /var/log/pvestatd.log 2>/dev/null || true
REMOTE
}

# --- steps ---------------------------------------------------------------

step_first_history() {
  if ! ssh_ok; then
    printf 'FAIL: ssh not answering on port %s (scripts/vm-status.sh shows what is up)\n' "$SSH_PORT"
    return 1
  fi

  local waited=0 files=""
  while :; do
    files="$(remote "find /var/lib/rrdcached/db -type f 2>/dev/null | head -5" 2>/dev/null || true)"
    if [ -n "$files" ]; then
      printf 'PASS: node archive under /var/lib/rrdcached/db after %ss of waiting:\n' "$waited"
      printf '%s\n' "$files"
      return 0
    fi
    if [ "$waited" -ge "$HISTORY_TIMEOUT" ]; then
      break
    fi
    sleep "$HISTORY_POLL"
    waited=$((waited + HISTORY_POLL))
  done

  printf 'FAIL: no node archive under /var/lib/rrdcached/db after %ss (SuperMox#12)\n' "$waited"
  probe_state
  return 1
}

step_check_no_systemd() {
  bash "$repo_root/scripts/check-no-systemd.sh" --source "$repo_root"
}

step_check_overrides() {
  bash "$repo_root/scripts/check-overrides.sh"
}

step_vm_smoke() {
  bash "$repo_root/scripts/vm-smoke.sh"
}

describe() {
  case "$1" in
    first-history) printf 'first boot after install files RRD history (SuperMox#12)' ;;
    check-no-systemd) printf 'ZERO systemd in our tree, against config/systemd-baseline.txt' ;;
    check-overrides) printf 'config/upstream-overrides.txt still honest' ;;
    vm-smoke) printf 'booted VM: sysvinit PID 1, no systemd in the image, nested KVM' ;;
    *) printf 'no description for %s' "$1" ;;
  esac
}

# --- registry / CLI --------------------------------------------------------

is_step() {
  local s
  for s in "${STEP_NAMES[@]}"; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}

usage() {
  printf 'usage: %s [--list] [--only STEP[,STEP...]] [--dry-run]\n' "${0##*/}"
  printf 'steps: %s\n' "${STEP_NAMES[*]}"
  printf 'env: SUPERMOX_VM_SSH_PORT, SUPERMOX_RELEASE_HISTORY_TIMEOUT, SUPERMOX_RELEASE_HISTORY_POLL\n'
}

main() {
  local selected=()
  local list=0 dry=0
  local n

  add_only() {
    local rest="$1" part
    while [ -n "$rest" ]; do
      part="${rest%%,*}"
      if [ "$part" = "$rest" ]; then
        rest=""
      else
        rest="${rest#*,}"
      fi
      [ -n "$part" ] || continue
      if ! is_step "$part"; then
        printf 'ERROR: unknown step: %s\n' "$part" >&2
        return 2
      fi
      selected+=("$part")
    done
    return 0
  }

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list)
        list=1
        shift
        ;;
      --dry-run)
        dry=1
        shift
        ;;
      --only)
        if [ "$#" -lt 2 ]; then
          usage
          return 2
        fi
        if ! add_only "$2"; then
          usage
          return 2
        fi
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        printf 'ERROR: unknown argument: %s\n' "$1" >&2
        usage
        return 2
        ;;
    esac
  done

  if [ "${#selected[@]}" -eq 0 ]; then
    selected=("${STEP_NAMES[@]}")
  fi

  if [ "$list" -eq 1 ]; then
    for n in "${selected[@]}"; do
      printf '%s\n' "$n"
    done
    return 0
  fi

  if [ "$dry" -eq 1 ]; then
    # Plan only: no ssh, no VM call of any kind.
    for n in "${selected[@]}"; do
      printf 'DRY-RUN %s: %s\n' "$n" "$(describe "$n")"
    done
    printf 'DRY-RUN %s steps planned, no VM call made\n' "${#selected[@]}"
    return 0
  fi

  local ran=0 failed=0 rc
  for n in "${selected[@]}"; do
    printf '== %s ==\n' "$n"
    rc=0
    "step_${n//-/_}" || rc=$?
    ran=$((ran + 1))
    if [ "$rc" -ne 0 ]; then
      printf 'FAIL %s (rc=%s)\n' "$n" "$rc"
      failed=$((failed + 1))
    else
      printf 'PASS %s\n' "$n"
    fi
  done

  printf 'release-check: %s steps attempted, %s failed\n' "$ran" "$failed"
  if [ "$failed" -ne 0 ]; then
    return 1
  fi
  return 0
}

main "$@"
