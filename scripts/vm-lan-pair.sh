#!/usr/bin/env bash
# Two SuperMox nodes on one virtual LAN: the real two-machine join test needs it.
#
# scripts/join-e2e.sh fakes a cluster with network namespaces inside ONE VM. A
# namespace is not a machine: it shares a kernel, a boot and a disk, so it cannot
# prove the join protocol, pmxcfs or the firewall between two real nodes. This
# harness boots the installed test image TWICE, side by side, and gives both VMs
# a SECOND network interface on one shared QEMU user-LAN (a UDP multicast socket,
# so neither root nor libvirt is needed). Each guest then has:
#
#   eth0  QEMU user-net, the ssh forward to the host (A 2231, B 2232)
#   eth1  the shared LAN, configured with a static address (A .10, B .11)
#
# The disks are qcow2 OVERLAYS created with -b from the test rootfs image, so the
# image scripts/vm-test-install.sh installed into is never written to: both nodes
# start from the same installed system and each keeps its own changes.
#
# Subcommands:
#   start [--fresh] [--no-reboot] [--dry-run]  overlays, boot both, configure
#                                             both over ssh, reboot both
#   configure [A|B]                           (re)apply hostname, eth1, /etc/hosts
#   ssh A|B <cmd...>                          ssh into one node (port by side)
#   status [A|B]                            pid, overlay, ssh, LAN address, hostname
#   stop                                  stops BOTH, pidfile or command line
#
# State lives under $SUPERMOX_TEST_DIR/lan-pair/ (overlays, pidfiles, serial logs).
# RAM per VM is SUPERMOX_LAN_RAM (default 1536): this PC has about 2 GB free beside
# the model and the desktop, so the pair only fits at roughly half vm-start.sh's
# default. The pair is meant for the LAN test, not for the ISO boot test.
set -euo pipefail

# Architecture mapping: QEMU binary, console, machine options, expected comm.
source "$(dirname "$0")/arch.sh"
# Paths: environment > config/local.env > build/ default (see docs/development.md).
source "$(dirname "$0")/local-env.sh"
# Shared pidfile/command-line lookup (also used by vm-stop.sh and vm-start.sh).
source "$(dirname "$0")/vm-pid.sh"

TEST_DIR="$(supermox_canon_path "$SUPERMOX_TEST_DIR")"
PAIR_DIR="$TEST_DIR/lan-pair"
SRC_IMG="$TEST_DIR/rootfs.img"

LAN_RAM="${SUPERMOX_LAN_RAM:-1536}"
LAN_CPUS="${SUPERMOX_LAN_CPUS:-2}"
LAN_WAIT_SECS="${SUPERMOX_LAN_WAIT_SECS:-300}"
# Ports, addresses and MACs must differ per side. The MACs matter because both
# guests sit on the same LAN: with a duplicate MAC the second node's DHCP and
# link-local setup collides with the first one's.
SSH_A="${SUPERMOX_LAN_SSH_A:-2231}"
SSH_B="${SUPERMOX_LAN_SSH_B:-2232}"
IP_A="${SUPERMOX_LAN_IP_A:-192.168.77.10}"
IP_B="${SUPERMOX_LAN_IP_B:-192.168.77.11}"
LAN_NET="${SUPERMOX_LAN_NET:-192.168.77.0/24}"
MCAST="${SUPERMOX_LAN_MCAST:-230.0.0.1:12345}"
HN_A="smx-a"
HN_B="smx-b"
MAC_A="52:54:00:12:00:0A"
MAC_B="52:54:00:12:00:0B"

# --- per-side settings -------------------------------------------------------
# Bash 4.2 has no portable associative-array literal, so the per-side values are
# plain functions of the side name ("a" or "b").
side_label() { case "$1" in a) printf 'A\n' ;; b) printf 'B\n' ;; esac; }
side_hn() { case "$1" in a) printf '%s\n' "$HN_A" ;; b) printf '%s\n' "$HN_B" ;; esac; }
side_port() { case "$1" in a) printf '%s\n' "$SSH_A" ;; b) printf '%s\n' "$SSH_B" ;; esac; }
side_ip() { case "$1" in a) printf '%s\n' "$IP_A" ;; b) printf '%s\n' "$IP_B" ;; esac; }
side_mac() { case "$1" in a) printf '%s\n' "$MAC_A" ;; b) printf '%s\n' "$MAC_B" ;; esac; }
side_img() { printf '%s/smx-%s.img\n' "$PAIR_DIR" "$1"; }
side_pid() { printf '%s/qemu-%s.pid\n' "$PAIR_DIR" "$1"; }
side_log() { printf '%s/serial-%s.log\n' "$PAIR_DIR" "$1"; }

usage() {
  cat <<USAGE
Usage: scripts/vm-lan-pair.sh <command> [options]

  start [--fresh] [--no-reboot] [--dry-run]
  configure [A|B]
  ssh A|B <command...>
  status [A|B]
  stop

Environment: SUPERMOX_LAN_RAM (default $LAN_RAM), SUPERMOX_LAN_CPUS (default $LAN_CPUS),
SUPERMOX_LAN_WAIT_SECS (default $LAN_WAIT_SECS), SUPERMOX_LAN_SSH_A/B ($SSH_A/$SSH_B),
SUPERMOX_LAN_IP_A/B ($IP_A/$IP_B), SUPERMOX_LAN_NET ($LAN_NET),
SUPERMOX_LAN_MCAST ($MCAST).
State: $PAIR_DIR
USAGE
}

# --- argument handling -------------------------------------------------------
fresh=0
no_reboot=0
dry_run=0
sides=(a b)
# Flags may come before the command (scripts/vm-lan-pair.sh --dry-run start) as well
# as after it: the gate test and a human typing quickly both reach for the flag first.
# Only the flags BEFORE the command word are taken here, so a remote command given to
# `ssh A ...` can still contain a word that looks like one.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fresh) fresh=1 ;;
    --no-reboot) no_reboot=1 ;;
    --dry-run) dry_run=1 ;;
    *) break ;;
  esac
  shift
done
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
command="$1"
shift
case "$command" in
  start)
    for arg in "$@"; do
      case "$arg" in
        --fresh) fresh=1 ;;
        --no-reboot) no_reboot=1 ;;
        --dry-run) dry_run=1 ;;
        *)
          printf 'ERROR: unknown start option: %s\n' "$arg" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
    ;;
  configure | status)
    # An optional side filter; with none, both sides.
    if [ "$#" -gt 0 ]; then
      case "$1" in
        A | a) sides=(a) ;;
        B | b) sides=(b) ;;
        *)
          printf 'ERROR: unknown side: %s\n' "$1" >&2
          usage >&2
          exit 2
          ;;
      esac
      if [ "$#" -gt 1 ]; then
        printf 'ERROR: too many arguments\n' >&2
        usage >&2
        exit 2
      fi
    fi
    ;;
  ssh)
    [ "$#" -ge 2 ] || { printf 'ERROR: ssh needs A or B and a command\n' >&2; usage >&2; exit 2; }
    case "$1" in
      A | a) sides=(a) ;;
      B | b) sides=(b) ;;
      *)
        printf 'ERROR: unknown side: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
    ;;
  stop)
    [ "$#" -eq 0 ] || { printf 'ERROR: stop takes no arguments\n' >&2; exit 2; }
    ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    printf 'ERROR: unknown command: %s\n' "$command" >&2
    usage >&2
    exit 2
    ;;
esac

qemu_bin="$(supermox_qemu_bin)"
expected_comm="$(supermox_qemu_comm)"
console="$(supermox_console)"
mapfile -t mach_opts < <(supermox_machine_opts_words)
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

# QEMU_CMD is filled by build_cmd and run by start_vm: keeping the array in a
# global avoids re-parsing a printed command line (eval on a command line built
# from user-settable paths is a quoting trap, not a feature).
QEMU_CMD=()

print_cmd() {
  local line="" a
  for a in "$@"; do
    case "$a" in
      *[[:space:]]*) line+="\"$a\" " ;;
      *) line+="$a " ;;
    esac
  done
  printf '%s\n' "$line"
}

# --- qemu command line for one side ------------------------------------------
# NIC 1 is -nic (the user stack plus the ssh forward). NIC 2 is an explicit
# -netdev/-device pair, because the MAC belongs to the guest device, not to the
# netdev, and because the LAN must be a socket (mcast) rather than a user stack:
# two VMs on one user stack would each get their own private 10.0.2.x network.
build_cmd() { # $1 side
  local side="$1"
  local ovl="$PAIR_DIR/smx-$side.img"
  local host_arch
  host_arch="$(dpkg --print-architecture)"
  QEMU_CMD=("$qemu_bin" "${mach_opts[@]}")
  if [ "$SUPERMOX_ARCH" = "$host_arch" ] && [ -e /dev/kvm ]; then
    QEMU_CMD+=(-enable-kvm -cpu host)
  else
    QEMU_CMD+=(-cpu max)
  fi
  QEMU_CMD+=(
    -m "$LAN_RAM"
    -smp "$LAN_CPUS"
    -kernel "$TEST_DIR/vmlinuz"
    -initrd "$TEST_DIR/initrd.img"
    -append "root=/dev/vda rw console=$console net.ifnames=0"
    -drive "file=$ovl,format=qcow2,if=virtio"
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$(side_port "$side")-:22"
    -netdev "socket,id=lan,mcast=$MCAST"
    -device "virtio-net-pci,netdev=lan,mac=$(side_mac "$side")"
    -display none
    -serial "file:$(side_log "$side")"
    -daemonize
    -pidfile "$(side_pid "$side")"
  )
}

# --- pid lookup for one side (pidfile first, command line as the fallback) ---
running_pid() { # $1 side
  local side="$1" pid=""
  pid="$(supermox_find_qemu_pid "$(side_pid "$side")" "$expected_comm" || true)"
  printf '%s\n' "$pid"
}

# --- stop one side ----------------------------------------------------------
stop_side() { # $1 side
  local side="$1" pid="" how="" file_pid comm
  local pidfile
  pidfile="$(side_pid "$side")"
  if [ -f "$pidfile" ]; then
    file_pid="$(tr -dc '0-9' < "$pidfile")"
    if [ -n "$file_pid" ] && [ -r "/proc/$file_pid/comm" ]; then
      comm="$(tr -d '\n' < "/proc/$file_pid/comm")"
      if [ "$comm" = "$expected_comm" ]; then
        pid="$file_pid"
        how="pidfile"
      else
        printf 'ERROR: pid %s is %s, not %s; refusing to kill\n' \
          "$file_pid" "$comm" "$expected_comm" >&2
        return 1
      fi
    else
      printf '%s: pidfile pid %s is not running; searching the command line\n' \
        "$(side_label "$side")" "${file_pid:-none}"
    fi
  fi
  if [ -z "$pid" ]; then
    pid="$(running_pid "$side")"
    [ -n "$pid" ] && how="command line"
  fi
  if [ -z "$pid" ]; then
    printf '%s VM: not running (%s)\n' "$(side_label "$side")" "$pidfile"
    return 0
  fi
  printf 'Stopping %s VM qemu pid %s (found by %s)\n' "$(side_label "$side")" "$pid" "$how"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ -d "/proc/$pid" ] || { printf '%s VM stopped.\n' "$(side_label "$side")"; return 0; }
    sleep 1
  done
  printf 'WARN: %s VM qemu pid %s still running after 30s\n' "$(side_label "$side")" "$pid" >&2
  return 1
}

# --- qcow2 overlays ---------------------------------------------------------
# -b keeps the installed test image read-only: every write lands in the overlay.
# --- the base image must be a clean installed system --------------------------
# Both LAN nodes are overlays of ONE base, so whatever the base holds, BOTH
# nodes start holding it. A base that already carries /etc/supermox/membership
# json - a join test that wrote its cluster into the base disk - makes every
# node say "this node already belongs to a cluster" before it can join this
# pair. Measured 2026-11-06: scripts/join-e2e.sh left node-a's cluster in the
# test VM's /etc/supermox, vm-lan-pair.sh built both LAN VMs as overlays of
# that same rootfs.img, and smx-a then refused. The check reads the image
# directly (debugfs), so it needs no root, no mount and no running VM.
base_holds_cluster() {
  [ -f "$SRC_IMG" ] || return 1
  # debugfs lives in /sbin, which a normal user's PATH usually leaves out.
  local debugfs
  debugfs="$(PATH="$PATH:/sbin:/usr/sbin" command -v debugfs 2>/dev/null)" || {
    printf 'NOTE: debugfs is missing; the base image was not checked for a\n'
    printf '      pre-existing cluster.\n' >&2
    return 1
  }
  local out
  # An image with an unplayed journal is one debugfs cannot open at all. Saying
  # "no cluster" then would be a guess, and a guess in the safe direction is
  # the point of the guard, so the reader says what it could not do.
  out="$("$debugfs" -R 'ls /etc/supermox' "$SRC_IMG" 2>&1)"
  case "$out" in
  *'Filesystem not open'* | *'Bad superblock'* | *'not a valid'*)
    printf 'NOTE: %s could not be read by debugfs; the base image was not\n' "$SRC_IMG"
    printf '      checked for a pre-existing cluster.\n' >&2
    return 1
    ;;
  esac
  printf '%s\n' "$out" | grep -q 'membership\.json'
}
base_cluster_guard() {
  base_holds_cluster || return 0
  printf 'ERROR: the base image %s already holds /etc/supermox/membership.json.\n' "$SRC_IMG" >&2
  printf '       Both LAN nodes are overlays of that base, so both would start\n' >&2
  printf '       already inside a cluster and refuse to join this pair.\n' >&2
  printf '       Rebuild the test image: bash scripts/vm-test-install.sh --rebuild\n' >&2
  return 1
}

# An existing overlay is reused (a re-run keeps each node's installed state);
# --fresh throws both away and re-copies.
make_overlays() {
  local side ovl missing=0
  for f in "$SRC_IMG" "$TEST_DIR/vmlinuz" "$TEST_DIR/initrd.img"; do
    if [ ! -f "$f" ]; then
      printf 'ERROR: missing input file: %s\n' "$f" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || {
    printf 'Build them first: bash scripts/build-rootfs.sh (SUPERMOX_VM_DIR=%s)\n' "$TEST_DIR" >&2
    return 1
  }
  base_cluster_guard || return 1
  mkdir -p "$PAIR_DIR"
  for side in "${sides[@]}"; do
    ovl="$(side_img "$side")"
    if [ "$fresh" -eq 1 ] && [ -f "$ovl" ]; then
      rm -f "$ovl"
      printf 'removed old overlay: %s\n' "$ovl"
    fi
    if [ -f "$ovl" ]; then
      printf 'reusing overlay: %s (%s bytes)\n' "$ovl" "$(wc -c < "$ovl")"
      continue
    fi
    printf 'creating overlay %s from base %s\n' "$ovl" "$SRC_IMG"
    if ! qemu-img create -f qcow2 -b "$SRC_IMG" -F raw "$ovl" >/dev/null; then
      printf 'ERROR: qemu-img create failed for %s\n' "$ovl" >&2
      return 1
    fi
    printf 'created %s (%s bytes)\n' "$ovl" "$(wc -c < "$ovl")"
  done
}

# --- ssh into one node ------------------------------------------------------
node_ssh() { # $1 side, rest: remote command
  local side="$1"
  shift
  sshpass -p supermox ssh -p "$(side_port "$side")" "${ssh_opts[@]}" root@127.0.0.1 "$@"
}

ssh_ok() { # $1 side
  timeout 10 sshpass -p supermox ssh -p "$(side_port "$1")" "${ssh_opts[@]}" \
    root@127.0.0.1 true >/dev/null 2>&1
}

wait_ssh() { # $1 side; waits for ssh to answer again
  local side="$1" waited=0
  while true; do
    if ssh_ok "$side"; then
      printf '%s VM: ssh OK after about %s s (port %s)\n' \
        "$(side_label "$side")" "$waited" "$(side_port "$side")"
      return 0
    fi
    if [ "$waited" -ge "$LAN_WAIT_SECS" ]; then
      printf 'ERROR: %s VM ssh not answering after %s s (port %s)\n' \
        "$(side_label "$side")" "$LAN_WAIT_SECS" "$(side_port "$side")" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

wait_gone() { # $1 side; waits for ssh to stop answering (the reboot taking effect)
  local side="$1" waited=0
  while ssh_ok "$side"; do
    if [ "$waited" -ge 60 ]; then
      printf 'WARN: %s VM ssh still answering after 60 s; the reboot may not have started\n' \
        "$(side_label "$side")" >&2
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  printf '%s VM: ssh down after %s s (reboot under way)\n' "$(side_label "$side")" "$waited"
}

# --- configure one node over ssh ---------------------------------------------
# Three things, all idempotent, all applied over ssh at first boot:
#
#   hostname  smx-a / smx-b. Two nodes called "supermox" are indistinguishable
#             to pmxcfs, to the join protocol and to a human reading a log.
#   eth1      the LAN: a static stanza in /etc/network/interfaces, applied now
#             with ifup and applied by init.d/networking at every later boot.
#   /etc/hosts the hostname mapped to this node's LAN address. That line is
#             deliberately an UNMANAGED (admin) line: init.d/supermox-hosts keeps
#             such a line when its address is one of this node's own addresses,
#             and the address we need is eth1's, not the default route's eth0
#             DHCP address, which the other VM can never reach. supermox-hosts
#             then verifies the mapping instead of choosing it.
#
# Values are passed as arguments to the remote bash, not interpolated into the
# script, so a path or address with odd characters cannot change the code.
configure_side() { # $1 side
  local side="$1"
  printf '== configuring %s VM (hostname %s, eth1 %s, ssh port %s) ==\n' \
    "$(side_label "$side")" "$(side_hn "$side")" "$(side_ip "$side")" "$(side_port "$side")"
  node_ssh "$side" bash -s "$(side_hn "$side")" "$(side_ip "$side")" "$LAN_NET" <<'CONF'
set -e
hn=$1
ip=$2
net=$3
# 1. hostname, now and at every boot.
if [ "$(hostname)" != "$hn" ]; then
  printf '%s\n' "$hn" > /etc/hostname
  hostname -F /etc/hostname
fi
printf 'hostname: %s\n' "$(hostname)"
# 2. the LAN stanza, appended once, marked so a re-run does not stack copies.
if ! grep -qF '# supermox-lan-pair' /etc/network/interfaces; then
  printf '\n# supermox-lan-pair\nauto eth1\niface eth1 inet static\n    address %s\n    netmask 255.255.255.0\n' "$ip" >> /etc/network/interfaces
fi
# ifupdown2 needs its state dir (init.d/networking creates it at boot; create it
# here too so a configure before any networking start still works).
mkdir -p /run/network
[ -e /etc/network/run ] || ln -s /run/network /etc/network/run
if ! ip -br a show eth1 2>/dev/null | grep -q "$ip"; then
  ifup eth1 || {
    ip addr add "$ip/24" dev eth1
    ip link set eth1 up
  }
  ip route show | grep -qF "$net" || ip route add "$net" dev eth1 || true
fi
printf 'eth1: '; ip -br a show eth1
printf 'route: '; ip route show | grep -F "$net" || true
printf 'mac: '; ip link show eth1 | grep -i 'link/ether' || true
# 3. hosts mapping for pmxcfs: hostname -> this node's LAN address.
if ! grep -qw "$hn" /etc/hosts; then
  printf '%s %s\n' "$ip" "$hn" >> /etc/hosts
fi
if [ -x /etc/init.d/supermox-hosts ]; then
  /etc/init.d/supermox-hosts status || true
fi
printf 'hosts:\n'
grep -v '^#\|^$' /etc/hosts | head -n 10
CONF
}

# --- boot one side ----------------------------------------------------------
start_vm() { # $1 side
  local side="$1"
  if [ -n "$(running_pid "$side")" ]; then
    printf 'ERROR: a qemu for the %s VM is already running; stop it first (scripts/vm-lan-pair.sh stop).\n' \
      "$(side_label "$side")" >&2
    return 1
  fi
  printf '== starting %s VM (ssh port %s, %s MB RAM) ==\n' \
    "$(side_label "$side")" "$(side_port "$side")" "$LAN_RAM"
  build_cmd "$side"
  # The command line is printed for the human log, then run.
  print_cmd "${QEMU_CMD[@]}" | sed 's/^/  /'
  "${QEMU_CMD[@]}"
}

# A half-started pair is worse than no pair: one qemu holds its RAM and its half
# of the LAN socket while nothing tests. Every failure after the first qemu is
# up therefore stops both.
abort_pair() { # $1 reason
  printf '%s; stopping the pair\n' "$1" >&2
  stop_side a || true
  stop_side b || true
}

do_start() {
  local side
  if [ "$dry_run" -eq 1 ]; then
    # Print what a real start would do: the overlay creation and both qemu
    # command lines. Nothing is created and nothing is booted, so the gate can
    # assert the two-NIC wiring without QEMU, root or a test image.
    for side in "${sides[@]}"; do
      printf 'overlay: qemu-img create -f qcow2 -b %s -F raw %s\n' \
        "$SRC_IMG" "$(side_img "$side")"
      build_cmd "$side"
      print_cmd "${QEMU_CMD[@]}"
    done
    printf 'lan: mcast=%s net=%s hosts: %s=%s %s=%s\n' \
      "$MCAST" "$LAN_NET" "$HN_A" "$IP_A" "$HN_B" "$IP_B"
    return 0
  fi
  make_overlays || return 1
  for side in "${sides[@]}"; do
    start_vm "$side" || { abort_pair 'start failed'; return 1; }
  done
  for side in "${sides[@]}"; do
    wait_ssh "$side" || { abort_pair 'ssh never answered'; return 1; }
  done
  for side in "${sides[@]}"; do
    configure_side "$side" || { abort_pair 'configure failed'; return 1; }
  done
  if [ "$no_reboot" -eq 1 ]; then
    printf 'NOTE: --no-reboot: the hostname is set live, but the services that\n'
    printf '      started before it still know the old one; reboot before a join test.\n'
    return 0
  fi
  # Reboot both so the hostname and the eth1 stanza are in effect from boot:
  # pmxcfs and the join daemons take the hostname when they start, not later.
  for side in "${sides[@]}"; do
    printf '== rebooting %s VM ==\n' "$(side_label "$side")"
    node_ssh "$side" 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' || true
  done
  for side in "${sides[@]}"; do
    wait_gone "$side"
  done
  for side in "${sides[@]}"; do
    wait_ssh "$side" || { abort_pair 'the pair did not come back'; return 1; }
  done
  printf 'Pair up: %s (%s, port %s) and %s (%s, port %s) on mcast %s\n' \
    "$HN_A" "$IP_A" "$SSH_A" "$HN_B" "$IP_B" "$SSH_B" "$MCAST"
}

do_configure() {
  local side
  # Refuse before anything is applied: configuring a pair whose base already
  # holds a cluster cannot work, and the reason is in the base image, not in
  # the running VMs (see base_cluster_guard).
  base_cluster_guard || return 1
  for side in "${sides[@]}"; do
    if [ -z "$(running_pid "$side")" ]; then
      printf 'ERROR: %s VM is not running (scripts/vm-lan-pair.sh start)\n' "$(side_label "$side")" >&2
      return 1
    fi
    configure_side "$side" || return 1
  done
}

do_status() {
  local side pid ovl
  for side in "${sides[@]}"; do
    pid="$(running_pid "$side")"
    ovl="$(side_img "$side")"
    if [ -n "$pid" ]; then
      printf '%s VM: running (pid %s)\n' "$(side_label "$side")" "$pid"
    else
      printf '%s VM: not running\n' "$(side_label "$side")"
    fi
    if [ -f "$ovl" ]; then
      printf '  overlay: %s (%s bytes)\n' "$ovl" "$(wc -c < "$ovl")"
    else
      printf '  overlay: %s (missing)\n' "$ovl"
    fi
    printf '  pidfile: %s\n' "$(side_pid "$side")"
    if [ -n "$pid" ]; then
      if timeout 10 sshpass -p supermox ssh -p "$(side_port "$side")" "${ssh_opts[@]}" \
        root@127.0.0.1 'printf "  hostname: %s\n" "$(hostname)"; ip -br a show eth1' 2>/dev/null; then
        :
      else
        printf '  ssh: NOT answering on port %s\n' "$(side_port "$side")"
      fi
    fi
  done
}

do_ssh() { # remaining args: remote command
  if ! command -v sshpass >/dev/null 2>&1; then
    printf 'ERROR: sshpass is not installed\n' >&2
    return 1
  fi
  node_ssh "${sides[0]}" "$@"
}

case "$command" in
  start) do_start ;;
  configure) do_configure ;;
  status) do_status ;;
  ssh) do_ssh "$@" ;;
  stop)
    rc=0
    # Always BOTH sides, even if the first stop fails: a lone qemu of a pair
    # holds its RAM and keeps the LAN socket bound for nobody.
    stop_side a || rc=1
    stop_side b || rc=1
    exit "$rc"
    ;;
esac
