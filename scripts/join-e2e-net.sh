# shellcheck shell=bash
# join-e2e-net.sh - veth star + wg0 bring-up helpers for join-e2e.sh.
# SOURCED, not executed: it has no shebang on purpose.
#
# Copied into the test VM and SOURCED by both phases of join-e2e.sh: the
# pre-reboot join phase and the post-reboot phase. A reboot destroys the
# namespaces and the tunnels but not the node state, so the same network
# set-up and bring-up code has to run twice; this file is what keeps the
# post-reboot phase honest about testing the SAME topology.
#
# The sourcing shell defines: JOIN_PORT (TCP join daemon), WG_PORT (UDP
# WireGuard), STATE (per-node state dirs $STATE/{sma,smb,smc}), BIN, and
# fmsg (records a failure).

# net_star: three namespaces, sma is the veth hub. One subnet per veth pair,
# plus a route in each leaf for the OTHER pair's subnet: a veth carries packets
# regardless of subnet labels, so without that route a leaf cannot address the
# hub's other endpoint and its tunnel to that peer silently loses everything.
net_star() {
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
}

net_teardown() {
  for n in sma smb smc; do
    ip netns del "$n" 2>/dev/null
    rm -rf "/etc/wireguard/$n"
  done
  for v in veth-a veth-b veth-c veth-d; do ip link del "$v" 2>/dev/null; done
}

# check_conf: every [Peer] Endpoint must name the WireGuard port, never the
# join daemon's port.
check_conf() {
  local n bad=0 e
  for n in "$@"; do
    [ -f "$STATE/$n/wg0.conf" ] || { printf '    %s/wg0.conf missing\n' "$n"; bad=1; continue; }
    while read -r e; do
      case "$e" in
        *:"$WG_PORT") ;;
        *) printf '    %s: Endpoint %s\n' "$n" "$e"; bad=1 ;;
      esac
    done < <(grep '^Endpoint = ' "$STATE/$n/wg0.conf" | cut -d' ' -f3)
    if grep -q "^Endpoint = .*:$JOIN_PORT" "$STATE/$n/wg0.conf"; then
      printf '    %s: wg0.conf points at the join port\n' "$n"; bad=1
    fi
  done
  return "$bad"
}

# bring_up <ns>: create wg0 in that namespace from $STATE/<ns>/wg0.conf. This
# iproute2 names the device type "wireguard"; setconf rejects the Address and
# PresharedKey lines, so the address is added with ip addr add and the (optional)
# PSK stays in the conf file only. Peers are reached at their overlay address.
#
# The setconf copy MUST live under /etc/wireguard/: the AppArmor policy shipped
# with Devuan Ceres loads profile `wg` for /usr/bin/wg in ENFORCE mode and lets
# it read only @{etc_rw}/wireguard/{,**}, so `wg setconf` on a conf elsewhere
# (e.g. $STATE/<ns>/wg0.conf or /etc/supermox/wg0.conf) fails with
# "fopen: Permission denied" and leaves wg0 with no keys. One directory per
# namespace, since all three nodes share this host. setconf failure is fatal
# here: an unconfigured wg0 silently drops every packet.
bring_up() {
  local ns="$1" conf="$STATE/$1/wg0.conf" aa="/etc/wireguard/$1/wg0.conf"
  ip netns exec "$ns" sh -c '
    CONF="$1" AA="$2"
    ip link add wg0 type wireguard
    A=$(grep "^Address" "$CONF" | cut -d" " -f3 | cut -d/ -f1)
    mkdir -p "$(dirname "$AA")"
    grep -v -e "^Address" -e "^PresharedKey" "$CONF" > "$AA"
    if ! wg setconf wg0 "$AA"; then
      echo "wg setconf failed on $AA (AppArmor wg profile reads only /etc/wireguard/**)" >&2
      exit 1
    fi
    ip -6 addr add "$A/128" dev wg0
    ip link set wg0 up
    grep "^AllowedIPs" "$CONF" | cut -d" " -f3 | while read ip; do
      ip -6 route add "$ip" dev wg0
    done
  ' sh "$conf" "$aa" || fmsg "wg0 bring-up failed in $ns"
}

# ping_across <from-ns> <overlay-address> <label>: the only proof the tunnel
# actually carries traffic; an unconfigured wg0 answers nothing.
ping_across() {
  local from="$1" to="$2" label="$3"
  if ip netns exec "$from" ping -n -c 3 "$to" >/run/ping.log 2>&1; then
    pass "$label"
    sed 's/^/    /' /run/ping.log
  else
    fmsg "$label"; sed 's/^/    /' /run/ping.log
  fi
}
