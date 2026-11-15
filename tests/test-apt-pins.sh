#!/usr/bin/env bash
# The apt origin pins must live in one file shipped by supermox-ve (issue #10
# item 2), not be re-typed inside the build scripts: an installed system with no
# pin file lets apt upgrade swap our sysvinit builds for upstream ones.
set -euo pipefail

cd "$(dirname "$0")/.."

pin="packaging/supermox-ve/etc/apt/preferences.d/supermox-origins"
rules="packaging/supermox-ve/debian/rules"
root="build/test-apt-pins"
rm -rf "$root"
mkdir -p "$root"
cleanup() { rm -rf "$root"; }
trap cleanup EXIT

fail=0

# Preferences stanzas as <packages>\t<pin>\t<priority>; "#" comments and
# field-continuation lines are not fields.
stanzas() {
  awk '
    function flush() { if (pkg != "") printf "%s\t%s\t%s\n", pkg, pin, pri; pkg = pin = pri = "" }
    {
      if ($0 ~ /^[[:space:]]*$/) { flush(); next }
      if ($0 ~ /^Package:[[:space:]]/) { pkg = $0; sub(/^Package:[[:space:]]*/, "", pkg) }
      else if ($0 ~ /^Pin:[[:space:]]/) { pin = $0; sub(/^Pin:[[:space:]]*/, "", pin) }
      else if ($0 ~ /^Pin-Priority:[[:space:]]/) { pri = $0; sub(/^Pin-Priority:[[:space:]]*/, "", pri) }
    }
    END { flush() }
  ' "$1"
}

# Validate one preferences file; prints a FAIL line per problem.
check_pin() {
  local f="$1"
  local bad=0 s map neg sys t comp pkgs d p
  local -a pk

  if [ ! -f "$f" ]; then
    printf 'FAIL pin file missing: %s\n' "$f"
    return 1
  fi
  s="$(stanzas "$f")"

  block() {
    printf '%s\n' "$s" | awk -F'\t' -v p="$1" -v q="$2" '$2 == p && $3 == q { n++ } END { exit (n > 0 ? 0 : 1) }'
  }

  if ! block 'origin ""' 999; then
    printf 'FAIL missing local-origin block: Package: * / Pin: origin "" / Pin-Priority: 999\n'
    bad=1
  fi
  if ! block 'origin download.proxmox.com' 100; then
    printf 'FAIL missing Proxmox-origin block: Pin: origin download.proxmox.com / Pin-Priority: 100\n'
    bad=1
  fi
  if ! printf '%s\n' "$s" | awk -F'\t' '$2 == "origin download.proxmox.com" && $3 == 600 && $1 ~ /swtpm/ { n++ } END { exit (n > 0 ? 0 : 1) }'; then
    printf 'FAIL swtpm swtpm-libs swtpm-tools no longer pinned 600 from the Proxmox origin\n'
    bad=1
  fi

  # Packages refused outright from the Proxmox origin, and the "# component ->
  # package" comment that explains which component builds each of them.
  neg="$(printf '%s\n' "$s" | awk -F'\t' '$3 == "-1" && $2 == "origin download.proxmox.com" { print $1 }' | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u || true)"
  map="$(sed -n 's/^#[[:space:]]*\([a-z0-9][-a-z0-9]*\)[[:space:]]*->[[:space:]]*\(.*\)$/\1\t\2/p' "$f")"

  if [ -z "$neg" ]; then
    printf 'FAIL no Pin-Priority: -1 block from the Proxmox origin\n'
    bad=1
  fi
  for d in patches/*/; do
    comp="${d%/}"
    comp="${comp#patches/}"
    pkgs="$(printf '%s\n' "$map" | awk -F'\t' -v c="$comp" '$1 == c { print $2 }')"
    if [ -z "$pkgs" ]; then
      printf 'FAIL patches/%s has no "# <component> -> <package>" mapping comment\n' "$comp"
      bad=1
      continue
    fi
    read -ra pk <<< "$pkgs"
    for p in "${pk[@]}"; do
      if ! printf '%s\n' "$neg" | grep -qx -- "$p"; then
        printf 'FAIL %s (built from %s) is not refused from the Proxmox origin at -1\n' "$p" "$comp"
        bad=1
      fi
    done
  done
  while IFS= read -r comp; do
    [ -n "$comp" ] || continue
    if ! printf '%s\n' "$map" | cut -f1 | grep -qx -- "$comp"; then
      printf 'FAIL component %s (config/upstream-overrides.txt) missing from the mapping comment\n' "$comp"
      bad=1
    fi
  done < <(grep -vE '^[[:space:]]*(#|$)' config/upstream-overrides.txt | cut -d' ' -f1)

  # The block that keeps the service manager out must name packages only.
  sys="$(printf '%s\n' "$s" | awk -F'\t' '$3 == "-1" && $2 == "version *" { print $1 }' || true)"
  if [ -z "$sys" ]; then
    printf 'FAIL no Pin: version * / Pin-Priority: -1 block for the packages to keep out\n'
    bad=1
  fi
  for t in $sys; do
    if [[ ! "$t" =~ ^[a-z0-9][-a-z0-9_.+]*$ ]]; then
      printf 'FAIL the block to keep out names %s, which is not a package name\n' "$t"
      bad=1
    fi
    if [[ "$t" =~ ^[a-z]*system[a-z]*ctl$ ]]; then
      printf 'FAIL the block to keep out names %s: the service manager command itself, not a package\n' "$t"
      bad=1
    fi
    case "$t" in
      /* | *.service | *.target | *.socket | *.timer | *.unit | *.conf)
        printf 'FAIL the block to keep out names %s: a path or a unit file, not a package\n' "$t"
        bad=1
        ;;
    esac
  done
  if printf '%s\n' "$s" | awk -F'\t' '$1 ~ /systemd/ && $2 ~ /^origin/ { n++ } END { exit (n > 0 ? 0 : 1) }'; then
    printf 'FAIL a package to keep out is pinned by origin: no service manager may be named as an origin\n'
    bad=1
  fi

  return "$bad"
}

# 1) the real file must pass
if ! check_pin "$pin"; then
  fail=1
fi

# 2) apt itself must parse it: preferences syntax is easy to get wrong (a
#   continuation line without its leading space makes apt reject the record).
apt_out="$(apt-cache policy -o "Dir::Etc::preferences=$PWD/$pin" bash 2>&1 || true)"
if printf '%s\n' "$apt_out" | grep -qE '^E: '; then
  printf 'FAIL apt rejects the pin file:\n'
  printf '%s\n' "$apt_out" | grep -E '^E: '
  fail=1
fi

# 3) a deliberately malformed copy must be rejected, by check_pin and by apt
bad="$root/bad-origins"
sed '/^Package: pve-rs /d' "$pin" > "$bad"
if check_pin "$bad" >/dev/null 2>&1; then
  printf 'FAIL check_pin accepted a pin file with its -1 Package: header deleted\n'
  fail=1
fi
bad_out="$(apt-cache policy -o "Dir::Etc::preferences=$PWD/$bad" bash 2>&1 || true)"
if printf '%s\n' "$bad_out" | grep -qE '^E: '; then
  printf 'OK: apt rejects a malformed copy (%s)\n' "$(printf '%s\n' "$bad_out" | grep -m1 -E '^E: ' | cut -d, -f1)"
else
  printf 'FAIL apt parsed a malformed copy of the pin file without an error\n'
  fail=1
fi

# 4) the package must install it, at mode 0644
for pat in \
  'mkdir -p debian/supermox-ve/etc/apt/preferences.d' \
  'cp -a etc/apt/preferences.d/supermox-origins debian/supermox-ve/etc/apt/preferences.d/supermox-origins' \
  'chmod 0644 debian/supermox-ve/etc/apt/preferences.d/supermox-origins'; do
  if ! grep -qF -- "$pat" "$rules"; then
    printf 'FAIL %s does not install the pin file: %s\n' "$rules" "$pat"
    fail=1
  fi
done

# 5) the build scripts must copy that file, never re-type the pins
for s in scripts/vm-setup-proxmox-repos.sh scripts/build-iso.sh; do
  if grep -qE 'preferences\.d/supermox-origins *<<|supermox\.pref\.chroot *<<' "$s"; then
    printf 'FAIL %s still writes the pin file from an inline heredoc\n' "$s"
    fail=1
  fi
  for pat in 'Pin-Priority: 999' 'Pin-Priority: 600' 'Pin: origin ""'; do
    if grep -qF -- "$pat" "$s"; then
      printf 'FAIL %s still carries an inline pin block (%s)\n' "$s" "$pat"
      fail=1
    fi
  done
  if ! grep -q 'etc/apt/preferences.d/supermox-origins' "$s"; then
    printf 'FAIL %s does not reference the shipped pin file\n' "$s"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: supermox-ve ships the apt origin pins: local 999 > Proxmox 100, swtpm 600, every rebuilt package refused from the Proxmox origin at -1, a packages-only block keeping the service manager out, and neither build script re-types the pins"
