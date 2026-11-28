#!/usr/bin/env bash
# Offline test for scripts/upstream-drift-check.sh: fixtures only, no network.
# The Packages index lists EVERY published version of a package, oldest first
# (f265b): the check must pick the NEWEST match, in dpkg version order, for
# both Package: and Source: names ("Source: name (version)", parens stripped).
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
pve-firewall https://git.proxmox.com/git/pve-firewall.git 9480dd1739669a1abb3551d42922c2691967ea8f  # 6.0.6, as in Proxmox's trixie repo
pve-ha-manager https://git.proxmox.com/git/pve-ha-manager.git c73364c19d5317e6df5bb1c1b727d080a5e897ef  # 5.2.5, ahead of the index
pve-mystery https://git.proxmox.com/git/pve-mystery.git dff26b458651b4e1141ff0a41a296d2904b16228  # 1.0.1, source name with no Source: field in the index
pve-ghost https://git.proxmox.com/git/pve-ghost.git dff26b458651b4e1141ff0a41a296d2904b16228  # 9.1.2, as in Proxmox's trixie repo
OV

# Fixture Packages index, in real index order (every version, oldest first):
#   pve-common ships 9.2.5-1 newest (two older entries first - the f265 bug
#     took the first match, 9.0.0~10-style, and reported false drift)
#   pve-container moved 6.1.15 -> 6.1.16-1 (the real drift), two older entries first
#   pve-firewall: 6.0.6~rc1-1 is OLDER than 6.0.6-1 in dpkg order though it
#     sorts higher bytewise - newest must win by dpkg --compare-versions
#   pve-ha-manager: newest 5.2.4-1 is BELOW our 5.2.5 pin -> AHEAD, not drift
#   proxmox-perl-rs: source-only, "Source: name (version)" parens stripped,
#     two source versions -> newest 0.15.3-1 matches the pin
#   pve-ghost absent from the index
pk="$root/Packages"
cat > "$pk" <<'PK'
Package: pve-common
Version: 9.0.0~10-1
Architecture: amd64
Description: oldest entry

Package: pve-common
Version: 9.1.0-1
Architecture: amd64
Description: middle entry

Package: pve-common
Version: 9.2.5-1
Architecture: amd64
Description: newest entry

Package: pve-container
Version: 6.1.14-1
Architecture: all
Description: oldest entry

Package: pve-container
Version: 6.1.15-1
Architecture: all
Description: our pin, superseded

Package: pve-container
Version: 6.1.16-1
Architecture: all
Description: newest entry

Package: pve-firewall
Version: 6.0.6~rc1-1
Architecture: amd64
Description: rc1 sorts BELOW the final release in dpkg order

Package: pve-firewall
Version: 6.0.6-1
Architecture: amd64
Description: newest entry

Package: pve-ha-manager
Version: 5.2.3-1
Architecture: amd64
Description: oldest entry

Package: pve-ha-manager
Version: 5.2.4-1
Architecture: amd64
Description: newest entry

Package: libpve-rs-perl
Version: 0.15.2-1
Source: proxmox-perl-rs (0.15.2-1)
Architecture: amd64
Description: older source version

Package: libpve-rs-perl
Version: 0.15.3-1
Source: proxmox-perl-rs (0.15.3-1)
Architecture: amd64
Description: newest source version

Package: libpve-extra-perl
Version: 0.15.3-1
Source: proxmox-perl-rs 0.15.3-1
Architecture: all
Description: source field without parens also resolves

Package: libpve-mystery-perl
Version: 1.0.0-1
Architecture: all
Description: older binary alias entry

Package: libpve-mystery-perl
Version: 1.0.1-1
Architecture: all
Description: newest binary alias entry
PK

# Fixture binary-alias map: pve-mystery carries no Source: field in this index
# (like the real index never carries one for libpve-*-perl), its component
# resolves through its binary package name.
map="$root/source-binaries.txt"
cat > "$map" <<'MAP'
# <component> <binary-package-name>
pve-mystery libpve-mystery-perl
MAP

# the real map must cover exactly the five source-only components
n_map=$(grep -c '^[a-z]' config/upstream-source-binaries.txt)
if [ "$n_map" -ne 5 ]; then
  echo "FAIL: config/upstream-source-binaries.txt has $n_map component lines, expected 5"
  fail=1
fi

rc=0
out="$(bash "$target" --overrides "$ov" --packages "$pk" --source-binaries "$map" 2>&1)" || rc=$?
if [ "$rc" -ne 1 ]; then
  echo "FAIL: drift run exited $rc, expected 1"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^BEHIND pve-container pinned 6.1.15 but trixie ships 6.1.16-1$'; then
  echo "FAIL: drift run did not print the pve-container BEHIND line for the NEWEST index entry"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -q '6\.1\.14'; then
  echo "FAIL: drift run reported an older index entry instead of the newest"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^in-sync pve-common 9.2.5$'; then
  echo "FAIL: drift run did not print in-sync for pve-common against its newest of three entries"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^in-sync proxmox-perl-rs 0.15.3$'; then
  echo "FAIL: Source-only component proxmox-perl-rs did not resolve via the Source: (name (version)) field"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^in-sync pve-firewall 6.0.6$'; then
  echo "FAIL: pve-firewall newest entry was not picked by dpkg order (6.0.6~rc1-1 < 6.0.6-1)"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^AHEAD pve-ha-manager pinned 5.2.5 but newest in the index is 5.2.4-1$'; then
  echo "FAIL: pin newer than the newest index entry did not print AHEAD"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^UNKNOWN pve-ghost not found in the index$'; then
  echo "FAIL: component missing from the index did not print UNKNOWN"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^in-sync pve-mystery 1.0.1$'; then
  echo "FAIL: source-only component with no Source: field did not resolve via its binary alias"
  printf '%s\n' "$out"
  fail=1
fi

# 2) all in sync (plus one AHEAD) -> exit 0, no BEHIND/UNKNOWN lines
ov_ok="$root/overrides-ok.txt"
cat > "$ov_ok" <<'OVOK'
proxmox-perl-rs https://git.proxmox.com/git/proxmox-perl-rs c6b798f72a7e9f1063d75b144835d63781006ef4  # pve-rs 0.15.3, matches Proxmox's current crates
pve-common https://git.proxmox.com/git/pve-common.git 1fc3a09b6456c487d37e602fcd85b7082a32bc50  # 9.2.5, as in Proxmox's trixie repo
pve-ha-manager https://git.proxmox.com/git/pve-ha-manager.git c73364c19d5317e6df5bb1c1b727d080a5e897ef  # 5.2.5, ahead of the index
OVOK
rc=0
out="$(bash "$target" --overrides "$ov_ok" --packages "$pk" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: in-sync run exited $rc, expected 0 (AHEAD must not be an error)"
  printf '%s\n' "$out"
  fail=1
fi
if printf '%s\n' "$out" | grep -qE '^(BEHIND|DRIFT|UNKNOWN) '; then
  echo "FAIL: in-sync run printed a BEHIND/DRIFT or UNKNOWN line"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -q '^AHEAD pve-ha-manager pinned 5.2.5 but newest in the index is 5.2.4-1$'; then
  echo "FAIL: in-sync run did not print the AHEAD line for pve-ha-manager"
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
for want in "pve-manager 9.3.1" "proxmox-perl-rs 0.16.8" "librados2-perl 1.5.1"; do
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

echo "OK: upstream-drift-check.sh exits 0 in-sync/AHEAD / 1 on BEHIND (newest index entry wins, dpkg order) / 2 on malformed lines; resolves Source-only components via 'Source: name (version)'; reports UNKNOWN for missing ones; --list parses the real upstream-overrides.txt offline"
