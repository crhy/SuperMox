#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/fetch-upstream.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

mapfile -t lines < <(bash "$target" --list)

count=${#lines[@]}
if [ "$count" -ne 16 ]; then
  echo "FAIL: --list printed $count lines, expected 16"
  exit 1
fi

for want in pve-cluster pve-access-control proxmox-perl-rs rrdtool isc-dhcp; do
  found=0
  for l in "${lines[@]}"; do
    if [ "$l" = "$want" ]; then
      found=1
    fi
  done
  if [ "$found" -ne 1 ]; then
    echo "FAIL: --list did not include $want"
    exit 1
  fi
done

ov_out="$(bash "$target" --list-overrides)"
ov_line="proxmox-perl-rs c6b798f72a7e9f1063d75b144835d63781006ef4"
if ! printf '%s\n' "$ov_out" | grep -qxF -- "$ov_line"; then
  echo "FAIL: --list-overrides did not print: $ov_line"
  printf '%s\n' "$ov_out"
  exit 1
fi

# Forked Debian source packages: pinned .dsc version plus the sha256 of that
# .dsc, so a silent upstream re-upload cannot change what we patch.
ds_out="$(bash "$target" --list-debian-src)"
ds_line="rrdtool 1.9.0-2.1 4953392378c0377a5b99fd08b217e0a7ae00c3abc8b092b6ae161c798640357e"
if ! printf '%s\n' "$ds_out" | grep -qxF -- "$ds_line"; then
  echo "FAIL: --list-debian-src did not print: $ds_line"
  printf '%s\n' "$ds_out"
  exit 1
fi
ds_line2="isc-dhcp 4.4.3-P1-8 8f11305d0d978e60114f596615b2cd605004802bb42587a95bf0806211880723"
if ! printf '%s\n' "$ds_out" | grep -qxF -- "$ds_line2"; then
  echo "FAIL: --list-debian-src did not print: $ds_line2"
  printf '%s\n' "$ds_out"
  exit 1
fi

# The two source layouts (pxvirt submodules, unpacked Debian sources) are resolved
# through --src-dir; the build scripts must not hardcode either path.
for pair in "pve-cluster upstream/pxvirt/packages/pve-cluster/pve-cluster" \
            "rrdtool upstream/debian-src/rrdtool/rrdtool" \
            "isc-dhcp upstream/debian-src/isc-dhcp/isc-dhcp"; do
  read -r want_c want_d <<< "$pair"
  got="$(UPSTREAM_PACKAGES="upstream/pxvirt/packages" UPSTREAM_DEBIAN_SRC="upstream/debian-src" \
    bash "$target" --src-dir "$want_c")"
  if [ "$got" != "$want_d" ]; then
    echo "FAIL: --src-dir $want_c printed '$got', expected '$want_d'"
    exit 1
  fi
done

co="upstream/pxvirt/packages/proxmox-perl-rs/proxmox-perl-rs"
if [ -d "$co" ]; then
  head="$(git -C "$co" rev-parse HEAD)"
  if [ "$head" != "c6b798f72a7e9f1063d75b144835d63781006ef4" ]; then
    echo "FAIL: $co HEAD is $head, expected override c6b798f72a7e9f1063d75b144835d63781006ef4"
    exit 1
  fi
fi

echo "OK: fetch-upstream.sh --list prints 16 lines including pve-cluster, pve-access-control, proxmox-perl-rs, rrdtool and isc-dhcp; --list-overrides prints the proxmox-perl-rs override and the checkout HEAD matches it; --list-debian-src pins rrdtool and isc-dhcp; --src-dir resolves both source layouts"
