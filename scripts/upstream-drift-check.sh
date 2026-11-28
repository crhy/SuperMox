#!/usr/bin/env bash
# Upstream drift check (docs/notes/supermox-track-current-proxmox.md, task u05):
# compare every component pinned in config/upstream-overrides.txt against the
# version Proxmox's trixie pve-no-subscription repo ships *now*, so we rebuild
# promptly when Proxmox moves instead of letting drift pile up.
#
# Output, one line per component:
#   in-sync <component> <version>                       pinned version matches the index
#   DRIFT <component> pinned <X> but trixie ships <Y>   the index ships a different version
#   UNKNOWN <component> not found in the index          no Package:/Source: stanza matches
#
# Exit: 0 no drift, 1 any drift, 2 usage error or malformed overrides line.
# Offline for tests: --packages <file> reads the Packages index from disk;
# without it the index is fetched from the pve-no-subscription repo.
set -euo pipefail

usage() {
  printf 'usage: %s [--packages <Packages-file>] [--overrides <file>] [--list]\n' "${0##*/}" >&2
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overrides_file="$repo_root/config/upstream-overrides.txt"
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
  if (src != "") { split(src, a, " "); if (a[1] != pkg) print "S", a[1], a[2] }
}
' "$index" > "$tmp_digest"; then
  printf 'ERROR: cannot digest the Packages index\n' >&2
  cleanup
  exit 2
fi

declare -A pkg_ver src_ver
while read -r kind name version; do
  [ -n "${name:-}" ] || continue
  case "$kind" in
    B) [ -z "${pkg_ver[$name]+x}" ] && pkg_ver[$name]="$version" ;;
    S) [ -z "${src_ver[$name]+x}" ] && src_ver[$name]="$version" ;;
  esac
done < "$tmp_digest"
cleanup

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
  idx=""
  if [ -n "${pkg_ver[$comp]+x}" ]; then
    idx="${pkg_ver[$comp]}"
  elif [ -n "${src_ver[$comp]+x}" ]; then
    idx="${src_ver[$comp]}"
  fi
  if [ -z "$idx" ]; then
    printf 'UNKNOWN %s not found in the index\n' "$comp"
  elif [ "$(norm_ver "$pinned")" = "$(norm_ver "$idx")" ]; then
    printf 'in-sync %s %s\n' "$comp" "$pinned"
  else
    printf 'DRIFT %s pinned %s but trixie ships %s\n' "$comp" "$pinned" "$idx"
    drift=1
  fi
done

exit "$drift"
