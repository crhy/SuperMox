#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dir="packaging/supermox-ve/debian"
control="$dir/control"
rules="$dir/rules"

fail=0

if [ ! -f "$control" ]; then
  echo "FAIL: $control does not exist"
  exit 1
fi

# Extract the Depends block (the Depends: line plus its indented continuation
# lines) and assert it never mentions systemd.
depends="$(awk '
  /^Depends:/ { f=1; print; next }
  f && /^[[:space:]]/ { print; next }
  f { exit }
' "$control")"

if [ -z "$depends" ]; then
  echo "FAIL: no Depends field found in $control"
  fail=1
elif printf '%s\n' "$depends" | grep -qi 'systemd'; then
  echo "FAIL: Depends mentions systemd"
  printf '%s\n' "$depends"
  fail=1
fi

# Conflicts must list systemd-sysv (and systemd).
if ! grep -qE '^Conflicts:.*systemd-sysv' "$control"; then
  echo "FAIL: control missing Conflicts: systemd-sysv"
  fail=1
fi

# rules must be executable.
if [ ! -x "$rules" ]; then
  echo "FAIL: $rules is not executable"
  fail=1
fi

# The package owns /etc/supermox/sync-users, the list of users that get a
# Syncthing instance, and nothing else creates it: the init script and the CLI
# both read it and fail without it.  So the package needs a postinst that
# creates it, keeps an existing one, and carries the #DEBHELPER# token dh_install
# uses to insert the enable/start snippets (0.1.7 removed an older postinst that
# hand-rolled those, so it must not hand-roll them again).
postinst="$dir/postinst"
if [ ! -f "$postinst" ]; then
  echo "FAIL: $postinst does not exist: nothing creates /etc/supermox/sync-users"
  fail=1
else
  if [ ! -x "$postinst" ]; then
    echo "FAIL: $postinst is not executable"
    fail=1
  fi
  if ! grep -q '#DEBHELPER#' "$postinst"; then
    echo "FAIL: $postinst has no #DEBHELPER# token"
    fail=1
  fi
  if ! grep -q '/etc/supermox/sync-users' "$postinst"; then
    echo "FAIL: $postinst does not create /etc/supermox/sync-users"
    fail=1
  fi
  if ! grep -qE '! -e[[:space:]]+/etc/supermox/sync-users' "$postinst"; then
    echo "FAIL: $postinst can overwrite an existing sync-users"
    fail=1
  fi
  if grep -qE 'update-rc\.d|invoke-rc\.d' "$postinst";
  then
    echo "FAIL: $postinst hand-rolls rc links or service starts"
    fail=1
  fi
fi

# ZERO systemd: the package itself must ship the apt pins that keep systemd
# out of the picture, so a plain Devuan Ceres host that installs supermox-ve
# can never have systemd pulled in behind it. Two conffiles live under
# /etc/apt/preferences.d/: supermox-no-systemd (systemd names and the packages
# that depend on them pinned out) and supermox-origins (our own builds win over
# every repository, and every binary package we rebuild from patches/ is pinned
# to -1 from download.proxmox.com so apt upgrade can never swap our sysvinit
# build for Proxmox's systemd one). scripts/build-rootfs.sh and the ISO build
# write the same file names before the package can be installed, so installing
# the package replaces their copy instead of leaving a second one behind.
pkg_root="packaging/supermox-ve"
pin="$pkg_root/etc/apt/preferences.d/supermox-no-systemd"
origins_pin="$pkg_root/etc/apt/preferences.d/supermox-origins"
for f in "$pin" "$origins_pin"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: supermox-ve ships no $f"
    fail=1
  fi
done
if [ -f "$pin" ]; then
  for p in systemd systemd-sysv libsystemd0 libpam-systemd \
           systemd-standalone-sysusers systemd-standalone-tmpfiles; do
    got="$(awk -v RS='' -v pkg="$p" '
      {
        name=""; prio=""
        n=split($0, lines, "\n")
        for (i=1; i<=n; i++) {
          if (lines[i] ~ /^Package: /) name=substr(lines[i], 10)
          else if (lines[i] ~ /^Pin-Priority: /) prio=substr(lines[i], 15)
        }
        if (name == pkg && prio == "-1") found=1
      }
      END { print (found ? "yes" : "no") }' "$pin")"
    if [ "$got" != "yes" ]; then
      echo "FAIL: $pin has no Pin-Priority: -1 stanza for $p"
      fail=1
    fi
  done
  # the no-systemd pin may only ever demote: no positive priority anywhere in it
  if grep -qE '^Pin-Priority: [^-]' "$pin"; then
    echo "FAIL: $pin contains a non-negative Pin-Priority"
    fail=1
  fi
fi
if [ -f "$origins_pin" ]; then
  # Print one pipe-separated line per apt record: Package | Pin | Pin-Priority.
  # Explanation lines are continuation lines of the record and are ignored.
  records="$(awk '
    BEGIN { RS="" }
    {
      pkg=""; pin=""; prio=""
      n=split($0, L, "\n")
      for (i=1; i<=n; i++) {
        if (L[i] ~ /^Package: /) pkg=substr(L[i], 10)
        else if (L[i] ~ /^Pin: /) pin=substr(L[i], 6)
        else if (L[i] ~ /^Pin-Priority: /) prio=substr(L[i], 15)
      }
      print pkg "|" pin "|" prio
    }' "$origins_pin")"
  for want in '*|origin ""|999' '*|origin download.proxmox.com|100' 'swtpm swtpm-libs swtpm-tools|origin download.proxmox.com|600' 'libpve-network-*|version 1.6.7*|990'; do
    if ! printf '%s\n' "$records" | grep -qF "$want"; then
      echo "FAIL: $origins_pin has no record matching $want"
      fail=1
    fi
  done
  # The -1 stanza must name exactly the binary packages apply-patches.sh versions,
  # i.e. the ones we rebuild from patches/: miss one and apt upgrade can replace
  # our sysvinit build with Proxmox's systemd one, name an extra and a package
  # we no longer build becomes uninstallable. scripts/supermox-pin-packages.sh
  # derives the list from the patched trees' debian/control files, so the
  # checked-in stanza cannot drift from what the build actually produces.
  patched="build/test-pin-patched"
  rm -rf "$patched"
  if ! bash scripts/apply-patches.sh "$patched" > "$patched.log" 2>&1; then
    echo "FAIL: scripts/apply-patches.sh $patched (needed to check the -1 stanza)"
    fail=1
  else
    have="$(awk '
      BEGIN { RS="" }
      {
        pkg=""; prio=""
        n=split($0, L, "\n")
        for (i=1; i<=n; i++) {
          if (L[i] ~ /^Package: /) pkg=substr(L[i], 10)
          else if (L[i] ~ /^Pin-Priority: /) prio=substr(L[i], 15)
        }
        if (prio == "-1") {
          m=split(pkg, names, " ")
          for (j=1; j<=m; j++) if (names[j] != "") print names[j]
        }
      }' "$origins_pin" | LC_ALL=C sort -u)"
    want="$(bash scripts/supermox-pin-packages.sh "$patched" | LC_ALL=C sort -u)"
    if [ "$have" != "$want" ]; then
      echo "FAIL: the -1 stanza of $origins_pin does not list exactly the packages apply-patches.sh versions"
      diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") | sed 's/^/  /'
      fail=1
    fi
  fi
  rm -rf "$patched" "$patched.log"
fi
# The forks (rrdtool, isc-dhcp) replace Devuan packages: a newer Devuan upload
# must not replace them, so they also need a -1 pin against Devuan's origin.
if [ -f "$origins_pin" ]; then
  for p in rrdcached librrd8t64 librrds-perl isc-dhcp-client isc-dhcp-common; do
    if ! awk -v RS='' -v pkg="$p" '
        { ok_pkg=0; ok_pin=0; ok_prio=0
          n=split($0, L, "\n")
          for (i=1; i<=n; i++) {
            if (L[i] ~ /^Package: / && (" " substr(L[i], 10) " ") ~ (" " pkg " ")) ok_pkg=1
            if (L[i] == "Pin: release o=Devuan") ok_pin=1
            if (L[i] == "Pin-Priority: -1") ok_prio=1
          }
          if (ok_pkg && ok_pin && ok_prio) found=1 }
        END { exit(found ? 0 : 1) }' "$origins_pin"; then
      echo "FAIL: $origins_pin does not pin $p to -1 from Devuan (o=Devuan)"
      fail=1
    fi
  done
fi
for f in "$pin" "$origins_pin"; do
  [ -f "$f" ] || continue
  # apt's preferences parser only continues a record on indented lines: a
  # non-blank, unindented line that is not a key makes apt print
  # "E: Invalid record ... no Package header" on every apt run on the target.
  bad_line="$(awk -v f="$f" '
    NF && $0 !~ /^[ \t]/ && $0 !~/^(Package|Pin|Pin-Priority|Explanation|File|ExtrapolatePin):/ {
      print f ":" NR ": " $0
    }' "$f")"
  if [ -n "$bad_line" ]; then
    echo "FAIL: $f has a line apt cannot parse: $bad_line"
    fail=1
  fi
  if command -v apt-cache > /dev/null 2>&1; then
    pd="build/pin-parse.$$"
    mkdir -p "$pd"
    cp "$f" "$pd/"
    apt_warn="$(apt-cache -o Dir::Etc::preferencesparts="$PWD/$pd" policy systemd 2>&1 | grep -E '^(E|W):' || true)"
    rm -rf "$pd"
    if [ -n "$apt_warn" ]; then
      echo "FAIL: apt rejects $f: $apt_warn"
      fail=1
    fi
  fi
done
for f in supermox-no-systemd supermox-origins; do
  if ! grep -qE "cp -a etc/apt/preferences\.d/$f debian/supermox-ve/etc/apt/preferences\.d/$f" "$rules"; then
    echo "FAIL: $rules does not install the $f apt pin file"
    fail=1
  fi
  if ! grep -qE "chmod 0644 debian/supermox-ve/etc/apt/preferences\.d/.*$f" "$rules"; then
    echo "FAIL: $rules does not install the $f apt pin file as 0644"
    fail=1
  fi
  # debhelper only registers conffiles it installs itself, so each path has to be
  # declared explicitly (upstream pve-cluster does the same in debian/conffiles).
  if [ ! -f "$pkg_root/debian/conffiles" ] || ! grep -qx "/etc/apt/preferences.d/$f" "$pkg_root/debian/conffiles"; then
    echo "FAIL: $pkg_root/debian/conffiles does not declare /etc/apt/preferences.d/$f"
    fail=1
  fi
done
# ZERO systemd unit files: the package also ships a dpkg config file so packages a
# node installs later never unpack systemd unit files. dpkg reads every file in
# /etc/dpkg/dpkg.cfg.d; path-exclude drops the three trees stock Devuan packages
# (ssh, lightdm, avahi, nfs-common, lvm2, lxc, wpa_supplicant ...) drop unit files
# into. The ISO build stages this very file before any package installs, and
# scripts/build-rootfs.sh passes the same three excludes to mmdebstrap, so the
# installed node, the ISO and the rootfs agree by construction.
dpkg_cfg="$pkg_root/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units"
if [ ! -f "$dpkg_cfg" ]; then
  echo "FAIL: supermox-ve does not ship etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units"
  fail=1
fi
for pat in 'path-exclude=/lib/systemd/\*' 'path-exclude=/usr/lib/systemd/\*' 'path-exclude=/etc/systemd/\*'; do
  if ! grep -qE "$pat" "$dpkg_cfg"; then
    echo "FAIL: supermox-no-systemd-units is missing $pat"
    fail=1
  fi
done
if ! grep -qF 'cp -a etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units debian/supermox-ve/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units' "$pkg_root/debian/rules"; then
  echo "FAIL: debian/rules does not copy the dpkg config file"
  fail=1
fi
if ! grep -qF 'chmod 0644 debian/supermox-ve/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units' "$pkg_root/debian/rules"; then
  echo "FAIL: debian/rules does not install the dpkg config file as 0644"
  fail=1
fi
if [ ! -f "$pkg_root/debian/conffiles" ] || ! grep -qx "/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units" "$pkg_root/debian/conffiles"; then
  echo "FAIL: debian/conffiles does not declare /etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units"
  fail=1
fi
for f in scripts/build-rootfs.sh scripts/build-iso.sh; do
  if ! grep -qF 'supermox-no-systemd' "$f"; then
    echo "FAIL: $f does not use the supermox-no-systemd pin file name"
    fail=1
  fi
done
# The pin is the guard. A DPkg::Post-Invoke hook that rm -rf's /etc/systemd
# must not be shipped as a second, heavier guard.
if grep -rqE 'Post-Invoke|rm -rf /etc/systemd' "$pkg_root"; then
  echo "FAIL: supermox-ve ships a Post-Invoke /etc/systemd removal hook"
  fail=1
fi

# A service owned by another component (rrdcached, shipped by the rrdtool fork)
# must not also be installed by supermox-ve: both would provide
# /etc/init.d/<svc> and dpkg refuses the second one at install time.
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  read -r comp _ svc <<< "$line"
  [ "$comp" = "supermox-ve" ] && continue
  if grep -qE "dh_installinit --name=$svc$" "$rules"; then
    echo "FAIL: $rules installs $svc, already shipped by $comp as /etc/init.d/$svc"
    fail=1
  fi
done < config/init-scripts.txt

# debhelper substitutes its marker token wherever it appears in a maintainer
# script, not only on a dedicated line: a script that spells the marker out in
# prose gets the whole init snippet injected there and the rest of the comment
# line becomes bare shell, which dash rejects. So each maintainer script may
# contain the marker exactly once.
for f in packaging/*/debian/post* packaging/*/debian/pre* packaging/*/debian/config; do
  [ -f "$f" ] || continue
  n=$(grep -c '#DEBHELPER#' "$f" || true)
  if [ "$n" -gt 1 ]; then
    echo "FAIL: $f mentions the debhelper marker $n times"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-ve packaging passes"
