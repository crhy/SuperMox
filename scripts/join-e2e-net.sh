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

# conf_of <ns>: the node's WireGuard config, as the join daemon writes it.
# node-a keeps it at the default /etc/wireguard/wg0.conf; a nested node in its
# own directory below it (SUPERMOX_WG_DIR), since all three nodes share this
# host and the file must sit under /etc/wireguard/ for wg's AppArmor profile.
# wg_dir_of <ns>: the directory a node's config lives in, as the join daemon
# is told via SUPERMOX_WG_DIR. node-a keeps the default; a nested node gets
# its own directory below it. Every command that touches a nested node's
# state must set it, or that node writes at the default path and overwrites
# node-a's config - and brings up the wrong overlay in its own namespace.
wg_dir_of() {
  if [ "$1" = sma ]; then printf '/etc/wireguard'
  else printf '/etc/wireguard/%s' "$1"; fi
}

conf_of() { printf '%s/wg0.conf' "$(wg_dir_of "$1")"; }

# check_conf: every [Peer] Endpoint must name the WireGuard port, never the
# join daemon's port.
check_conf() {
  local n bad=0 e f
  for n in "$@"; do
    f=$(conf_of "$n")
    [ -f "$f" ] || { printf '    %s wg0.conf missing\n' "$n"; bad=1; continue; }
    while read -r e; do
      case "$e" in
        *:"$WG_PORT") ;;
        *) printf '    %s: Endpoint %s\n' "$n" "$e"; bad=1 ;;
      esac
    done < <(grep '^Endpoint = ' "$f" | cut -d' ' -f3)
    if grep -q "^Endpoint = .*:$JOIN_PORT" "$f"; then
      printf '    %s: wg0.conf points at the join port\n' "$n"; bad=1
    fi
  done
  return "$bad"
}

# manual_up <ns>: create wg0 in that namespace from the node's config. This is
# what /etc/init.d/supermox-wg does at boot through wg-quick, spelled out by
# hand so a config in a nested node's own directory works too: wg-quick names
# the interface after the file and cannot reach a subdirectory.
#
# wg setconf takes the [Interface] block minus the wg-quick-only Address line:
# PrivateKey belongs in it (without it the kernel generates a fresh keypair,
# every peer handshake then fails and the tunnel silently drops all traffic),
# and the per-peer PresharedKey lines belong in the [Peer] blocks. Only Address
# is dropped, and the address is added with ip -6 addr add instead.
#
# The setconf copy MUST live under /etc/wireguard/ and MUST be 0600: the AppArmor
# policy shipped with Devuan Ceres loads profile `wg` for /usr/bin/wg in ENFORCE
# mode and lets it read only @{etc_rw}/wireguard/{,**}, so `wg setconf` on a conf
# elsewhere fails with "fopen: Permission denied" and leaves wg0 with no keys.
# setconf failure is fatal here: an unconfigured wg0 silently drops every packet.
manual_up() {
  local ns="$1" conf aa
  conf=$(conf_of "$ns")
  aa="${conf%wg0.conf}setconf"
  ip netns exec "$ns" sh -c '
    CONF="$1" AA="$2"
    umask 077
    ip link add wg0 type wireguard
    A=$(grep "^Address" "$CONF" | cut -d" " -f3 | cut -d/ -f1)
    grep -v "^Address" "$CONF" > "$AA"
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
