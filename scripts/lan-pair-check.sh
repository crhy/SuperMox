#!/usr/bin/env bash
# Prove the LAN pair really is one LAN: A pings B's address, B pings A's, and both
# print their interfaces and round-trip times.
#
# scripts/vm-lan-pair.sh wires NIC 2 of both VMs to one QEMU user-LAN (a UDP
# multicast socket) and gives each node a static address in 192.168.77.0/24. This
# script is the evidence that the wiring works end to end: ICMP packets crossing
# between two separate kernels, two separate stacks, measured latency printed
# rather than asserted. Nothing here is a substitute for that measurement: a
# namespace inside one VM (what join-e2e.sh fakes) can "ping" its neighbour and
# prove nothing, because the two ends share a kernel and a network stack.
#
# Run it after scripts/vm-lan-pair.sh start. Ports, addresses and the LAN net come
# from the same SUPERMOX_LAN_* variables vm-lan-pair.sh reads, so a changed
# address is still pinged correctly.
#
# Exit 0 only when BOTH directions get a reply.
set -euo pipefail

# Paths: environment > config/local.env > build/ default (see docs/development.md).
source "$(dirname "$0")/local-env.sh"

PAIR_DIR="$SUPERMOX_TEST_DIR/lan-pair"
SSH_A="${SUPERMOX_LAN_SSH_A:-2231}"
SSH_B="${SUPERMOX_LAN_SSH_B:-2232}"
IP_A="${SUPERMOX_LAN_IP_A:-192.168.77.10}"
IP_B="${SUPERMOX_LAN_IP_B:-192.168.77.11}"
MCAST="${SUPERMOX_LAN_MCAST:-230.0.0.1:12345}"
LAN_NET="${SUPERMOX_LAN_NET:-192.168.77.0/24}"
HN_A="smx-a"
HN_B="smx-b"
# Count and total timeout of one ping run: -c 4 gives a real RTT sample, -t bounds
# the whole run so a dead LAN fails in seconds instead of hanging the caller.
PING_COUNT="${SUPERMOX_LAN_PING_COUNT:-4}"
PING_TIMEOUT="${SUPERMOX_LAN_PING_TIMEOUT:-15}"

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

node_ssh() { # $1 ssh port, rest: remote command
  local port="$1"
  shift
  sshpass -p supermox ssh -p "$port" "${ssh_opts[@]}" root@127.0.0.1 "$@"
}

if [ ! -d "$PAIR_DIR" ]; then
  printf 'ERROR: no pair state in %s; run scripts/vm-lan-pair.sh start first.\n' "$PAIR_DIR" >&2
  exit 1
fi

# The endpoint and the net are printed because they are the two things to look at
# when a ping fails: the UDP endpoint both VMs share, and the range the static
# addresses have to fall inside. A node outside the net fails for a config reason,
# not a wiring one, so say so instead of reporting a broken LAN.
printf '== lan ==\n'
printf 'shared user-LAN: mcast=%s net=%s (A %s, B %s)\n' "$MCAST" "$LAN_NET" "$IP_A" "$IP_B"
net_prefix="${LAN_NET%%/*}"
for ip in "$IP_A" "$IP_B"; do
  case "$ip" in
    "$net_prefix".*) ;;
    *)
      printf 'ERROR: %s is outside the LAN net %s\n' "$ip" "$LAN_NET" >&2
      exit 1
      ;;
  esac
done

printf '== interfaces ==\n'
for side in a b; do
  case "$side" in
    a) port="$SSH_A"; hn="$HN_A"; me="$IP_A" ;;
    b) port="$SSH_B"; hn="$HN_B"; me="$IP_B" ;;
  esac
  printf -- '-- %s (ssh port %s, eth1 %s)\n' "$hn" "$port" "$me"
  if ! node_ssh "$port" \
    "printf 'hostname: %s\n' \"\$(hostname)\"; ip -br a; ip link show eth1 | grep -i 'link/ether'"; then
    printf 'ERROR: %s (port %s) is not reachable over ssh\n' "$hn" "$port" >&2
    exit 1
  fi
done

rc=0
# Both directions: one direction working and the other not is a broken LAN
# (asymmetric routing shows up exactly this way), so neither is optional.
printf '\n== A -> B: ping %s from %s ==\n' "$IP_B" "$HN_A"
if node_ssh "$SSH_A" "ping -n -c $PING_COUNT -W 2 -t $PING_TIMEOUT $IP_B"; then
  printf 'A -> B: OK\n'
else
  printf 'A -> B: FAILED\n' >&2
  rc=1
fi

printf '\n== B -> A: ping %s from %s ==\n' "$IP_A" "$HN_B"
if node_ssh "$SSH_B" "ping -n -c $PING_COUNT -W 2 -t $PING_TIMEOUT $IP_A"; then
  printf 'B -> A: OK\n'
else
  printf 'B -> A: FAILED\n' >&2
  rc=1
fi

# The hostnames and the hosts mapping are what pmxcfs and the join protocol
# use; a LAN that pings but cannot name its peer is not usable for a join test.
printf '\n== names ==\n'
for side in a b; do
  case "$side" in
    a) port="$SSH_A"; hn="$HN_A"; ip="$IP_A" ;;
    b) port="$SSH_B"; hn="$HN_B"; ip="$IP_B" ;;
  esac
  printf -- '-- %s (%s)\n' "$hn" "$ip"
  if node_ssh "$port" "grep -qF '$ip $hn' /etc/hosts"; then
    node_ssh "$port" "grep -F '$ip $hn' /etc/hosts"
  else
    printf '%s: FAILED (%s %s is not in that node'\''s /etc/hosts)\n' "$hn" "$ip" "$hn" >&2
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  printf '\nLAN pair OK: %s (%s) and %s (%s) ping each other over eth1.\n' \
    "$HN_A" "$IP_A" "$HN_B" "$IP_B"
else
  printf '\nLAN pair NOT OK: see the FAILED lines above.\n' >&2
fi
exit "$rc"
