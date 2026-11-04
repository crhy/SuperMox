#!/usr/bin/env bash
# join-e2e.sh - real WireGuard join between network namespaces inside the TEST VM.
#
# Runs on this PC and drives the test VM over ssh (the VM is root; this PC is not).
# The test VM must already be started (SUPERMOX_VM_SSH_PORT=2224). Prints PASS/FAIL
# per step and exits 1 on any FAIL.
#
# Topology (veth star, sma is the hub, one subnet per veth pair, see
# scripts/join-e2e-net.sh):
#   sma <-> smb : 10.99.0.1 / 10.99.0.2
#   sma <-> smc : 10.99.1.1 / 10.99.1.2
#   Each leaf also carries a route for the OTHER pair's subnet through its own
#   veth: a veth transfers packets regardless of subnet labels, so smc can
#   reach 10.99.0.1 (veth-d -> veth-c into sma -> delivered on veth-a's address
#   there). Without that route a leaf cannot address the hub's other endpoint
#   and its WireGuard tunnel to that peer silently loses every packet.
#   leaf <-> leaf is NOT reachable in this model: it would need its own veth
#   pair and a per-pair subnet, which one-address-per-member cannot express.
#
# Two ports, never conflated:
#   join daemon (TCP)     8743   - supermox-joind, where joins are sent
#   WireGuard (UDP)       51820  - the [Peer] Endpoint in wg0.conf
#
# node-a (sma) creates the cluster at the DEFAULT state dir /etc/supermox, so
# the sysvinit service script (enabled by rc symlinks) brings its join daemon
# back after the reboot in phase C. node-b (smb) joins by phrase, node-c (smc)
# joins by invite that node-a's operator approves; every member then runs its
# own daemon through /etc/init.d/supermox-joind, as in a real deployment.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
VM_SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2224}"

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'ERROR: sshpass is not installed\n' >&2
  exit 1
fi

ssh_opts=(
  -p "$VM_SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

vm_ssh() {
  sshpass -p supermox ssh "${ssh_opts[@]}" root@127.0.0.1 "$@"
}

vm_copy() {
  # scp takes -P, ssh takes -p.
  sshpass -p supermox scp -P "$VM_SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null "$@"
}

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_msg() { printf 'FAIL: %s\n' "$1"; fail=1; }

# --- Step 1: copy the join code and the netns helper into the VM (/opt/supermox) ---
if tar -C "$repo_root" -czf - src/supermox bin/supermox-join bin/supermox-joind \
  | vm_ssh 'rm -rf /opt/supermox; mkdir -p /opt/supermox; tar -xzf - -C /opt/supermox
# The ISO ships supermox in dist-packages; run the code just copied instead
# of the installed copy, so install it the way the package would.
find /opt/supermox/src -name __pycache__ -exec rm -rf {} + 2>/dev/null
rm -rf /usr/lib/python3/dist-packages/supermox
cp -a /opt/supermox/src/supermox /usr/lib/python3/dist-packages/'; then
  pass "copied src/supermox and bin/supermox-join + supermox-joind to /opt/supermox"
else
  fail_msg "copy to /opt/supermox"
fi

if vm_copy scripts/join-e2e-net.sh root@127.0.0.1:/opt/supermox/e2e-net.sh; then
  pass "copied scripts/join-e2e-net.sh to /opt/supermox/e2e-net.sh"
else
  fail_msg "copy of the netns helper"
fi

# --- Step 2: python deps, wireguard-tools, ping (tolerate no apt; verify) ---
if vm_ssh 'export DEBIAN_FRONTEND=noninteractive
apt-get -y install python3-mnemonic python3-nacl python3-qrcode python3-cryptography wireguard-tools iputils-ping >/dev/null 2>&1 || true
python3 -c "import nacl, mnemonic, qrcode, cryptography" && test -x /usr/bin/wg && test -x "$(command -v ping)"'; then
  pass "python deps, wireguard-tools and ping present in the VM"
else
  fail_msg "python deps / wireguard-tools / ping"
fi

# --- Step 3: the sysvinit service script for the join daemon, installed and
#     enabled the way the package is supposed to do it (dh_installinit --name).
#     The repo copy under init.d/ is the only source of truth. ---
if vm_copy init.d/supermox-joind root@127.0.0.1:/etc/init.d/supermox-joind \
  && vm_copy init.d/supermox-wg root@127.0.0.1:/etc/init.d/supermox-wg \
  && vm_ssh 'chmod 755 /etc/init.d/supermox-joind /etc/init.d/supermox-wg
update-rc.d supermox-joind defaults >/dev/null 2>&1
update-rc.d supermox-wg defaults >/dev/null 2>&1
ls /etc/rc2.d | grep -q "supermox-joind" && ls /etc/rc2.d | grep -q "supermox-wg" && test -x /usr/lib/supermox/supermox-logpipe'; then
  pass "service scripts installed and enabled (rc symlinks present)"
else
  fail_msg "init.d/supermox-joind not installed/enabled"
fi

# --- Steps 4-8: the join itself, in one remote shell. Quoted heredoc: every
#     path and port is defined inside the VM, nothing is expanded on the PC. ---
if vm_ssh 'bash -s' <<'REMOTE'
set -u
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fmsg() { printf 'FAIL: %s\n' "$1"; fail=1; }

BIN=/opt/supermox/bin
INITD=/etc/init.d/supermox-joind
WG_INITD=/etc/init.d/supermox-wg
JOIN_PORT=8743
WG_PORT=51820
. /opt/supermox/e2e-net.sh

# node-a keeps its state at the default /etc/supermox so the boot-time service
# finds it after the reboot; node-b and node-c keep per-node state dirs.
ETC_B=/etc/supermox/e2e/smb
ETC_C=/etc/supermox/e2e/smc
# The matching WireGuard config directories, passed as SUPERMOX_WG_DIR by every
# command that touches a nested node's state (wg_dir_of in join-e2e-net.sh).
WG_B=$(wg_dir_of smb)
WG_C=$(wg_dir_of smc)

# Every WireGuard config lives under /etc/wireguard/, where the wg profile
# allows it to be read: node-a at the default /etc/wireguard/wg0.conf, the
# nested nodes one directory per node below it (SUPERMOX_WG_DIR is how a
# multi-namespace host keeps several configs apart). conf_of in join-e2e-net.sh
# names the file for a namespace.

cleanup() {
  # A namespace with a live wireguard interface is not removed by ip netns del,
  # so take the tunnels down first. node-a's tunnel is a wg-quick interface;
  # the nested nodes' are hand-built, since wg-quick names the interface after
  # the file and cannot reach a config in a subdirectory.
  ip netns exec sma wg-quick down wg0 2>/dev/null
  for n in smb smc; do
    ip netns exec "$n" ip link del wg0 2>/dev/null
  done
  for n in sma smb smc; do
    [ -f "/run/jd-$n.pid" ] && kill "$(cat "/run/jd-$n.pid")" 2>/dev/null
    ip netns del "$n" 2>/dev/null
  done
  rm -f /run/jd-*.pid /run/jd-*.log /run/join.log /run/invite.log
}

names() {
  if [ "$1" = sma ]; then
    "$BIN/supermox-join" members
  else
    SUPERMOX_ETC="/etc/supermox/e2e/$1" "$BIN/supermox-join" members
  fi | awk '{print $1}' | sort | tr '\n' ' '
}

# start the node's join daemon through the sysvinit script, in its namespace;
# JOIND_PIDFILE/SUPERMOX_ETC keep the three nodes from colliding.
start_daemon() {
  ns=$1
  if [ "$ns" = sma ]; then
    ip netns exec "$ns" env JOIND_PIDFILE="/run/jd-$ns.pid" "$INITD" start >/dev/null
  else
    ip netns exec "$ns" env JOIND_PIDFILE="/run/jd-$ns.pid" SUPERMOX_ETC="/etc/supermox/e2e/$ns" SUPERMOX_WG_DIR="$(wg_dir_of "$ns")" "$INITD" start >/dev/null
  fi
  sleep 1
  [ -f "/run/jd-$ns.pid" ] && kill -0 "$(cat "/run/jd-$ns.pid")" 2>/dev/null
}

stop_daemon() {
  [ -f "/run/jd-$1.pid" ] && kill "$(cat "/run/jd-$1.pid")" 2>/dev/null
  rm -f "/run/jd-$1.pid"
}

# wg's AppArmor profile only lets wg read configs under /etc/wireguard, and
# wg-quick names the interface after the file, so node-a - the node at the
# default path - is brought up by the service script itself, exactly as it
# would be at boot; the nested nodes' configs sit in their own directory and
# are built by hand by manual_up (join-e2e-net.sh).
bring_up() {
  ns=$1
  if [ "$ns" = sma ]; then
    "$BIN/supermox-join" conf >/dev/null || return 1
    ip netns exec "$ns" "$WG_INITD" start >/dev/null || return 1
  else
    SUPERMOX_ETC="/etc/supermox/e2e/$ns" SUPERMOX_WG_DIR="$(wg_dir_of "$ns")" "$BIN/supermox-join" conf >/dev/null || return 1
    manual_up "$ns" || return 1
  fi
}

# The overlay addresses in wg0.conf are random ULA addresses (fd00::/8): they
# exist nowhere but inside the WireGuard tunnel, so pinging one proves the
# tunnel carries traffic, which pinging the veth addresses would not.
my_addr() {
  grep '^Address' "$(conf_of "$1")" | head -n1 | awk '{print $3}' | cut -d/ -f1
}

ping_ok() { ip netns exec "$1" ping -n -c 2 -W 3 "$2" >/dev/null 2>&1; }

# 4. clean slate: daemons, state and veth from any earlier run.
cleanup
rm -rf /etc/supermox/e2e
rm -f /etc/supermox/identity.json /etc/supermox/membership.json /etc/supermox/cluster.keys /etc/supermox/invites.json /etc/supermox/pending.json /etc/supermox/nonces.json /etc/supermox/wg0.conf /etc/supermox/cluster.json
rm -f /etc/wireguard/wg0.conf
rm -rf /etc/wireguard/smb /etc/wireguard/smc
for v in veth-a veth-b veth-c veth-d; do ip link del "$v" 2>/dev/null; done

# 5. namespaces + veth star.
if net_star; then
  pass "namespaces sma/smb/smc + veth star up"
else
  fmsg "namespaces/veth setup"
fi

# 6. create the cluster as node-a; the 12 words live only in a shell variable.
W=$(ip netns exec sma "$BIN/supermox-join" create --name node-a \
  --endpoint "10.99.0.1:$JOIN_PORT" --my-wg-endpoint "10.99.0.1:$WG_PORT" | tail -n1)
nw=$(printf '%s\n' "$W" | wc -w)
if [ "$nw" -eq 12 ]; then
  pass "create node-a (12 words captured in a variable, not a file)"
else
  fmsg "create node-a (got $nw words)"
fi

# 7. node-a's join daemon, started by the sysvinit script inside sma.
if start_daemon sma && [ -f /run/jd-sma.pid ]; then
  pass "join daemon for node-a running (init.d start)"
else
  fmsg "join daemon for node-a"
  tail -3 /var/log/syslog 2>/dev/null | sed 's/^/    /'
fi

# 8. node-b joins by phrase from smb, then runs its own daemon.
mkdir -p "$ETC_B"
ip netns exec smb env SUPERMOX_ETC="$ETC_B" SUPERMOX_WG_DIR="$WG_B" "$BIN/supermox-join" join --words "$W" \
  --endpoint "10.99.0.1:$JOIN_PORT" --name node-b \
  --my-endpoint "10.99.0.2:$JOIN_PORT" --my-wg-endpoint "10.99.0.2:$WG_PORT" >/run/join.log 2>&1
if grep -q '^joined as node-b' /run/join.log; then
  pass "node-b phrase join"
else
  fmsg "node-b phrase join"
  sed 's/^/    /' /run/join.log
fi
if start_daemon smb; then
  pass "join daemon for node-b running"
else
  fmsg "join daemon for node-b"
fi

# 9. node-c joins through an invite that node-a's operator approves.
URI=$(ip netns exec sma "$BIN/supermox-join" invite --ttl 900 | head -n1)
ip netns exec smc env SUPERMOX_ETC=/tmp/supermox-e2e-throwaway SUPERMOX_WG_DIR="$WG_C" "$BIN/supermox-join" join --uri "$URI" \
  --endpoint "10.99.0.1:$JOIN_PORT" --name node-c \
  --my-endpoint "10.99.1.2:$JOIN_PORT" --my-wg-endpoint "10.99.1.2:$WG_PORT" >/run/join.log 2>&1 &
sleep 2
RID=$(ip netns exec sma "$BIN/supermox-join" pending | awk '$1 != "no" {print $1; exit}')
if [ -n "$RID" ]; then
  ip netns exec sma "$BIN/supermox-join" approve "$RID" --endpoint "127.0.0.1:$JOIN_PORT" >/dev/null
  wait
  mkdir -p "$ETC_C"
  cp /tmp/supermox-e2e-throwaway/* "$ETC_C/" 2>/dev/null
  start_daemon smc
  pass "node-c invite join approved by node-a, daemon running"
else
  fmsg "node-c invite join (no pending request)"
  sed 's/^/    /' /run/join.log
fi

# 10. every member ran a daemon when the change happened, so all three nodes
#     must now agree on the member list.
A=$(names sma); B=$(names smb); C=$(names smc)
if [ "$A" = "$B" ] && [ "$A" = "$C" ] && printf '%s\n' "$A" | grep -q node-a \
  && printf '%s\n' "$A" | grep -q node-b && printf '%s\n' "$A" | grep -q node-c; then
  pass "all three nodes agree on the member list ($A)"
else
  fmsg "membership differs: sma=$A smb=$B smc=$C"
fi

# 11. wg0.conf must name the WireGuard port for every peer, never the join port.
# The daemon only rewrites the config when membership changes, so generate it.
for n in sma smb smc; do
  if [ "$n" = sma ]; then
    "$BIN/supermox-join" conf >/dev/null
    KEY_A=$(grep '^PrivateKey' /etc/wireguard/wg0.conf | cut -d' ' -f3)
  else
    SUPERMOX_ETC="/etc/supermox/e2e/$n" SUPERMOX_WG_DIR="$(wg_dir_of "$n")" "$BIN/supermox-join" conf >/dev/null
  fi
done
# A nested node keeps its config in its own directory: regenerating node-b's
# and node-c's configs must leave node-a's file at the default path alone.
if [ -n "$KEY_A" ] && [ "$(grep '^PrivateKey' /etc/wireguard/wg0.conf | cut -d' ' -f3)" = "$KEY_A" ]; then
  pass "nested nodes left node-a's default wg0.conf alone"
else
  fmsg "a nested node overwrote /etc/wireguard/wg0.conf"
fi
conf_ok=1
for n in sma smb smc; do
  f=$(conf_of "$n")
  # 0600: the file holds this node's WireGuard private key.
  [ "$(stat -c '%a' "$f")" = 600 ] || conf_ok=0
  grep -q "$WG_PORT" "$f" || conf_ok=0
  grep -q "$JOIN_PORT" "$f" && conf_ok=0
  grep -q AllowedIPs "$f" || conf_ok=0
  # wg's parser rejects PresharedKey outside [Peer]; one per peer, no more.
  peers=$(grep -c '^\[Peer\]' "$f" 2>/dev/null); peers=${peers:-0}
  psk=$(grep -c '^PresharedKey' "$f" 2>/dev/null); psk=${psk:-0}
  [ "$psk" -eq "$peers" ] || conf_ok=0
done
if [ "$conf_ok" -eq 1 ]; then
  pass "wg0.conf on every node: WG port only, AllowedIPs, PSK per peer"
else
  fmsg "wg0.conf contents"
fi

# 12. the overlay addresses are unreachable before the tunnels exist.
ADDR_A=$(my_addr sma); ADDR_B=$(my_addr smb); ADDR_C=$(my_addr smc)
if ping_ok sma "$ADDR_B"; then
  fmsg "overlay address reachable without a tunnel (test would be vacuous)"
else
  pass "overlay addresses unreachable with no tunnel up"
fi

# 13. tunnels up in all three namespaces, then ping the overlay addresses.
bring_up sma && bring_up smb && bring_up smc || fmsg "wg0 bring-up"
# The first handshake takes a moment; retry the pings instead of sleeping once.
ping_wait() {
  i=0
  while [ "$i" -lt 6 ]; do
    ip netns exec "$1" ping -n -c 2 -W 3 "$2" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 2
  done
  return 1
}
if ping_wait sma "$ADDR_B" && ping_wait smb "$ADDR_A"; then
  pass "node-a <-> node-b through the WireGuard tunnel"
else
  fmsg "node-a <-> node-b tunnel ping"
  ip netns exec sma wg show 2>/dev/null | sed 's/^/    /'
fi
if ping_wait sma "$ADDR_C" && ping_wait smc "$ADDR_A"; then
  pass "node-a <-> node-c through the WireGuard tunnel"
else
  fmsg "node-a <-> node-c tunnel ping"
fi
if ip netns exec sma wg show 2>/dev/null | grep -q "endpoint: 10.99.0.2:$WG_PORT"; then
  pass "node-a's tunnel reports node-b's WireGuard endpoint"
else
  fmsg "wg show endpoints on node-a"
  ip netns exec sma wg show 2>/dev/null | sed 's/^/    /'
fi

# 13. stop the daemons; the reboot in the next phase must bring node-a's back
#     by itself, through the rc symlinks.
stop_daemon sma; stop_daemon smb; stop_daemon smc
if [ "$fail" -eq 0 ]; then exit 0; else exit 1; fi
REMOTE
then
  pass "three-node join: joins, membership, wg0.conf, tunnels"
else
  fail_msg "three-node join (see the FAIL lines above)"
fi

# --- Step 14: reboot the VM. The join daemons must come back through the
#     sysvinit script; the WireGuard tunnels cannot (netns do not survive a
#     boot), so the test rebuilds them and the configs must regenerate from
#     the state that survived. ---
vm_ssh 'sync; nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' >/dev/null 2>&1 || true
waited=0
until ! vm_ssh true 2>/dev/null; do
  if [ "$waited" -ge 60 ]; then break; fi
  sleep 2
  waited=$((waited + 2))
done
waited=0
until vm_ssh true 2>/dev/null; do
  if [ "$waited" -ge 180 ]; then
    fail_msg "ssh not reachable again within 180s after reboot"
    break
  fi
  sleep 5
  waited=$((waited + 5))
done

if vm_ssh 'bash -s' <<'REMOTE'
set -u
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fmsg() { printf 'FAIL: %s\n' "$1"; fail=1; }
BIN=/opt/supermox/bin
INITD=/etc/init.d/supermox-joind
WG_INITD=/etc/init.d/supermox-wg
JOIN_PORT=8743
WG_PORT=51820
. /opt/supermox/e2e-net.sh

# node-a's daemon is started by init at boot; its state is at the default
# /etc/supermox, which is what the service script reads.
sleep 2
if "$INITD" status | grep -q "is running"; then
  pass "join daemon came back at boot (init.d status)"
else
  fmsg "join daemon not running after reboot"
fi

# The overlay is a boot-time service: nothing in this test brings wg0 up by
# hand before this point, and the namespaces are gone after a reboot, so a
# wg0 interface in the host namespace here can only be init.d/supermox-wg
# having read /etc/wireguard/wg0.conf during boot.
if ip link show wg0 2>/dev/null | grep -q 'UP,LOWER_UP'; then
  pass "wg0 came up by itself at boot (init.d/supermox-wg)"
else
  fmsg "wg0 not up after boot: the overlay did not come up on its own"
  "$WG_INITD" status | sed 's/^/    /'
fi

names() {
  if [ "$1" = sma ]; then
    "$BIN/supermox-join" members
  else
    SUPERMOX_ETC="/etc/supermox/e2e/$1" "$BIN/supermox-join" members
  fi | awk '{print $1}' | sort | tr '\n' ' '
}
A=$(names sma); B=$(names smb); C=$(names smc)
if [ "$A" = "$B" ] && [ "$A" = "$C" ] && printf '%s\n' "$A" | grep -q node-c; then
  pass "membership survived the reboot on all three nodes ($A)"
else
  fmsg "membership after reboot: sma=$A smb=$B smc=$C"
fi

# node-a's config survived the reboot where the service script looks for it,
# still 0600, and the service script brings the tunnel up from it inside the
# namespace the cluster lives in (the netns themselves do not survive a boot,
# so the test recreates sma before asking the script to serve it).
if [ -f /etc/wireguard/wg0.conf ] && [ "$(stat -c '%a' /etc/wireguard/wg0.conf)" = 600 ]; then
  pass "node-a's WireGuard config survived the reboot at /etc/wireguard/wg0.conf"
else
  fmsg "node-a's WireGuard config missing or world-readable after reboot"
fi

# rebuild the tunnels from the persisted state and ping again.
net_star || fmsg "veth star after reboot"
bring_up() {
  ns=$1
  if [ "$ns" = sma ]; then
    "$BIN/supermox-join" conf >/dev/null || return 1
    ip netns exec "$ns" "$WG_INITD" start >/dev/null || return 1
  else
    SUPERMOX_ETC="/etc/supermox/e2e/$ns" SUPERMOX_WG_DIR="$(wg_dir_of "$ns")" "$BIN/supermox-join" conf >/dev/null || return 1
    manual_up "$ns" || return 1
  fi
}
my_addr() {
  grep '^Address' "$(conf_of "$1")" | head -n1 | awk '{print $3}' | cut -d/ -f1
}
ADDR_A=$(my_addr sma); ADDR_B=$(my_addr smb)
bring_up sma && bring_up smb || fmsg "wg0 bring-up after reboot"
ping_wait() {
  i=0
  while [ "$i" -lt 6 ]; do
    ip netns exec "$1" ping -n -c 2 -W 3 "$2" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 2
  done
  return 1
}
if ping_wait sma "$ADDR_B" && ping_wait smb "$ADDR_A"; then
  pass "the tunnel works again after the reboot"
else
  fmsg "tunnel ping after reboot"
  ip netns exec sma wg show 2>/dev/null | sed 's/^/    /'
fi
ip netns exec sma wg-quick down wg0 2>/dev/null
for n in smb smc; do ip netns exec "$n" ip link del wg0 2>/dev/null; done
for n in sma smb smc; do ip netns del "$n" 2>/dev/null; done
rm -f /etc/wireguard/wg0.conf
rm -rf /etc/wireguard/smb /etc/wireguard/smc
for v in veth-a veth-b veth-c veth-d; do ip link del "$v" 2>/dev/null; done
[ "$fail" -eq 0 ]
REMOTE
then
  pass "cluster survived the reboot"
else
  fail_msg "cluster did not survive the reboot"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll checks passed.\n'
  exit 0
fi
printf '\njoin-e2e: FAILURES ABOVE\n'
exit 1
