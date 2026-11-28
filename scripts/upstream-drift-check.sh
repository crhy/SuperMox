#!/usr/bin/env bash
# Upstream drift check (docs/notes/supermox-track-current-proxmox.md, task u05):
# compare every component pinned in config/upstream-overrides.txt against the
# version Proxmox's trixie pve-no-subscription repo ships *now*, so we rebuild
# promptly when Proxmox moves instead of letting drift pile up.
#
# The Packages index lists EVERY version Proxmox has published (oldest first),
# so for each component we take the HIGHEST version among all stanzas whose
# Package: or Source: (name part) matches, ordered by dpkg version rules
# (dpkg --compare-versions, python3 apt_pkg fallback) - never string order.
# Components whose names are SOURCE package names that the index never spells
# in a Source: field (pve-common & co, f265b) resolve by their binary package
# names, recorded in config/upstream-source-binaries.txt.
#
# Output, one line per component:
#   in-sync <component> <version>                                pin == newest in the index
#   BEHIND <component> pinned <X> but trixie ships <Y>           pin < newest: the real drift
#   AHEAD <component> pinned <X> but newest in the index is <Y>  pin > newest: say so, not an error
#   UNKNOWN <component> not found in the index                   no Package:, Source: or alias match
#
# Exit: 0 no drift (in-sync/AHEAD/UNKNOWN), 1 any BEHIND, 2 usage error or malformed overrides line.
# Offline for tests: --packages <file> reads the Packages index from disk;
# without it the index is fetched from the pve-no-subscription repo.
set -euo pipefail

usage() {
  printf 'usage: %s [--packages <Packages-file>] [--overrides <file>] [--source-binaries <file>] [--list]\n' "${0##*/}" >&2
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overrides_file="$repo_root/config/upstream-overrides.txt"
mapping_file="$repo_root/config/upstream-source-binaries.txt"
packages_file=""
list_only=0

PACKAGES_URL="http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --packages)
      if [ "$#" -lt 2 ]; then
        printf 'ERROR: --packages requires a file\n' >&2
        usage
        exit 2
      fi
      packages_file="$2"
      shift 2
      ;;
    --overrides)
      if [ "$#" -lt 2 ]; then
        printf 'ERROR: --overrides requires a file\n' >&2
        usage
        exit 2
      fi
      overrides_file="$2"
      shift 2
      ;;
    --source-binaries)
      if [ "$#" -lt 2 ]; then
        printf 'ERROR: --source-binaries requires a file\n' >&2
        usage
        exit 2
      fi
      mapping_file="$2"
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ ! -f "$overrides_file" ]; then
  printf 'ERROR: overrides file not found: %s\n' "$overrides_file" >&2
  exit 2
fi

# Parse the component lines, same format rules as check-overrides.sh and
# fetch-upstream.sh: "<component> <git-url> <commit>  # <reason>"; a line
# without a "# reason" is an error per the file's own header. The recorded
# version is the first token of the reason that starts with a digit (with any
# trailing comma stripped), e.g. "9.2.24" in "# 9.2.24, as in Proxmox's trixie
# repo" or "0.15.3" in "# pve-rs 0.15.3, matches Proxmox's current crates".
declare -a ov_comp ov_ver
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  case "$line" in '#'*) continue ;; esac

  before="${line%%#*}"
  if [ "$before" = "$line" ]; then
    printf 'ERROR: override line %d has no "# reason": %s\n' "$lineno" "$line" >&2
    exit 2
  fi
  reason="${line#*#}"
  reason="${reason#"${reason%%[![:space:]]*}"}"
  if [ -z "$reason" ]; then
    printf 'ERROR: override line %d has empty reason: %s\n' "$lineno" "$line" >&2
    exit 2
  fi
  read -r comp url commit extra <<< "$before"
  if [ -z "${comp:-}" ] || [ -z "${url:-}" ] || [ -z "${commit:-}" ] || [ -n "${extra:-}" ]; then
    printf 'ERROR: override line %d malformed (expected "<component> <git-url> <commit>  # <reason>"): %s\n' "$lineno" "$line" >&2
    exit 2
  fi
  ver=""
  for tok in $reason; do
    tok="${tok%,}"
    case "$tok" in
      [0-9]*) ver="$tok"; break ;;
    esac
  done
  if [ -z "$ver" ]; then
    printf 'ERROR: override line %d has no version in the "# reason": %s\n' "$lineno" "$line" >&2
    exit 2
  fi
  ov_comp+=("$comp")
  ov_ver+=("$ver")
done < "$overrides_file"

if [ "$list_only" -eq 1 ]; then
  for i in "${!ov_comp[@]}"; do
    printf '%s %s\n' "${ov_comp[$i]}" "${ov_ver[$i]}"
  done
  exit 0
fi

# The Packages index: from --packages (gz variants accepted), or fetched.
index=""
tmp_index=""
tmp_digest=""
cleanup() {
  [ -n "$tmp_index" ] && rm -f "$tmp_index"
  [ -n "$tmp_digest" ] && rm -f "$tmp_digest"
  return 0
}
if [ -n "$packages_file" ]; then
  if [ ! -f "$packages_file" ]; then
    printf 'ERROR: Packages index not found: %s\n' "$packages_file" >&2
    exit 2
  fi
  case "$packages_file" in
    *.gz)
      tmp_index="$(mktemp)"
      if ! gzip -dc "$packages_file" > "$tmp_index"; then
        printf 'ERROR: cannot decompress %s\n' "$packages_file" >&2
        cleanup
        exit 2
      fi
      index="$tmp_index"
      ;;
    *) index="$packages_file" ;;
  esac
else
  printf 'Fetching %s\n' "$PACKAGES_URL" >&2
  tmp_index="$(mktemp)"
  if ! curl -fsSL --retry 3 -o "$tmp_index" "$PACKAGES_URL"; then
    printf 'ERROR: fetch failed: %s\n' "$PACKAGES_URL" >&2
    cleanup
    exit 2
  fi
  index="$tmp_index"
fi

# Digest the index into "B <binary> <version>" and "S <source-name> <source-version>"
# lines: source-only names (proxmox-perl-rs) carry no Package: stanza of their
# own, so the Source: field is what resolves them.
tmp_digest="$(mktemp)"
if ! awk '
BEGIN { RS = ""; FS = "\n" }
{
  pkg = ""; ver = ""; src = ""
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^Package: /) pkg = substr($i, 10)
    else if ($i ~ /^Version: /) ver = substr($i, 10)
    else if ($i ~ /^Source: /) src = substr($i, 9)
  }
  if (pkg != "" && ver != "") print "B", pkg, ver
  if (src != "") {
    gsub(/[()]/, "", src)
    split(src, a, " ")
    if (a[1] != "" && a[2] != "" && a[1] != pkg) print "S", a[1], a[2]
  }
}
' "$index" > "$tmp_digest"; then
  printf 'ERROR: cannot digest the Packages index\n' >&2
  cleanup
  exit 2
fi

# Debian version ordering: dpkg first, python3's apt_pkg as a fallback. Never
# plain string order: "6.0.6-1" sorts BELOW "6.0.6~rc1-1" bytewise, the exact
# opposite of dpkg's rule.
ver_kind=""
if command -v dpkg >/dev/null 2>&1; then
  ver_kind="dpkg"
elif python3 -c 'import apt_pkg' >/dev/null 2>&1; then
  ver_kind="apt_pkg"
else
  printf 'ERROR: comparing versions needs dpkg or python3 apt_pkg\n' >&2
  cleanup
  exit 2
fi

# ver_cmp a b -> echoes lt, eq or gt for a vs b in Debian version order.
ver_cmp() {
  local a="$1" b="$2"
  if [ "$a" = "$b" ]; then
    printf 'eq'
    return
  fi
  case "$ver_kind" in
    dpkg)
      if dpkg --compare-versions "$a" lt "$b"; then
        printf 'lt'
      elif dpkg --compare-versions "$a" gt "$b"; then
        printf 'gt'
      else
        printf 'eq'
      fi
      ;;
    apt_pkg)
      python3 -c 'import apt_pkg, sys
apt_pkg.init_system()
c = apt_pkg.version_compare(sys.argv[1], sys.argv[2])
print("lt" if c < 0 else "gt" if c > 0 else "eq")' "$a" "$b"
      ;;
  esac
}

# One entry per name: the HIGHEST version among all stanzas whose Package: or
# Source: name matches (the index lists every version, oldest first, so the
# first match is the OLDEST - that is the bug this reduces away).
declare -A best_ver
while read -r kind name version; do
  [ -n "${name:-}" ] && [ -n "${version:-}" ] || continue
  case "$kind" in
    B | S)
      if [ -z "${best_ver[$name]+x}" ]; then
        best_ver[$name]="$version"
      elif [ "$(ver_cmp "$version" "${best_ver[$name]}")" = "gt" ]; then
        best_ver[$name]="$version"
      fi
      ;;
  esac
done < "$tmp_digest"
cleanup

# Source-only components (f265b): their names are SOURCE package names, and the
# live binary Packages index carries "Source:" fields only on foreign entries
# (lvm2, apparmor, ceph), never on the libpve-*-perl stanzas - and the repo
# publishes no source/Sources index (404). They resolve by their binary
# package names, recorded one line per component in --source-binaries.
declare -A comp_alias
if [ -f "$mapping_file" ]; then
  while read -r comp bins; do
    [ -n "${comp:-}" ] || continue
    case "$comp" in '#'*) continue ;; esac
    comp_alias[$comp]="$bins"
  done < "$mapping_file"
fi

# Normalize a version for comparison: strip the epoch and the Debian revision
# (everything after the last hyphen), so the recorded "9.2.5" matches the index
# version "9.2.5-1".
norm_ver() {
  local v="$1"
  case "$v" in
    [0-9]*:*) v="${v#*:}" ;;
  esac
  if [[ "$v" == *-* ]]; then
    v="${v%-*}"
  fi
  printf '%s' "$v"
}

drift=0
for i in "${!ov_comp[@]}"; do
  comp="${ov_comp[$i]}"
  pinned="${ov_ver[$i]}"
  key="$comp"
  if [ -z "${best_ver[$key]+x}" ] && [ -n "${comp_alias[$comp]+x}" ]; then
    for cand in ${comp_alias[$comp]}; do
      if [ -n "${best_ver[$cand]+x}" ]; then
        key="$cand"
        break
      fi
    done
  fi
  if [ -z "${best_ver[$key]+x}" ]; then
    printf 'UNKNOWN %s not found in the index\n' "$comp"
    continue
  fi
  newest="${best_ver[$key]}"
  # The pins carry no Debian revision ("9.2.5" vs the index "9.2.5-1"), so
  # compare the normalized versions.
  rel="$(ver_cmp "$(norm_ver "$pinned")" "$(norm_ver "$newest")")"
  case "$rel" in
    lt)
      printf 'BEHIND %s pinned %s but trixie ships %s\n' "$comp" "$pinned" "$newest"
      drift=1
      ;;
    gt)
      printf 'AHEAD %s pinned %s but newest in the index is %s\n' "$comp" "$pinned" "$newest"
      ;;
    *)
      printf 'in-sync %s %s\n' "$comp" "$pinned"
      ;;
  esac
done

exit "$drift"
