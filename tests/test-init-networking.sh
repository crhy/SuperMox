#!/usr/bin/env bash
# Behavioural test for init.d/networking DHCP handling.
#
# Two regressions this guards:
#   * Devuan's dhcpcd-base installs /sbin/dhcpcd, not /usr/sbin/dhcpcd. A check
#     hard-coded to /usr/sbin silently skipped DHCP and the VM booted with no
#     network, so ssh never answered.
#   * ifupdown2 drags /sbin/dhclient in even though /etc/network/interfaces has
#     no "inet dhcp" stanza. Treating dhclient's presence as a reason to skip
#     dhcpcd left eth0 unconfigured.
#
# The script is copied into a sandbox with its absolute paths rewritten to the
# sandbox, so no root and no real network commands are involved.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/networking"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-init-networking.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/usr/sbin" "$tmp/sbin" "$tmp/run" "$tmp/etc/network"

sed \
  -e "s#/\(usr/\)\?sbin/dhcpcd#$tmp/\1sbin/dhcpcd#g" \
  -e "s#/sbin/dhclient#$tmp/sbin/dhclient#g" \
  -e "s#/run/dhcpcd.pid#$tmp/run/dhcpcd.pid#g" \
  -e "s#/run/network#$tmp/run/network#g" \
  -e "s#/etc/network/run#$tmp/etc/network/run#g" \
  "$src" > "$tmp/networking"

# Fake ifupdown2 front ends: record the call order, succeed.
for c in ifup ifdown ifreload; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$c" "$tmp" > "$tmp/bin/$c"
  chmod +x "$tmp/bin/$c"
done

# Fake dhcpcd: record that it ran, leave a pid file like the real daemon would.
printf '#!/bin/bash\necho ran >> "%s/dhcpcd-ran"\necho $$ > "%s/run/dhcpcd.pid"\n' \
  "$tmp" "$tmp" > "$tmp/dhcpcd"
chmod +x "$tmp/dhcpcd"

# Fake dhclient: must never be executed by our script.
printf '#!/bin/bash\necho ran >> "%s/dhclient-ran"\n' "$tmp" > "$tmp/sbin/dhclient"
chmod +x "$tmp/sbin/dhclient"

fail=0

run_start() {
  rm -f "$tmp/calls" "$tmp/dhcpcd-ran" "$tmp/dhclient-ran" "$tmp/run/dhcpcd.pid"
  PATH="$tmp/bin:$PATH" bash "$tmp/networking" start
}

# Case 1: dhcpcd only at the Devuan path, dhclient present. dhcpcd must still run.
cp "$tmp/dhcpcd" "$tmp/sbin/dhcpcd"
if ! run_start; then
  echo "FAIL: networking start exited non-zero (Devuan dhcpcd path)"
  fail=1
fi
if [ ! -f "$tmp/dhcpcd-ran" ]; then
  echo "FAIL: dhcpcd not started when only /sbin/dhcpcd exists and dhclient is present"
  fail=1
fi
if [ -f "$tmp/dhclient-ran" ]; then
  echo "FAIL: dhclient was executed"
  fail=1
fi
if ! grep -q '^ifup -a' "$tmp/calls" 2>/dev/null; then
  echo "FAIL: ifup -a not called"
  fail=1
fi

# Case 2: dhcpcd only at the Debian path. Must still run.
rm -f "$tmp/sbin/dhcpcd"
cp "$tmp/dhcpcd" "$tmp/usr/sbin/dhcpcd"
if ! run_start; then
  echo "FAIL: networking start exited non-zero (Debian dhcpcd path)"
  fail=1
fi
if [ ! -f "$tmp/dhcpcd-ran" ]; then
  echo "FAIL: dhcpcd not started when only /usr/sbin/dhcpcd exists"
  fail=1
fi

# Case 3: no DHCP client at all. Must not fail the boot.
rm -f "$tmp/usr/sbin/dhcpcd" "$tmp/sbin/dhclient"
if ! run_start; then
  echo "FAIL: networking start exited non-zero with no DHCP client installed"
  fail=1
fi
if [ -f "$tmp/dhcpcd-ran" ]; then
  echo "FAIL: dhcpcd reported as run with no client installed"
  fail=1
fi

# Case 4: stop must not fail when no dhcpcd pid file is around.
rm -f "$tmp/run/dhcpcd.pid"
if ! PATH="$tmp/bin:$PATH" bash "$tmp/networking" stop; then
  echo "FAIL: networking stop exited non-zero with no dhcpcd running"
  fail=1
fi

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/networking DHCP handling"
