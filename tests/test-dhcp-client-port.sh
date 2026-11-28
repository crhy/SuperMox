#!/usr/bin/env bash
# Offline test for the pve-container DHCP client port (crhy/SuperMox#9).
#
# Devuan Ceres no longer ships isc-dhcp-client, so pve-container's host-managed
# container networking (PVE::LXC::manage_dhclient, which runs a DHCP client inside
# the container's network namespace) must work with a maintained client while
# keeping the ISC one as a fallback. This test
#   * applies patches/pve-container/0003-maintained-dhcp-client.patch to the
#     pinned-source excerpts under tests/fixtures/ and fails if it does not apply,
#   * checks the patched source keeps /sbin/dhclient and adds a udhcpc6/udhcpc
#     one-shot call, that debian/control no longer depends on isc-dhcp-client
#     alone, and that src/Makefile installs the adapter,
#   * extracts the adapter from the patch and runs it with a fixture udhcpc
#     environment and a stub dhclient-script, checking the whole dhclient-script
#     contract, the file placement, the no-address failure path and usage,
#   * and, when upstream/ is present, that the fixtures still match the pinned
#     source byte-for-byte and that the patch applies in the real tree.
#
# Everything happens under build/ (never /tmp); no container, no network, no root.
set -euo pipefail

cd "$(dirname "$0")/.."
repo="$PWD"

patch_file="patches/pve-container/0003-maintained-dhcp-client.patch"
fix_lxc="tests/fixtures/pve-container-manage-dhclient.pl"
fix_control="tests/fixtures/pve-container-debian-control"
fix_make="tests/fixtures/pve-container-Makefile"
adapter_path="src/pve-dhcp-client"

fail=0

error() {
  echo "FAIL: $*"
  fail=1
}

for f in "$patch_file" "$fix_lxc" "$fix_control" "$fix_make"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing file: $f"
    exit 1
  fi
done

sandbox="$repo/build/test-dhcp-client"
rm -rf "$sandbox"
mkdir -p "$sandbox"

# --- 1. the patch applies to the pinned-source excerpts -----------------------
tree="$sandbox/tree"
mkdir -p "$tree/src/PVE" "$tree/debian"
cp "$fix_lxc" "$tree/src/PVE/LXC.pm"
cp "$fix_control" "$tree/debian/control"
cp "$fix_make" "$tree/src/Makefile"

rc=0
out="$( ( cd "$tree" && patch -p1 --forward --batch --fuzz=0 < "$repo/$patch_file" ) 2>&1 )" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: $patch_file does not apply to the fixtures (exit $rc)"
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$out" > "$sandbox/patch-apply.log"
echo "OK: $patch_file applies to the pinned-source excerpts with --fuzz=0"

# --- 2. what the patched source must say --------------------------------------
lxc_pm="$tree/src/PVE/LXC.pm"
control="$tree/debian/control"
makefile="$tree/src/Makefile"

if ! grep -qF "'/sbin/dhclient'," "$lxc_pm"; then
  error "patched LXC.pm lost the /sbin/dhclient fallback"
fi
if ! grep -qF 'container_dhcp_client($vmid)' "$lxc_pm"; then
  error "patched LXC.pm does not probe for a DHCP client inside the container"
fi
if ! grep -qF 'udhcpc6' "$lxc_pm" || ! grep -qF '/sbin/udhcpc;' "$lxc_pm"; then
  error "patched LXC.pm does not probe for udhcpc6 and udhcpc"
fi

# the non-ISC branch: from the client check to its return
branch="$(awk -v m1="if (\$client ne '/sbin/dhclient')" -v m2='        return;' '
  !f && index($0, m1) { f = 1 }
  f { print }
  f && index($0, m2) { exit }
' "$lxc_pm")"
if [ -z "$branch" ]; then
  error "patched LXC.pm has no separate branch for a non-ISC client"
  exit 1
fi
for flag in "-i" "-p" "-q" "-n" "-s"; do
  if ! printf '%s\n' "$branch" | grep -qF -- "'$flag',"; then
    error "the udhcpc one-shot call is missing the '$flag' argument"
  fi
done
for needle in '$client,' '$eth,' '$pidfile,' '/usr/share/lxc/hooks/pve-dhcp-client'; do
  if ! printf '%s\n' "$branch" | grep -qF -- "$needle"; then
    error "the udhcpc one-shot call is missing: $needle"
  fi
done
if ! printf '%s\n' "$branch" | grep -qF 'local $ENV{ROOTFS} = $rootdir;'; then
  error "ROOTFS is not passed to the adapter through the environment"
fi

if grep -qE '^[[:space:]]*isc-dhcp-client,[[:space:]]*$' "$control"; then
  error "debian/control still depends on isc-dhcp-client alone"
fi
if ! grep -qE '^[[:space:]]*udhcpc \| dhcpcd-base \| isc-dhcp-client,[[:space:]]*$' "$control"; then
  error "debian/control has no maintained-client dependency with isc-dhcp-client as a fallback"
fi

if ! grep -qF 'install -m 0755 pve-dhcp-client $(LXC_HOOK_DIR)' "$makefile"; then
  error "src/Makefile does not install pve-dhcp-client next to the other hooks"
fi
if [ ! -f "$tree/$adapter_path" ]; then
  error "the patch did not create $adapter_path"
fi

# --- 3. the adapter, taken out of the patch itself ---------------------------
extract_new_file() {
  # $1 = patch file, $2 = new file path as it appears after "+++ b/"
  awk -v want="$2" '
    BEGIN { t = "+++ b/" want }
    f == 0 && index($0, t) == 1 {
      rest = substr($0, length(t) + 1)
      if (rest == "" || rest ~ /^\t/) { f = 1; next }
    }
    f == 1 && /^@@ / { b = 1; next }
    f == 1 && b == 1 {
      if (/^\+/) { print substr($0, 2); next }
      exit
    }
  ' "$1"
}

mkdir -p "$sandbox/extract"
extract_new_file "$repo/$patch_file" "$adapter_path" > "$sandbox/extract/pve-dhcp-client"
chmod +x "$sandbox/extract/pve-dhcp-client"

if [ ! -s "$sandbox/extract/pve-dhcp-client" ]; then
  echo "FAIL: could not extract $adapter_path from $patch_file"
  exit 1
fi
if ! cmp -s "$sandbox/extract/pve-dhcp-client" "$tree/$adapter_path"; then
  error "the adapter in the patch differs from the one the patch installs"
fi
if ! sh -n "$sandbox/extract/pve-dhcp-client"; then
  error "the adapter is not valid POSIX sh"
fi
if command -v shellcheck > /dev/null 2>&1; then
  if ! shellcheck -S warning -s sh "$sandbox/extract/pve-dhcp-client"; then
    error "shellcheck complains about the adapter"
  fi
fi
if grep -qE '\[\[|<<<|[^- ]\+=|&>|function [a-z_]+ *\(\)|\$\{[a-z_]+![^}]*\}' \
  "$sandbox/extract/pve-dhcp-client"; then
  error "the adapter uses bashisms"
fi
if grep -E '^\+' "$repo/$patch_file" | grep -qiE 'systemctl|libsystemd|sd_notify|\.service\b'; then
  error "the patch adds a systemd reference"
fi

# --- 4. run the adapter with a fixture udhcpc environment -------------------
rootfs="$sandbox/rootfs"
hookdir="$sandbox/var/lib/lxc/100/hook"
mkdir -p "$rootfs/usr/share/lxc/hooks" "$hookdir" "$sandbox/outside"

cat > "$rootfs/usr/share/lxc/hooks/dhclient-script" <<'EOF'
#!/bin/sh
# stub for LXC's dhclient-script: print the environment it was handed.
env
EOF
chmod +x "$rootfs/usr/share/lxc/hooks/dhclient-script"

lease="$hookdir/dhclient4-eth0.leases"
adapter_bin="$sandbox/extract/pve-dhcp-client"

touch "$sandbox/.marker"

rc=0
envout="$(env -i \
  PATH="/usr/bin:/bin" \
  ROOTFS="$rootfs" \
  LEASEFILE="$lease" \
  interface=eth0 \
  ip=10.0.2.77 \
  subnet_mask=255.255.255.0 \
  mask=255.255.255.0 \
  router=10.0.2.2 \
  router_list='10.0.2.2 fd00::2' \
  giaddr=10.0.2.2 \
  domain=example.test \
  dns_servers='ns1.example.test ns2.example.test' \
  lease_seconds=1200 \
  reason=bound \
  /bin/sh "$adapter_bin" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: the adapter exited $rc with a full lease"
  printf '%s\n' "$envout"
  exit 1
fi

check_env() {
  # $1 = NAME=value the stub hook must have received
  if ! printf '%s\n' "$envout" | grep -qxF -- "$1"; then
    error "the hook did not get exactly: $1"
  fi
}

check_env "reason=bind"
check_env "interface=eth0"
check_env "new_ip_address=10.0.2.77"
check_env "new_subnet_mask=255.255.255.0"
check_env "new_network_mask=255.255.255.0"
check_env "new_gateway=10.0.2.2"
check_env "new_domain_name=example.test"
check_env "new_dns_servers=ns1.example.test ns2.example.test"
check_env "new_domain_name_servers=ns1.example.test ns2.example.test"
check_env "new_lease_seconds=1200"
check_env "new_router_count=2"
check_env "new_router_1=10.0.2.2"
check_env "new_router_2=fd00::2"
check_env "ROOTFS=$rootfs"

router_lines="$(printf '%s\n' "$envout" | grep -cE '^new_router_[0-9]+=')"
if [ "$router_lines" != "2" ]; then
  error "new_router_1..N does not match the router list ($router_lines entries)"
fi
if [ "$(printf '%s\n' "$envout" | grep -E '^new_router_count=' | cut -d= -f2)" != "$router_lines" ]; then
  error "new_router_count does not match the router list"
fi

if [ ! -f "$lease" ] || [ ! -s "$lease" ]; then
  error "no lease record written in the container hook directory"
fi

# nothing may be created outside $ROOTFS and the container hook directory
stray=0
while IFS= read -r f; do
  case "$f" in
    "$rootfs"/* | "$hookdir"/*) continue ;;
  esac
  echo "FAIL: the adapter wrote outside ROOTFS and the hook dir: $f"
  stray=1
done < <(find "$sandbox" -type f -newer "$sandbox/.marker" -print)
if [ "$stray" -ne 0 ]; then
  fail=1
fi
if [ -n "$(find "$sandbox/outside" -mindepth 1 -print -quit)" ]; then
  error "the adapter wrote into the untouched directory"
fi

# --- 5. the failure paths ----------------------------------------------------
rm -f "$lease"
rc=0
out="$(env -i PATH="/usr/bin:/bin" ROOTFS="$rootfs" LEASEFILE="$lease" \
  interface=eth0 reason=renew router=10.0.2.2 \
  /bin/sh "$adapter_bin" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  error "the adapter succeeded although the client produced no address"
fi
if [ -e "$lease" ]; then
  error "the adapter wrote a lease record for a lease it does not have"
fi
if printf '%s' "$out" | grep -q 'new_ip_address'; then
  error "the adapter called the hook without an address"
fi

rc=0
out="$(env -i /bin/sh "$adapter_bin" 2>&1)" || rc=$?
if [ "$rc" -ne 2 ]; then
  echo "FAIL: the adapter with no interface exited $rc, expected 2"
  printf '%s\n' "$out"
  exit 1
fi

# --- 6. the pinned source, when upstream/ is present ------------------------
up="upstream/pxvirt/packages/pve-container/pve-container"
if [ ! -d "$up" ]; then
  echo "SKIP: upstream/pxvirt/packages/pve-container/pve-container absent; fixture and real-tree checks skipped"
else
  fixture_body() {
    # everything after the "begins ---" marker line
    awk '/^# --- .* begins ---$/{f=1;next} f{print}' "$1"
  }

  if ! diff -q <(fixture_body "$fix_lxc") <(sed -n '1292,1400p' "$up/src/PVE/LXC.pm") > /dev/null; then
    error "$fix_lxc no longer matches src/PVE/LXC.pm lines 1292-1400 at the pinned commit"
  fi
  if ! diff -q <(fixture_body "$fix_control") "$up/debian/control" > /dev/null; then
    error "$fix_control no longer matches debian/control at the pinned commit"
  fi

  # src/Makefile as 0003 sees it: the pinned file with 0001-debian-sysvinit applied
  mkdir -p "$sandbox/up"
  rsync -a --exclude .git "$up/" "$sandbox/up/"
  rc=0
  ( cd "$sandbox/up" && patch -p1 --forward --batch < "$repo/patches/pve-container/0001-debian-sysvinit.patch" > /dev/null ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: could not apply 0001-debian-sysvinit.patch to the pinned src/Makefile"
    exit 1
  fi
  if ! diff -q <(fixture_body "$fix_make") <(sed -n '38,70p' "$sandbox/up/src/Makefile") > /dev/null; then
    error "$fix_make no longer matches src/Makefile lines 38-70 at the pinned commit with 0001 applied"
  fi

  rm -rf "$sandbox/patched"
  rc=0
  out="$(bash scripts/apply-patches.sh "$sandbox/patched" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: scripts/apply-patches.sh failed on the real upstream tree"
    printf '%s\n' "$out"
    exit 1
  fi
  if [ ! -f "$sandbox/patched/pve-container/pve-container/$adapter_path" ]; then
    error "apply-patches.sh did not create $adapter_path in the real tree"
  fi
  rc=0
  out="$(bash scripts/check-no-systemd.sh --source "$sandbox/patched" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: scripts/check-no-systemd.sh --source on the patched tree"
    printf '%s\n' "$out"
    exit 1
  fi
  echo "OK: fixtures match the pinned pve-container source; 0003 applies after 0001+0002; no new systemd"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: pve-container DHCP port: patch applies, ISC fallback kept, udhcpc one-shot added, adapter contract and file placement correct"
