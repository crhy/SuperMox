#!/usr/bin/env bash
# smx02 (crhy/SuperMox#9): the two packages of the one DHCP path must install
# side by side without a file or Provides conflict.
#
# The path: patched pve-container (patches/pve-container/0003-maintained-
# dhcp-client.patch) runs the container image's own client through the
# adapter /usr/share/lxc/hooks/pve-dhcp-client that pve-container ships, and
# supermox-dhcp-client is a thin alias that depends on pve-container and
# ships nothing. The interim isc-dhcp fork (kept; patches/isc-dhcp, the
# supermox-ve pin and the apt pins) stays the only package that can own
# /usr/sbin/dhclient.
#
# This test builds both control files into real debs with dpkg-deb and asks
# dpkg about them:
#   * dpkg-deb --info must parse both, and neither may declare Provides,
#     Conflicts or Replaces against the other or against isc-dhcp-client,
#   * dpkg-deb --contents must show no path in both packages, and
#     /usr/sbin/dhclient in neither (the fork owns it alone),
#   * the pve-container client dependency must still be the maintained-client
#     alternative `udhcpc | dhcpcd-base | isc-dhcp-client`, satisfiable on a
#     SuperMox node (fork present), while the alias only needs pve-container.
# Everything happens under build/ (never /tmp); no root, no network.
set -euo pipefail

cd "$(dirname "$0")/.."
repo="$PWD"

alias_src="packaging/supermox-dhcp-client"
patch_file="patches/pve-container/0003-maintained-dhcp-client.patch"
fix_lxc="tests/fixtures/pve-container-manage-dhclient.pl"
fix_control="tests/fixtures/pve-container-debian-control"
fix_make="tests/fixtures/pve-container-Makefile"

fail=0
error() {
  echo "FAIL: $*"
  fail=1
}

for f in "$alias_src/debian/control" "$patch_file" "$fix_lxc" "$fix_control" "$fix_make"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing file: $f"
    exit 1
  fi
done

sb="$repo/build/test-dhcp-one-path"
rm -rf "$sb"
mkdir -p "$sb"

# Binary paragraph of a source control file (paragraph beginning "Package: X").
binary_para() { # $1 = control file, $2 = binary package name
  awk -v p="Package: $2" 'BEGIN { RS = ""; ORS = "" } index($0, p "\n") == 1 { print }' "$1"
}

# Extract a file added by the patch (same recipe as tests/test-dhcp-client-port.sh).
extract_new_file() { # $1 = patch file, $2 = new path after "+++ b/"
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

# version from the top changelog line, e.g. "pkg (0.2.0) ..." -> 0.2.0
deb_version() {
  sed -n '1s/.*(\([^()]*\)).*/\1/p' "$1"
}

# Refold a binary paragraph for DEBIAN/control and drop debhelper substvars
# (${misc:Depends} etc.): dpkg-deb --build does not expand them, and a left
# behind comma would make dpkg reject the Depends field.
stage_para() { # $1 = paragraph text on stdin, $2 = extra file to append
  awk '
    function flush(   v) {
      if (field != "") {
        v = value
        sub(/[[:space:]]*$/, "", v); sub(/,$/, "", v)
        print field ": " v
      }
      field = ""; value = ""
    }
    /^[A-Za-z-]+:/ {
      flush()
      match($0, /^[A-Za-z-]+:/)
      field = substr($0, 1, RLENGTH - 1)
      value = substr($0, RLENGTH + 1)
      next
    }
    /^[[:space:]]/ {
      v = $0
      sub(/^[[:space:]]+/, "", v)
      if (v !~ /\$\{/) value = value " " v
      next
    }
    { flush(); print }
    END { flush() }
  ' | cat - "$2"
}

# --- 1. the alias package as a deb ------------------------------------------
stage="$sb/alias/DEBIAN"
mkdir -p "$stage"
printf 'Version: %s\nMaintainer: %s\n' \
  "$(deb_version "$alias_src/debian/changelog")" \
  "$(sed -n 's/^Maintainer: //p' "$alias_src/debian/control" | head -1)" \
  > "$sb/extra.fields"
binary_para "$alias_src/debian/control" supermox-dhcp-client \
  | stage_para - "$sb/extra.fields" > "$stage/control"
chmod 0644 "$stage/control"
alias_deb="$sb/supermox-dhcp-client.deb"
dpkg-deb --build --root-owner-group "$sb/alias" "$alias_deb" > /dev/null

# --- 2. patched pve-container as a deb ---------------------------------------
tree="$sb/tree"
mkdir -p "$tree/src/PVE" "$tree/debian"
cp "$fix_lxc" "$tree/src/PVE/LXC.pm"
cp "$fix_control" "$tree/debian/control"
cp "$fix_make" "$tree/src/Makefile"
rc=0
( cd "$tree" && patch -p1 --forward --batch --fuzz=0 < "$repo/$patch_file" ) > "$sb/patch.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: $patch_file does not apply to the fixtures (exit $rc)"
  cat "$sb/patch.log"
  exit 1
fi

pstage="$sb/pve/DEBIAN"
mkdir -p "$pstage" "$sb/pve/usr/share/lxc/hooks"
printf 'Version: 6.1.15+supermox1\nMaintainer: %s\n' \
  "$(sed -n 's/^Maintainer: //p' "$tree/debian/control" | head -1)" \
  > "$sb/extra.fields"
binary_para "$tree/debian/control" pve-container \
  | stage_para - "$sb/extra.fields" > "$pstage/control"
chmod 0644 "$pstage/control"
extract_new_file "$repo/$patch_file" "src/pve-dhcp-client" \
  > "$sb/pve/usr/share/lxc/hooks/pve-dhcp-client"
chmod 0755 "$sb/pve/usr/share/lxc/hooks/pve-dhcp-client"
pve_deb="$sb/pve-container.deb"
dpkg-deb --build --root-owner-group "$sb/pve" "$pve_deb" > /dev/null

# --- 3. dpkg parses both controls; no Provides/Conflicts/Replaces ------------
for deb in "$alias_deb" "$pve_deb"; do
  if ! dpkg-deb --info "$deb" > "$sb/info.txt"; then
    error "dpkg-deb --info failed on $deb"
    continue
  fi
  name="$(dpkg-deb -f "$deb" Package)"
  for field in Provides Conflicts Replaces; do
    val="$(dpkg-deb -f "$deb" "$field" 2>/dev/null || true)"
    if [ -n "$val" ]; then
      error "$name declares $field: $val (the one path forbids virtual-name claims)"
    fi
  done
done

# --- 4. contents: no shared file, no dhclient from either -------------------
files_of() { # sorted regular paths, "./" dropped; empty for a files-less deb
  dpkg-deb --contents "$1" | awk '{ print $NF }' | { grep -v -E '^\./$|/$' || true; } | sort
}
files_of "$alias_deb" > "$sb/alias.files"
files_of "$pve_deb" > "$sb/pve.files"
if grep -q 'dhclient' "$sb/alias.files" || grep -q 'sbin/dhclient' "$sb/pve.files"; then
  error "a package of the one path ships a dhclient binary; only the interim isc-dhcp fork may"
fi
if ! grep -q './usr/share/lxc/hooks/pve-dhcp-client' <(dpkg-deb --contents "$pve_deb"); then
  error "pve-container does not ship the adapter next to the other LXC hooks"
fi
if [ -s "$sb/alias.files" ]; then
  error "the alias ships files: $(tr '\n' ' ' < "$sb/alias.files")"
fi
overlap="$(comm -12 "$sb/alias.files" "$sb/pve.files" || true)"
if [ -n "$overlap" ]; then
  error "both packages ship the same path(s): $overlap"
fi

# --- 5. /usr/sbin/dhclient has exactly one owner system-wide -----------------
if grep -rn "^Provides: isc-dhcp-client" packaging/; then
  error "a packaging/ source still Provides: isc-dhcp-client; the fork owns that name alone"
fi
if [ ! -f "patches/isc-dhcp/0001-supermox.patch" ]; then
  error "the interim isc-dhcp fork (sole owner of /usr/sbin/dhclient) is gone; its removal is rhY's decision, not this test's"
fi
if ! grep -qE 'isc-dhcp-client \(>= 4\.4\.3-P1-8\+supermox1\)' packaging/supermox-ve/debian/control; then
  error "supermox-ve no longer pins the fork that owns /usr/sbin/dhclient"
fi
if ! grep -q 'isc-dhcp-client' packaging/supermox-ve/etc/apt/preferences.d/supermox-origins; then
  error "the apt pins no longer mention the fork; drop them only when rhY drops the fork"
fi

# --- 6. the client dependency stays one satisfiable alternative -------------
pdeps="$(dpkg-deb -f "$pve_deb" Depends)"
if ! printf '%s' "$pdeps" | grep -qE 'udhcpc \| dhcpcd-base \| isc-dhcp-client'; then
  error "pve-container lost the 'udhcpc | dhcpcd-base | isc-dhcp-client' alternative (patched control: $pdeps)"
fi
adeps="$(dpkg-deb -f "$alias_deb" Depends)"
adepl="${adeps// /}"
adepl="${adepl%,}"
if [ "$adepl" != "pve-container" ]; then
  error "the alias must depend on exactly pve-container (the one path), got: $adeps"
fi

# --- 7. no systemd anywhere in the two control files or the adapter ---------
for f in "$sb/alias/DEBIAN/control" "$sb/pve/DEBIAN/control" "$sb/pve/usr/share/lxc/hooks/pve-dhcp-client"; do
  if grep -riE '\.service|\.unit\b|systemctl|sd_notify|libsystemd|ExecStart' "$f"; then
    error "systemd reference in $f"
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: the one DHCP path installs side by side: no shared files, no Provides/Conflicts, /usr/sbin/dhclient owned only by the kept fork"
