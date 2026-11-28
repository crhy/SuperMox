#!/usr/bin/env bash
# Guard for the supermox-dhcp-client thin alias (packaging/supermox-dhcp-client).
#
# Rewritten by smx02 (crhy/SuperMox#9): this test used to exercise the
# /usr/sbin/dhclient adapter the package shipped. The task folded the two
# DHCP answers into one path: the patched pve-container (0003-maintained-
# dhcp-client.patch) probes the container image's own client and runs it
# through the pve-container-bundled /usr/share/lxc/hooks/pve-dhcp-client,
# which tests/test-dhcp-client-port.sh guards. The host adapter is gone, so
# this test now guards the opposite: the adapter must NOT come back, and the
# alias must stay one dependency deep with no claim on the dhclient name.
#
# What this guards:
#   * the package ships no files: no usr/sbin/dhclient can come back (the
#     interim isc-dhcp fork is the only package that may own /usr/sbin/dhclient);
#   * no Provides/Replaces/Conflicts on isc-dhcp-client: an alias that
#     re-declared the virtual name would fork the single path in two again;
#   * the alias points at the one path: Depends pve-container;
#   * debian/rules installs nothing;
#   * nothing under the package mentions systemd.
set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packaging/supermox-dhcp-client"
fail=0

error() {
  echo "FAIL: $*"
  fail=1
}

for f in "$pkg/debian/control" "$pkg/debian/rules" "$pkg/debian/changelog"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing file: $f"
    exit 1
  fi
done

# --- the host adapter is gone, and cannot sneak back ----------------------
if [ -e "$pkg/usr/sbin/dhclient" ] || [ -e "$pkg/usr" ]; then
  echo "FAIL: $pkg still ships a usr tree; the single path's adapter lives in pve-container"
  exit 1
fi
if find "$pkg" -type f -name 'dhclient' | grep -q .; then
  echo "FAIL: a dhclient file reappeared under $pkg/"
  exit 1
fi
if grep -qiE 'dhclient' "$pkg/debian/rules"; then
  echo "FAIL: $pkg/debian/rules installs a dhclient again"
  error "rules must install nothing"
fi

# --- the virtual name is not claimed --------------------------------------
if grep -qE '^(Provides|Replaces|Conflicts):' "$pkg/debian/control"; then
  error "$pkg/debian/control declares Provides/Replaces/Conflicts again: with the interim isc-dhcp fork owning /usr/sbin/dhclient, any claim on the virtual name forks the path in two"
fi

# --- the alias points at the one path --------------------------------------
if ! awk '/^Package: supermox-dhcp-client$/,/^$/' "$pkg/debian/control" |
  grep -qE '^Depends:.*pve-container'; then
  error "$pkg/debian/control does not depend on pve-container, the package carrying the adapter"
fi
# The one path itself must still be there: the patch that carries the adapter.
if [ ! -f "patches/pve-container/0003-maintained-dhcp-client.patch" ]; then
  error "patches/pve-container/0003-maintained-dhcp-client.patch missing: the alias points at nothing"
fi

# --- the interim fork stays the only owner of /usr/sbin/dhclient -----------
# Dropping it is a separate decision (listed in the notes); re-owning the
# path here is not that decision's substitute.
if [ ! -f "patches/isc-dhcp/0001-supermox.patch" ]; then
  error "patches/isc-dhcp/0001-supermox.patch missing while the alias defers to it for /usr/sbin/dhclient"
fi
if ! grep -qE 'isc-dhcp-client \(>= 4\.4\.3-P1-8\+supermox1\)' packaging/supermox-ve/debian/control; then
  error "supermox-ve no longer pins the interim isc-dhcp fork that owns /usr/sbin/dhclient"
fi

# --- no package under packaging/ ships a dhclient file --------------------
if find packaging -type f -name 'dhclient' | grep -q .; then
  error "some packaging/ source ships a dhclient file; exactly zero may"
fi

# --- nothing we ship uses systemd -----------------------------------------
if grep -riE '\.service|\.unit\b|systemctl|sd_notify|libsystemd|ExecStart' "$pkg/"; then
  error "systemd reference under $pkg/"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-dhcp-client is a thin alias: no dhclient file, no isc-dhcp virtual, Depends pve-container (the one path)"
