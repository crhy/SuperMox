#!/usr/bin/env bash
set -euo pipefail

# Prove milestone 1 on a CLEAN VM: install our debs, start PVE under sysvinit, show there is no systemd.
# This task MAY build images and run QEMU (that is its point). It never runs two VMs at once, never touches
# PVE code and never fixes anything: it installs, starts, checks and prints PASS/FAIL for a human to read.
#
# It points every helper (build-rootfs/vm-start/vm-ssh/vm-stop/vm-setup-proxmox-repos) at the TEST VM by
# exporting SUPERMOX_VM_DIR and SUPERMOX_VM_SSH_PORT, which those scripts already honour.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

TEST_DIR="${SUPERMOX_TEST_DIR:-/media/rhy/data/supermox-test}"
SSH_PORT="${SUPERMOX_TEST_SSH_PORT:-2224}"
DEBS_DIR="${SUPERMOX_DEBS_DIR:-/media/rhy/data/supermox-vm/debs}"

export SUPERMOX_VM_DIR="$TEST_DIR"
export SUPERMOX_VM_SSH_PORT="$SSH_PORT"

rebuild=0
for arg in "$@"; do
  case "$arg" in
    --rebuild) rebuild=1 ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

remote() {
  bash "$repo_root/scripts/vm-ssh.sh" "$@"
}

copy_in() {
  sshpass -p supermox scp -P "$SSH_PORT" "${ssh_opts[@]}" -o ConnectTimeout=10 "$@"
}

test_vm_running=0
cleanup() {
  if [ "$test_vm_running" -eq 1 ]; then
    printf 'Stopping test VM (dir %s)\n' "$TEST_DIR"
    bash "$repo_root/scripts/vm-stop.sh" || true
  fi
}
trap cleanup EXIT

# 1. Build the rootfs for the test VM (force only with --rebuild).
build_args=()
if [ "$rebuild" -eq 1 ]; then
  build_args+=(--force)
fi
printf '== building test rootfs in %s ==\n' "$TEST_DIR"
bash "$repo_root/scripts/build-rootfs.sh" "${build_args[@]}"

# 2. Start the test VM in the background.
printf '== starting test VM (ssh port %s) ==\n' "$SSH_PORT"
bash "$repo_root/scripts/vm-start.sh" --background
test_vm_running=1

# 3. Wait for ssh.
waited=0
until remote true 2>/dev/null; do
  if [ "$waited" -ge 180 ]; then
    printf 'FAIL: ssh not reachable within 180s\n' >&2
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done
printf 'PASS: ssh reachable after %ss\n' "$waited"

# 4. Copy the debs in, index them, add the local repo source.
remote 'mkdir -p /root/localrepo'
copy_in "$DEBS_DIR"/*.deb root@127.0.0.1:/root/localrepo/
remote 'export DEBIAN_FRONTEND=noninteractive; { command -v dpkg-scanpackages >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends dpkg-dev >/dev/null; }; } && cd /root/localrepo && dpkg-scanpackages . /dev/null > Packages 2> scan.log; printf "deb [trusted=yes] file:/root/localrepo ./\n" > /etc/apt/sources.list.d/supermox-local.list; printf "indexed %s packages\n" "$(grep -c "^Package:" Packages)"'

# 5. vm-setup-proxmox-repos.sh downloads the Proxmox keyring with curl, which the base image lacks;
#    install it first from the Devuan sources already in the image so the documented step can run.
remote 'command -v curl >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get -qq -y install curl; }'

printf '== configuring Proxmox repos on the test VM ==\n'
bash "$repo_root/scripts/vm-setup-proxmox-repos.sh"

# 6. /etc/hosts: hostname must resolve to the VM's own non-loopback IP (pve-cluster requires it).
remote 'bash -s' <<'HOSTS'
set -e
ip="$(ip -4 -o addr show eth0 | awk '{sub(/\/.*/, "", $4); print $4}')"
[ -n "$ip" ] || { echo "no IPv4 address on eth0" >&2; exit 1; }
touch /etc/hosts
hn="$(hostname)"
grep -v "[[:space:]]${hn}\$" /etc/hosts > /etc/hosts.new || true
printf '%s %s\n' "$ip" "$hn" >> /etc/hosts.new
mv /etc/hosts.new /etc/hosts
printf 'hosts:\n'; cat /etc/hosts
printf 'resolves: '; getent hosts "$hn" || true
HOSTS

# 7. Install the meta package (noninteractive).
printf '== apt-get install -y --no-install-recommends supermox-ve ==\n'
remote 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends supermox-ve'

# 8. Checks, from inside the VM. Print PASS/FAIL for each; on any FAIL dump the last 20 syslog lines
#    and any per-service log.
printf '== checks ==\n'
copy_in "$repo_root/scripts/check-no-systemd.sh" root@127.0.0.1:/root/check-no-systemd.sh

check_rc=0
remote 'bash -s' <<'CHECK' || check_rc=1
fail=0

init="$(readlink /proc/1/exe 2>/dev/null || true)"
case "$init" in
  */init) printf 'PASS: /proc/1/exe is sysvinit init (%s)\n' "$init" ;;
  *) printf 'FAIL: /proc/1/exe is not init (%s)\n' "$init"; fail=1 ;;
esac

if bash /root/check-no-systemd.sh --image /; then
  printf 'PASS: check-no-systemd.sh --image /\n'
else
  printf 'FAIL: check-no-systemd.sh --image /\n'; fail=1
fi

for svc in pve-cluster pvedaemon pveproxy pvestatd pvescheduler; do
  out="$(/etc/init.d/"$svc" status 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'PASS: %s status running\n' "$svc"
  else
    printf 'FAIL: %s status (rc=%s): %s\n' "$svc" "$rc" "$out"
    if [ -f "/var/log/$svc.log" ]; then
      printf '--- /var/log/%s.log (last 20) ---\n' "$svc"; tail -n 20 "/var/log/$svc.log"
    fi
    fail=1
  fi
done

if ss -ltn 2>/dev/null | grep -q ':8006'; then
  printf 'PASS: ss -ltn shows port 8006\n'
else
  printf 'FAIL: ss -ltn does not show port 8006\n'; fail=1
fi

ver="$(pvesh get /version --output-format json 2>&1)"; vrc=$?
if [ "$vrc" -eq 0 ] && [ -n "$ver" ]; then
  printf 'PASS: pvesh get /version: %s\n' "$ver"
else
  printf 'FAIL: pvesh get /version (rc=%s): %s\n' "$vrc" "$ver"; fail=1
fi

body="$(curl -sk https://127.0.0.1:8006/ 2>/dev/null)"
if printf '%s' "$body" | grep -qiE 'proxmox|<title'; then
  printf 'PASS: web UI on 8006 answers\n'
else
  printf 'FAIL: web UI on 8006 did not answer\n'; fail=1
fi

if [ "$fail" -ne 0 ]; then
  printf '--- /var/log/syslog (last 20) ---\n'
  tail -n 20 /var/log/syslog 2>/dev/null || true
fi
exit "$fail"
CHECK

if [ "$check_rc" -eq 0 ]; then
  printf 'ALL CHECKS PASSED on the clean test VM.\n'
else
  printf 'SOME CHECKS FAILED (see above; reported, not fixed).\n'
fi
exit "$check_rc"
