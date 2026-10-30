#!/usr/bin/env bash
# join-e2e.sh - real WireGuard join between network namespaces inside the TEST VM.
#
# Runs on this PC and drives the test VM over ssh (the VM is root; this PC is not).
# The test VM must already be started (SUPERMOX_VM_SSH_PORT=2224) per
# .strata/t49c-join-e2e.md. Prints PASS/FAIL per step and exits 1 on any FAIL.
#
# Topology (veth star, sma is the hub, one subnet per veth pair):
#   sma <-> smb : 10.99.0.1 / 10.99.0.2
#   sma <-> smc : 10.99.1.1 / 10.99.1.2
#   Each leaf also carries a route for the OTHER pair's subnet through its own
#   veth. A veth transfers packets regardless of subnet labels, so smc can
#   reach 10.99.0.1 (veth-d -> veth-c into sma -> delivered on veth-a's address
#   there). Without that route a leaf cannot address the hub's other endpoint
#   and its WireGuard tunnel to that peer silently loses every packet.
# Two ports, never conflated:
#   join daemon (TCP)     8743   - supermox-joind, where joins are sent
#   WireGuard (UDP)       51820  - the [Peer] Endpoint in wg0.conf
#   node-a (sma) runs the join daemon on 0.0.0.0:8743 and advertises
#   10.99.0.1:8743; its WireGuard endpoint is 10.99.0.1:51820.
#   node-b (smb) joins by phrase; node-c (smc) joins by invite (approved in sma).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
VM_SSH_PORT="${SUPERMOX_VM_SSH_PORT:-2224}"
# Join daemon port (TCP 8743) and WireGuard port (UDP 51820) are kept distinct
# on purpose; the values live in the remote shell, see the REMOTE block below.

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

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_msg() { printf 'FAIL: %s\n' "$1"; fail=1; }

# --- Step 1: copy src/supermox and bin/supermox-join into the VM (/opt/supermox) ---
if tar -C "$repo_root" -czf - src/supermox bin/supermox-join bin/supermox-joind \
  | vm_ssh 'rm -rf /opt/supermox; mkdir -p /opt/supermox; tar -xzf - -C /opt/supermox'; then
  pass "copied src/supermox and bin/supermox-join + supermox-joind to /opt/supermox"
else
  fail_msg "copy to /opt/supermox"
fi

# --- Step 2: install python deps + wireguard-tools (tolerate no apt; verify imports) ---
if vm_ssh 'export DEBIAN_FRONTEND=noninteractive
apt-get -y install python3-mnemonic python3-nacl python3-qrcode python3-cryptography wireguard-tools >/dev/null 2>&1 || true
python3 -c "import nacl, mnemonic, qrcode, cryptography" && test -x /usr/bin/wg'; then
  pass "python deps + wireguard-tools present in the VM"
else
  fail_msg "python deps / wireguard-tools"
fi

# --- Steps 3-6: the join itself, all inside one remote shell so the 12 words
#     live only in a shell variable (never a file). ---
if vm_ssh 'bash -s' <<'REMOTE'
set -u
fail=0
# Join daemon (TCP) vs WireGuard (UDP): two different ports, always.
JOIN_PORT=8743
WG_PORT=51820
pass() { printf 'PASS: %s\n' "$1"; }
fmsg() { printf 'FAIL: %s\n' "$1"; fail=1; }

BIN=/opt/supermox/bin
cleanup() {
  [ -n "${DAEMON:-}" ] && kill "$DAEMON" 2>/dev/null
  for n in sma smb smc; do ip netns del "$n" 2>/dev/null; done
}
trap cleanup EXIT

# clean slate (state and veth from any earlier run)
for n in sma smb smc; do ip netns del "$n" 2>/dev/null; done
for v in veth-a veth-b veth-c veth-d; do ip link del "$v" 2>/dev/null; done
rm -rf /run/sma /run/smb /run/smc
rm -f /run/joind.log /run/ping.log /run/join-c.log /run/approve.log

# 3a. namespaces + veth star (one subnet for the whole star, see the header)
ip netns add sma && ip netns add smb && ip netns add smc
ip link add veth-a type veth peer name veth-b
ip link add veth-c type veth peer name veth-d
ip link set veth-a netns sma && ip link set veth-b netns smb
ip link set veth-c netns sma && ip link set veth-d netns smc
ip netns exec sma ip link set lo up
ip netns exec sma ip addr add 10.99.0.1/24 dev veth-a && ip netns exec sma ip link set veth-a up
ip netns exec sma ip addr add 10.99.1.1/24 dev veth-c && ip netns exec sma ip link set veth-c up
ip netns exec smb ip addr add 10.99.0.2/24 dev veth-b && ip netns exec smb ip link set veth-b up
ip netns exec smc ip addr add 10.99.1.2/24 dev veth-d && ip netns exec smc ip link set veth-d up
ip netns exec smb ip route add 10.99.1.0/24 dev veth-b
ip netns exec smc ip route add 10.99.0.0/24 dev veth-d
if ip netns exec sma ip link show veth-a >/dev/null 2>&1 \
   && ip netns exec smb ip link show veth-b >/dev/null 2>&1 \
   && ip netns exec sma ip link show veth-c >/dev/null 2>&1 \
   && ip netns exec smc ip link show veth-d >/dev/null 2>&1; then
  pass "namespaces sma/smb/smc + veth star up"
else
  fmsg "namespaces/veth setup"
fi

# 3b. create the cluster in sma; capture the 12 words into a variable only.
#     --endpoint is the join daemon (8743); --my-wg-endpoint is the WireGuard
#     endpoint (51820) the other members' wg0.conf must point at.
W="$(ip netns exec sma env SUPERMOX_ETC=/run/sma "$BIN/supermox-join" create --name node-a --endpoint 10.99.0.1:$JOIN_PORT --my-wg-endpoint 10.99.0.1:$WG_PORT | tail -n1)"
nw=$(printf '%s\n' "$W" | wc -w)
if [ "$nw" -eq 12 ]; then
  pass "create node-a (captured 12 words into \$W, not a file)"
else
  fmsg "create node-a (got $nw words)"
fi

# 3c. start the join daemon in sma (background) and wait for it to listen.
ip netns exec sma env SUPERMOX_ETC=/run/sma "$BIN/supermox-joind" --host 0.0.0.0 --port $JOIN_PORT >/run/joind.log 2>&1 &
DAEMON=$!
up=0
for _ in $(seq 1 20); do
  if ip netns exec smb timeout 3 bash -c 'exec 3<>/dev/tcp/10.99.0.1/'"$JOIN_PORT" 2>/dev/null; then up=1; break; fi
  sleep 0.5
done
if [ "$up" -eq 1 ]; then
  pass "join daemon listening in sma"
else
  fmsg "join daemon not listening"; sed 's/^/    /' /run/joind.log 2>/dev/null
fi

# 3d. node-b joins by phrase from smb (advertise its join daemon AND its
#     WireGuard endpoint separately).
out=$(ip netns exec smb env SUPERMOX_ETC=/run/smb "$BIN/supermox-join" join --words "$W" --endpoint 10.99.0.1:$JOIN_PORT --name node-b --my-endpoint 10.99.0.2:$JOIN_PORT --my-wg-endpoint 10.99.0.2:$WG_PORT 2>&1)
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -q '^joined as node-b'; then
  pass "node-b phrase join"
else
  fmsg "node-b phrase join"
fi

# 4. bring up wg0 in sma and smb from their wg0.conf, then ping across the tunnel.
# node-a's wg0.conf is regenerated from its (now two-member) state.
# 4. wg0.conf must name the WireGuard port for every peer, never the join port.
check_conf() {
  bad=0
  for n in "$@"; do
    [ -f "/run/$n/wg0.conf" ] || { printf '    /run/%s/wg0.conf missing\n' "$n"; bad=1; continue; }
    while read -r e; do
      case "$e" in
        *:$WG_PORT) ;;
        *) printf '    %s: Endpoint %s\n' "$n" "$e"; bad=1 ;;
      esac
    done < <(grep '^Endpoint = ' "/run/$n/wg0.conf" | cut -d' ' -f3)
    if grep -q "^Endpoint = .*:$JOIN_PORT" "/run/$n/wg0.conf"; then
      printf '    %s: wg0.conf points at the join port\n' "$n"; bad=1
    fi
  done
  return "$bad"
}
for n in sma smb; do
  SUPERMOX_ETC=/run/$n "$BIN/supermox-join" conf >/dev/null || fmsg "conf for $n"
done
if check_conf sma smb; then
  pass "wg0.conf [Peer] Endpoint is host:$WG_PORT, never the join port"
else
  fmsg "wg0.conf [Peer] Endpoint port"
fi

# bring_up <ns> creates wg0 in that namespace from /run/<ns>/wg0.conf. This
# iproute2 names the device type "wireguard"; setconf here rejects the Address
# and PresharedKey lines, so the address is added with ip addr add and the
# (optional) PSK stays in the conf file only. Peers are reached at their
# overlay address (the AllowedIPs value).
bring_up() {
  local ns="$1" conf="/run/$1/wg0.conf"
  ip netns exec "$ns" sh -c '
    CONF="$1"
    ip link add wg0 type wireguard
    A=$(grep "^Address" "$CONF" | cut -d" " -f3 | cut -d/ -f1)
    grep -v -e "^Address" -e "^PresharedKey" "$CONF" > "$CONF.setconf"
    wg setconf wg0 "$CONF.setconf"
    ip -6 addr add "$A/128" dev wg0
    ip link set wg0 up
    grep "^AllowedIPs" "$CONF" | cut -d" " -f3 | while read ip; do
      ip -6 route add "$ip" dev wg0
    done
  ' sh "$conf" || fmsg "wg0 bring-up failed in $ns"
}

# 5. invite join for node-c (smc): invite from sma, join in smc, approve in sma.
URI=$(ip netns exec sma env SUPERMOX_ETC=/run/sma "$BIN/supermox-join" invite --ttl 900 | head -n1)
ip netns exec smc env SUPERMOX_ETC=/run/smc "$BIN/supermox-join" join --uri "$URI" --endpoint 10.99.1.1:$JOIN_PORT --name node-c --my-endpoint 10.99.1.2:$JOIN_PORT --my-wg-endpoint 10.99.1.2:$WG_PORT >/run/join-c.log 2>&1 &
JC=$!
rid=""
for _ in $(seq 1 20); do
  rid=$(ip netns exec sma env SUPERMOX_ETC=/run/sma "$BIN/supermox-join" pending 2>/dev/null | awk '$1!="no"{print $1; exit}')
  [ -n "$rid" ] && break
  sleep 0.5
done
if [ -n "$rid" ]; then
  pass "node-c invite join pending (request $rid)"
  if ip netns exec sma env SUPERMOX_ETC=/run/sma "$BIN/supermox-join" approve "$rid" --endpoint 127.0.0.1:$JOIN_PORT >/run/approve.log 2>&1; then
    pass "approved node-c join request"
  else
    fmsg "approve node-c"; sed 's/^/    /' /run/approve.log
  fi
else
  fmsg "node-c invite join never went pending"
fi
wait "$JC" 2>/dev/null
if grep -q '^joined as node-c' /run/join-c.log; then
  pass "node-c invite join completed"
else
  fmsg "node-c invite join"; sed 's/^/    /' /run/join-c.log
fi

# 6. all three tunnels: regenerate confs, bring up wg0 everywhere, ping.
for n in sma smb smc; do
  SUPERMOX_ETC=/run/$n "$BIN/supermox-join" conf >/dev/null || fmsg "conf for $n"
done
if check_conf sma smb smc; then
  pass "all three wg0.conf files name host:$WG_PORT for every peer"
else
  fmsg "wg0.conf after node-c joined"
fi
ADDR_A=$(grep -m1 '^Address = ' /run/sma/wg0.conf | awk '{print $3}' | cut -d/ -f1)
ADDR_B=$(grep -m1 '^Address = ' /run/smb/wg0.conf | awk '{print $3}' | cut -d/ -f1)
ADDR_C=$(grep -m1 '^Address = ' /run/smc/wg0.conf | awk '{print $3}' | cut -d/ -f1)
bring_up sma
bring_up smb
bring_up smc
sleep 1
ping_across() {
  local from="$1" to="$2" label="$3"
  if ip netns exec "$from" ping -n -c 3 "$to" >/run/ping.log 2>&1; then
    pass "$label"
    sed 's/^/    /' /run/ping.log
  else
    fmsg "$label"; sed 's/^/    /' /run/ping.log
  fi
}
ping_across smb "$ADDR_A" "smb pings node-a over wg0 ($ADDR_A)"
ping_across smc "$ADDR_A" "smc pings node-a over wg0 ($ADDR_A)"
ping_across sma "$ADDR_B" "sma pings node-b over wg0 ($ADDR_B)"
ping_across sma "$ADDR_C" "sma pings node-c over wg0 ($ADDR_C)"

# 7. the 12-word phrase must not appear in any state file.
if [ -z "$W" ]; then
  fmsg "leak check skipped (no phrase captured)"
elif grep -rqF "$W" /run/sma /run/smb /run/smc 2>/dev/null; then
  fmsg "the 12-word phrase leaked into a state file"
else
  pass "no 12-word phrase in /run/sma /run/smb /run/smc"
fi

exit "$fail"
REMOTE
then
  pass "join sequence (create/join/wg0/invite/approve/leak-check)"
else
  fail_msg "join sequence"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
printf 'ALL STEPS PASSED.\n'
