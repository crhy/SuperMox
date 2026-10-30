#!/usr/bin/env bash
# Offline check that keeps config/upstream-overrides.txt honest.
# For each override line: validate format, and (when the local clone exists)
# confirm the pinned commit is present and compare the override version against
# the version PXVIRT's own submodule pin points at.
# Output, one line per component: OK|WARN|FAIL|SKIP <component> override=<ver> pxvirt=<ver>
#   OK   override is needed (PXVIRT's pin is older than the override)
#   WARN PXVIRT's pin is >= the override version -> the override can be dropped
#   FAIL bad format, missing "# reason", non-40-hex commit, or commit absent from the clone
#   SKIP no local clone to check against
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overrides_file="${1:-$repo_root/config/upstream-overrides.txt}"
pxvirt="$repo_root/upstream/pxvirt"

if [ ! -f "$overrides_file" ]; then
  printf 'FAIL overrides file not found: %s\n' "$overrides_file"
  exit 1
fi

# Extract the Debian version from a changelog first line: "<pkg> (<ver>) <dist>; ..."
# Returns empty when the line has no "(...)" (e.g. no debian/changelog at that path).
extract_ver() {
  local line="$1" rest
  case "$line" in
    *'('*')'*)
      rest="${line#*(}"
      printf '%s' "${rest%%)*}"
      ;;
    *) printf '' ;;
  esac
}

overall=0
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  case "$line" in '#'*) continue ;; esac

  before="${line%%#*}"
  reason="${line#*#}"
  reason="${reason#"${reason%%[![:space:]]*}"}"
  read -r comp url commit extra <<< "$before"

  if [ -z "${comp:-}" ] || [ -z "${url:-}" ] || [ -z "${commit:-}" ] || [ -n "${extra:-}" ]; then
    printf 'FAIL %s bad format (line %d): %s\n' "${comp:-?}" "$lineno" "$line"
    overall=1
    continue
  fi
  if [ -z "$reason" ]; then
    printf 'FAIL %s missing "# reason" (line %d)\n' "$comp" "$lineno"
    overall=1
    continue
  fi
  if ! printf '%s' "$commit" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf 'FAIL %s commit not 40-hex: %s\n' "$comp" "$commit"
    overall=1
    continue
  fi

  clone="$pxvirt/packages/$comp/$comp"
  if [ ! -d "$clone" ]; then
    printf 'SKIP %s no local clone\n' "$comp"
    continue
  fi
  if ! git -C "$clone" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    printf 'FAIL %s override commit absent from clone: %s\n' "$comp" "$commit"
    overall=1
    continue
  fi

  ov_line="$( { git -C "$clone" show "${commit}:debian/changelog" 2>/dev/null || true; } | head -1)"
  ov_ver="$(extract_ver "${ov_line:-}")"
  [ -n "$ov_ver" ] || ov_ver="$commit"

  pin="$( { git -C "$pxvirt" ls-tree HEAD -- "packages/$comp/$comp" || true; } | awk '{print $3}')"
  pv_ver=""
  if [ -n "$pin" ] && git -C "$clone" cat-file -e "${pin}^{commit}" 2>/dev/null; then
    pv_line="$( { git -C "$clone" show "${pin}:debian/changelog" 2>/dev/null || true; } | head -1)"
    pv_ver="$(extract_ver "${pv_line:-}")"
  fi
  pv_is_ver=1
  [ -n "$pv_ver" ] || pv_is_ver=0
  [ -n "$pv_ver" ] || pv_ver="${pin:-unknown}"

  status="OK"
  if [ "$pv_is_ver" -eq 1 ] && [ "$ov_ver" != "$commit" ] && dpkg --compare-versions "$pv_ver" ge "$ov_ver" 2>/dev/null; then
    status="WARN"
  fi
  printf '%s %s override=%s pxvirt=%s\n' "$status" "$comp" "$ov_ver" "$pv_ver"
done < "$overrides_file"

exit "$overall"
