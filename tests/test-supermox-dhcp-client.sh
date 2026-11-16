#!/usr/bin/env bash
# Behavioural test for the supermox-dhcp-client adapter
# (packaging/supermox-dhcp-client/usr/sbin/dhclient).
#
# What this guards:
#   * pve-container's PVE::LXC::manage_dhclient runs /sbin/dhclient with
#     -pf/-lf/-sf and an interface, and the LXC hook consumes the ISC contract
#     (reason, new_ip_address, router_count/router_N, new_domain_name_servers).
#     A maintained client (dhcpcd/udhcpc) knows none of those names, so the
#     translation is exactly the part that breaks silently.
#   * every file must land under $ROOTFS, and a failed request must not touch
#     the pid or lease files at all.
#   * unknown options must be refused with a usage line, not ignored.
#
# No real DHCP client, no network and no root are involved: the client and the
# hook are fakes in a sandbox under build/.
set -euo pipefail

cd "$(dirname "$0")/.."

script="packaging/supermox-dhcp-client/usr/sbin/dhclient"
if [ ! -f "$script" ]; then
  echo "FAIL: $script missing"
  exit 1
fi

tmp="build/test-dhcp-client"
rm -rf "$tmp"
mkdir -p "$tmp/bin"

# Fake maintained client: exports the binding the way udhcpc/dhcpcd do.
cat > "$tmp/bin/client" <<'EOF'
#!/bin/sh
printf 'interface=eth0\n'
printf 'ip=10.0.0.5\n'
printf 'subnet_mask=255.255.255.0\n'
printf 'router=192.168.0.1 10.0.0.1\n'
printf 'domain_name=example.org\n'
printf 'server=10.0.0.2 10.0.0.3\n'
EOF

# Fake client that fails (no binding at all).
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/bad-client"

# Stand-in busybox udhcpc: takes -q -n -p pidfile -s script -i iface, then runs
# the -s script with the binding exported the way busybox does.
cat > "$tmp/bin/udhcpc" <<'EOF'
#!/bin/sh
script=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) script="$2"; shift 2 ;;
    -p|-t|-i) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$script" ] || exit 1
ip=172.16.4.9 subnet_mask=255.255.255.0 router='10.0.0.1 10.0.0.2' \
  domain_name=ct.example server=10.0.0.7 interface=eth0 "$script"
EOF

# Stand-in dhcpcd that refuses the -s one-shot (as some builds do) and answers
# -G with "<interface> <address>", the fallback the adapter must handle.
cat > "$tmp/bin/dhcpcd" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    -s) exit 1 ;;
    -G) printf 'eth0 10.0.0.9\n'; exit 0 ;;
  esac
done
exit 1
EOF

# Fake -sf hook: dumps the contract it was handed, writing under $ROOTFS
# exactly as /usr/share/lxc/hooks/dhclient-script does.
cat > "$tmp/bin/hook" <<'EOF'
#!/bin/sh
mkdir -p "$ROOTFS/dumps"
{
  printf 'reason=%s\n' "$reason"
  printf 'interface=%s\n' "$interface"
  printf 'new_ip_address=%s\n' "$new_ip_address"
  printf 'new_subnet_mask=%s\n' "$new_subnet_mask"
  printf 'router_count=%s\n' "$router_count"
  printf 'router_1=%s\n' "$router_1"
  printf 'router_2=%s\n' "$router_2"
  printf 'new_domain_name=%s\n' "$new_domain_name"
  printf 'new_domain_name_servers=%s\n' "$new_domain_name_servers"
  printf 'pid=%s\n' "$pid"
  printf 'ROOTFS=%s\n' "${ROOTFS:-unset}"
} >> "$ROOTFS/dumps/hook.txt"
EOF

chmod +x "$tmp/bin/client" "$tmp/bin/bad-client" "$tmp/bin/hook" "$tmp/bin/udhcpc" "$tmp/bin/dhcpcd"

fail=0

expect() {
  # $1 = what is being checked, $2 = file, $3 = line that must be present
  if ! grep -qxF "$3" "$2"; then
    echo "FAIL: $1: no line '$3' in $2"
    fail=1
  fi
}

# --- bind: the hook sees the ISC contract --------------------------------
root="$tmp/root"
ROOTFS="$root" SUPERMOX_DHCP_CLIENT="$tmp/bin/client" \
  sh "$script" -pf /run/dhclient.pid -lf /var/lib/dhclient/dhclient.leases \
  -sf "$tmp/bin/hook" eth0

dump="$root/dumps/hook.txt"
if [ ! -f "$dump" ]; then
  echo "FAIL: the -sf hook was not run"
  fail=1
else
  expect "reason" "$dump" "reason=bind"
  expect "interface" "$dump" "interface=eth0"
  expect "address" "$dump" "new_ip_address=10.0.0.5"
  expect "subnet mask" "$dump" "new_subnet_mask=255.255.255.0"
  expect "router count" "$dump" "router_count=2"
  expect "router 1" "$dump" "router_1=192.168.0.1"
  expect "router 2" "$dump" "router_2=10.0.0.1"
  expect "domain name" "$dump" "new_domain_name=example.org"
  expect "DNS servers" "$dump" "new_domain_name_servers=10.0.0.2, 10.0.0.3"
  expect "ROOTFS passed to the hook" "$dump" "ROOTFS=$root"
  if ! grep -qE '^pid=[0-9]+$' "$dump"; then
    echo "FAIL: pid not exported: $(grep '^pid=' "$dump")"
    fail=1
  fi
fi

# --- the pid and lease files land where -pf/-lf said ----------------------
pidfile="$root/run/dhclient.pid"
leases="$root/var/lib/dhclient/dhclient.leases"
if [ ! -f "$pidfile" ]; then
  echo "FAIL: -pf /run/dhclient.pid did not write $root/run/dhclient.pid"
  fail=1
elif ! grep -qE '^[0-9]+$' "$pidfile"; then
  echo "FAIL: pid file does not hold a pid: $(cat "$pidfile")"
  fail=1
fi
if [ ! -f "$leases" ]; then
  echo "FAIL: -lf did not write $root/var/lib/dhclient/dhclient.leases"
  fail=1
else
  for want in 'interface eth0;' 'fixed-address 10.0.0.5;' \
    'subnet-mask 255.255.255.0;' 'domain-name-servers 10.0.0.2;' \
    'host-router 192.168.0.1;'; do
    if ! grep -qF "$want" "$leases"; then
      echo "FAIL: lease record missing '$want'"
      fail=1
    fi
  done
fi

# --- ROOTFS: nothing at all is written outside the prefix ----------------
before="$(find "$tmp" | sort)"
root2="$tmp/root2"
ROOTFS="$root2" SUPERMOX_DHCP_CLIENT="$tmp/bin/client" \
  sh "$script" -pf /run/pid2 -lf /var/lib/leases2 -sf "$tmp/bin/hook" eth0
after="$(find "$tmp" | sort)"
stray="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") |
  grep -vE "^$root2(/|$)" || true)"
if [ -n "$stray" ]; then
  echo "FAIL: wrote outside the ROOTFS prefix:"
  printf '%s\n' "$stray"
  fail=1
fi
for want in "$root2/run/pid2" "$root2/var/lib/leases2" "$root2/dumps/hook.txt"; do
  if [ ! -f "$want" ]; then
    echo "FAIL: $want not created under the new ROOTFS"
    fail=1
  fi
done
if [ -e "$tmp/run" ] || [ -e "$tmp/var" ]; then
  echo "FAIL: sandbox root got run/ or var/ (ROOTFS ignored)"
  fail=1
fi

# --- the maintained client itself: udhcpc, and dhcpcd's -G fallback ------
root6="$tmp/root6"
ROOTFS="$root6" SUPERMOX_DHCP_CLIENT="$tmp/bin/udhcpc" \
  sh "$script" -q -1 --timeout 5 -pf /run/pid6 -lf /var/lib/leases6 \
  -sf "$tmp/bin/hook" eth0
d6="$root6/dumps/hook.txt"
if [ ! -f "$d6" ]; then
  echo "FAIL: the udhcpc path produced no binding"
  fail=1
else
  expect "udhcpc address" "$d6" "new_ip_address=172.16.4.9"
  expect "udhcpc routers" "$d6" "router_count=2"
  expect "udhcpc interface" "$d6" "interface=eth0"
fi
if [ ! -f "$root6/run/pid6" ]; then
  echo "FAIL: udhcpc path did not write the -pf file"
  fail=1
fi

root7="$tmp/root7"
ROOTFS="$root7" SUPERMOX_DHCP_CLIENT="$tmp/bin/dhcpcd" \
  sh "$script" -pf /run/pid7 -lf /var/lib/leases7 -sf "$tmp/bin/hook" eth0
d7="$root7/dumps/hook.txt"
if [ ! -f "$d7" ]; then
  echo "FAIL: dhcpcd -G fallback produced no binding"
  fail=1
else
  expect "dhcpcd -G address" "$d7" "new_ip_address=10.0.0.9"
  expect "dhcpcd -G interface" "$d7" "interface=eth0"
fi

# --- a failing client: reason=fail, no files, hook not called ------------
rc=0
root3="$tmp/root3"
ROOTFS="$root3" SUPERMOX_DHCP_CLIENT="$tmp/bin/bad-client" \
  sh "$script" -pf /run/pid3 -lf /var/lib/leases3 -sf "$tmp/bin/hook" eth0 \
  2> "$tmp/bad.err" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: adapter exited 0 although the DHCP client failed"
  fail=1
fi
if [ -e "$root3" ]; then
  echo "FAIL: a failed request wrote under $root3"
  fail=1
fi
if ! grep -q 'reason=fail' "$script"; then
  echo "FAIL: adapter does not export reason=fail on failure"
  fail=1
fi

# --- --release: the hook runs once, with reason=release -----------------
root4="$tmp/root4"
ROOTFS="$root4" SUPERMOX_DHCP_CLIENT="$tmp/bin/client" \
  sh "$script" --release -pf /run/pid4 -lf /var/lib/leases4 \
  -sf "$tmp/bin/hook" eth0
d4="$root4/dumps/hook.txt"
if [ ! -f "$d4" ]; then
  echo "FAIL: --release did not run the hook"
  fail=1
else
  expect "--release reason" "$d4" "reason=release"
  if [ "$(grep -c '^reason=' "$d4")" -ne 1 ]; then
    echo "FAIL: --release ran the hook more than once"
    fail=1
  fi
fi

# --- an unknown option is refused, not ignored ---------------------------
rc=0
sh "$script" --not-an-isc-option 2> "$tmp/unknown.err" || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: unknown option exited $rc, expected 2"
  fail=1
fi
if ! grep -q '^usage: dhclient' "$tmp/unknown.err"; then
  echo "FAIL: unknown option printed no usage line"
  fail=1
fi

# --- -sf absent: the ISC default hook is used ----------------------------
rc=0
ROOTFS="$tmp/root5" SUPERMOX_DHCP_CLIENT="$tmp/bin/client" \
  sh "$script" -pf /run/pid5 eth0 2> "$tmp/default.err" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "FAIL: succeeded although the default hook path has no hook"
  fail=1
fi
if ! grep -q '/usr/share/lxc/hooks/dhclient-script' "$tmp/default.err"; then
  echo "FAIL: default -sf is not /usr/share/lxc/hooks/dhclient-script"
  fail=1
fi

# --- nothing we ship uses systemd ----------------------------------------
# The shipped script must not mention systemd at all; the debian/ files may
# only mention it to promise it is absent, which the gate pattern catches.
if grep -qi systemd "$script"; then
  echo "FAIL: the adapter mentions systemd"
  fail=1
fi
if grep -riE '\.service|\.unit\b|systemctl|sd_notify|libsystemd|ExecStart' \
  packaging/supermox-dhcp-client/; then
  echo "FAIL: systemd reference under packaging/supermox-dhcp-client/"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-dhcp-client translates a maintained client into the ISC contract"
