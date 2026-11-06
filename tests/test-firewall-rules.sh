#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Offline check for the pve-firewall patch that lets SuperMox cluster traffic
# through a node's host firewall (docs/cluster-core-join.md section 7).
# The rule generator is Perl inside upstream's Firewall.pm and the PVE perl
# modules are not installed on the build host, so this test drives the patch
# end to end - pristine upstream plus our patch series, applied with zero
# fuzz - and then replays the string building that produces the iptables
# matchers, asserting on the matchers themselves.
up=upstream/pxvirt/packages/pve-firewall/pve-firewall
if [ ! -d "$up" ]; then
  echo "SKIP"
  exit 0
fi

work=build/firewall-rules
rm -rf "$work"
mkdir -p "$work/pkg"
rsync -a --exclude .git "$up/" "$work/pkg/"

fail=0

# Apply the whole series: 0004 is written against the tree 0001-0003 produce,
# so applying it alone would shift every hunk and report a false offset.
for p in patches/pve-firewall/*.patch; do
  p="$PWD/$p"
  if ! out="$(cd "$work/pkg" && patch -p1 --forward --batch --no-backup-if-mismatch < "$p" 2>&1)"; then
    echo "FAIL: patch failed: $p"
    printf '%s\n' "$out"
    exit 1
  fi
  if printf '%s\n' "$out" | grep -qE 'fuzz|offset'; then
    echo "FAIL: $p applies with fuzz/offset"
    printf '%s\n' "$out" | grep -E 'fuzz|offset'
    exit 1
  fi
done

python3 - "$work/pkg/src/PVE/Firewall.pm" <<'PY'
import re
import sys

path = sys.argv[1]
src = open(path, encoding='utf-8').read()

m = re.search(r'^sub enable_host_firewall \{.*?^\}$', src, re.M | re.S)
if not m:
    print("FAIL: enable_host_firewall not found")
    sys.exit(1)
body = m.group(0)

# the rule fragments the generator builds once per compile
defs = dict(re.findall(r'my \$(\w+) = "([^"]*)";', body))
for var in ('corosync_rule', 'supermox_join_rule', 'supermox_wg_rule'):
    if var not in defs:
        print("FAIL: $%s is not defined in enable_host_firewall" % var)
        sys.exit(1)

# every quoted matcher handed to ruleset_addrule, with the fragments expanded;
# runtime values ($destination, $node_ip, ...) stay as placeholders.
strings = []
for s in re.findall(r'"((?:[^"\\]|\\)*)"', body):
    s = re.sub(r'\$(\w+)', lambda g: defs.get(g.group(1), '$' + g.group(1)), s)
    strings.append(s)

need = [
    ('-d $destination -s $node_ip -p udp --dport 5404:5412', 'corosync knet, inbound, pinned to one local/peer pair'),
    ('-s $source -d $node_ip -p udp --dport 5404:5412', 'corosync knet, outbound, pinned to one local/peer pair'),
    ('src -p tcp --dport 8743', 'the join daemon from the LAN (management ipset)'),
    ('src -p udp --dport 51820', 'WireGuard control channel from the LAN'),
    ('-d $destination -s $node_ip -p tcp --dport 8743', 'the join daemon over the overlay, inbound'),
    ('-s $source -d $node_ip -p tcp --dport 8743', 'the join daemon over the overlay, outbound'),
    ('-d $localnet -p tcp --dport 8743', 'the join daemon to the LAN, outbound'),
    ('-d $localnet -p udp --dport 51820', 'WireGuard control channel to the LAN, outbound'),
]
for needle, why in need:
    if not any(needle in s for s in strings):
        print("FAIL: no rule matching %r (%s)" % (needle, why))
        sys.exit(1)

print("firewall rules: %d matchers checked" % len(need))
PY

if grep -qiE 'systemd|journalctl' patches/pve-firewall/0004-cluster-traffic.patch; then
  echo "FAIL: the cluster traffic patch mentions systemd"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK"
