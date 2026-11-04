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

# ZERO systemd: the package itself must ship the apt pin that keeps systemd
# out of the picture, so a plain Devuan Ceres host that installs supermox-ve
# can never have systemd pulled in behind it. The pin is a conffile at
# /etc/apt/preferences.d/supermox-no-systemd; scripts/build-rootfs.sh and the
# ISO build have to write it before the package can be installed, so they use
# this same file name and installing the package replaces their copy instead
# of leaving a second one behind.
pkg_root="packaging/supermox-ve"
pin="$pkg_root/etc/apt/preferences.d/supermox-no-systemd"
if [ ! -f "$pin" ]; then
  echo "FAIL: supermox-ve ships no $pin"
  fail=1
fi
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
  # the pin file may only ever demote: no positive priority anywhere in it
  if grep -qE '^Pin-Priority: [^-]' "$pin"; then
    echo "FAIL: $pin contains a non-negative Pin-Priority"
    fail=1
  fi
  # apt's preferences parser only continues a record on indented lines: a
  # non-blank, unindented line that is not a key makes apt print
  # "E: Invalid record ... no Package header" on every apt run on the target.
  bad_line="$(awk -v f="$pin" '
    NF && $0 !~ /^[ \t]/ && $0 !~/^(Package|Pin|Pin-Priority|Explanation|File|ExtrapolatePin):/ {
      print f ":" NR ": " $0
    }' "$pin")"
  if [ -n "$bad_line" ]; then
    echo "FAIL: $pin has a line apt cannot parse: $bad_line"
    fail=1
  fi
  if command -v apt-cache > /dev/null 2>&1; then
    pd="build/pin-parse.$$"
    mkdir -p "$pd"
    cp "$pin" "$pd/"
    apt_warn="$(apt-cache -o Dir::Etc::preferencesparts="$PWD/$pd" policy systemd 2>&1 | grep -E '^(E|W):' || true)"
    rm -rf "$pd"
    if [ -n "$apt_warn" ]; then
      echo "FAIL: apt rejects $pin: $apt_warn"
      fail=1
    fi
  fi
fi
if ! grep -qE 'cp -a etc/apt/preferences\.d/supermox-no-systemd debian/supermox-ve/etc/apt/preferences\.d/supermox-no-systemd' "$rules"; then
  echo "FAIL: $rules does not install the apt pin file"
  fail=1
fi
if ! grep -qE 'chmod 0644 debian/supermox-ve/etc/apt/preferences\.d/supermox-no-systemd' "$rules"; then
  echo "FAIL: $rules does not install the apt pin file as 0644"
  fail=1
fi
# debhelper only registers conffiles it installs itself, so the path has to be
# declared explicitly (upstream pve-cluster does the same in debian/conffiles).
if [ ! -f "$pkg_root/debian/conffiles" ] || ! grep -qx '/etc/apt/preferences.d/supermox-no-systemd' "$pkg_root/debian/conffiles"; then
  echo "FAIL: $pkg_root/debian/conffiles does not declare /etc/apt/preferences.d/supermox-no-systemd"
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

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-ve packaging passes"
