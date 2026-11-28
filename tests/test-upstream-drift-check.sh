#!/usr/bin/env bash
# Offline test for scripts/upstream-drift-check.sh: fixtures only, no network.
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/upstream-drift-check.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

root="build/test-upstream-drift-check"
rm -rf "$root"
mkdir -p "$root"

fail=0

# Fixture overrides file, real-file line format.
ov="$root/overrides.txt"
cat > "$ov" <<'OV'
# Pin a component to an upstream commit other than the one PXVIRT's submodule records.
proxmox-perl-rs https://git.proxmox.com/git/proxmox-perl-rs c6b798f72a7e9f1063d75b144835d63781006ef4  # pve-rs 0.15.3, matches Proxmox's current crates
pve-common https://git.proxmox.com/git/pve-common.git 1fc3a09b6456c487d37e602fcd85b7082a32bc50  # 9.2.5, as in Proxmox's trixie repo
pve-container https://git.proxmox.com/git/pve-container.git 7d99e4982438de5b2262a36ef2a32c0f48227ad2  # 6.1.15, as in Proxmox's trixie repo
pve-ghost https://git.proxmox.com/git/pve-ghost.git dff26b458651b4e1141ff0a41a296d2904b16228  # 9.1.2, as in Proxmox's trixie repo
OV

# Fixture Packages index: pve-common ships the pinned version, pve-container
# moved (drift), proxmox-perl-rs exists only as a Source:, pve-ghost absent.
pk="$root/Packages"
cat > "$pk" <<'PK'
Package: pve-common
Version: 9.2.5-1
Architecture: amd64
Description: tests

Package: pve-container
Version: 6.1.16-1
Architecture: all
Description: tests

Package: libpve-rs-perl
Version: 0.15.3-1
Source: proxmox-perl-rs 0.15.3-1
Architecture: amd64
Description: tests
PK

rc=0
out="$(bash "$target" --overrides "$ov" --packages "$pk" 2>&1)" || rc=$?
if [ "$rc" -ne 1 ]; then
  echo "FAIL: drift run exited $rc, expected 1"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^DRIFT pve-container pinned 6.1.15 but trixie ships 6.1.16-1$'; then
  echo "FAIL: drift run did not print the pve-container DRIFT line"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^in-sync pve-common 9.2.5$'; then
  echo "FAIL: drift run did not print in-sync for pve-common (index version carries -1)"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^in-sync proxmox-perl-rs 0.15.3$'; then
  echo "FAIL: Source-only component proxmox-perl-rs did not resolve via the Source: field"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^UNKNOWN pve-ghost not found in the index$'; then
  echo "FAIL: component missing from the index did not print UNKNOWN"
  printf '%s\n' "$out"
  fail=1
fi

# 2) all in sync -> exit 0, no DRIFT/UNKNOWN lines
ov_ok="$root/overrides-ok.txt"
cat > "$ov_ok" <<'OVOK'
proxmox-perl-rs https://git.proxmox.com/git/proxmox-perl-rs c6b798f72a7e9f1063d75b144835d63781006ef4  # pve-rs 0.15.3, matches Proxmox's current crates
pve-common https://git.proxmox.com/git/pve-common.git 1fc3a09b6456c487d37e602fcd85b7082a32bc50  # 9.2.5, as in Proxmox's trixie repo
OVOK
rc=0
out="$(bash "$target" --overrides "$ov_ok" --packages "$pk" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: in-sync run exited $rc, expected 0"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -qE '^(DRIFT|UNKNOWN) '; then
  echo "FAIL: in-sync run printed a DRIFT or UNKNOWN line"
  printf '%s\n' "$out"
  fail=1
fi

# 3) malformed overrides line (no "# reason") -> exit 2
ov_bad="$root/overrides-bad.txt"
cp "$ov_ok" "$ov_bad"
printf 'pve-storage https://git.proxmox.com/git/pve-storage.git 75b36a49f57fa7119a45bb69118c8c6eb58102d7\n' >> "$ov_bad"
rc=0
out="$(bash "$target" --overrides "$ov_bad" --packages "$pk" 2>&1)" || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: malformed overrides line exited $rc, expected 2"
  printf '%s\n' "$out"
  fail=1
fi

# 4) the REAL config/upstream-overrides.txt against a fixture Packages derived
#    from it (no network): every component must report in-sync, exit 0.
list_out="$(bash "$target" --list)"
n=$(printf '%s\n' "$list_out" | wc -l)
if [ "$n" -ne 13 ]; then
  echo "FAIL: --list printed $n lines, expected 13 component lines"
  printf '%s\n' "$list_out"
  fail=1
fi
for want in "pve-manager 9.2.24" "proxmox-perl-rs 0.15.3" "librados2-perl 1.5.1"; do
  if ! printf '%s\n' "$list_out" | grep -qxF -- "$want"; then
    echo "FAIL: --list did not print: $want"
    printf '%s\n' "$list_out"
    fail=1
  fi
done
pk_real="$root/Packages-real"
awk '{ print "Package: " $1 "\nVersion: " $2 "-1\nArchitecture: amd64\nDescription: fixture\n" }' \
  <(bash "$target" --list) > "$pk_real"
rc=0
out="$(bash "$target" --packages "$pk_real" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: real overrides vs derived fixture exited $rc, expected 0"
  printf '%s\n' "$out"
  fail=1
fi
insync=$(printf '%s\n' "$out" | grep -c '^in-sync ')
if [ "$insync" -ne 13 ]; then
  echo "FAIL: real overrides run printed $insync in-sync lines, expected 13"
  printf '%s\n' "$out"
  fail=1
fi

# 5) usage error -> exit 2
rc=0
bash "$target" --packages 2>/dev/null || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: --packages without an argument exited $rc, expected 2"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: upstream-drift-check.sh exits 0 in-sync / 1 on drift (with the DRIFT line) / 2 on malformed lines; resolves Source-only components; reports UNKNOWN for missing ones; --list parses the real upstream-overrides.txt offline"
