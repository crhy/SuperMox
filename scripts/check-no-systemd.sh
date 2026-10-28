#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_PAT='systemctl|sd_notify|libsystemd|systemd-run|journalctl|dh_installsystemd|dh-sequence-systemd|systemd-sysv'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

TMP_RAW="$repo_root/build/check-no-systemd.raw"
TMP_SORTED="$repo_root/build/check-no-systemd.sorted"

cleanup() {
  rm -f "$TMP_RAW" "$TMP_SORTED"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s --image ROOTFS | --source DIR\n' "${0##*/}" >&2
}

image_mode() {
  local root="$1"
  local fail=0
  local status="$root/var/lib/dpkg/status"

  if [ -f "$status" ]; then
    local pkg
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      printf 'FAIL: installed package matches systemd: %s\n' "$pkg"
      fail=1
    done < <(awk '
      /^Package:/ { pkg=$0; sub(/^Package:[ \t]*/, "", pkg) }
      /^Status:/  { st=$0;  sub(/^Status:[ \t]*/, "", st) }
      /^$/        { if (st=="install ok installed" && pkg ~ /systemd/) print pkg; pkg=""; st="" }
      END         { if (st=="install ok installed" && pkg ~ /systemd/) print pkg }
    ' "$status")
  fi

  local p
  for p in bin/systemctl usr/bin/systemctl lib/systemd/systemd usr/lib/systemd/systemd bin/journalctl usr/bin/journalctl; do
    if [ -e "$root/$p" ]; then
      printf 'FAIL: systemd binary present: %s\n' "$p"
      fail=1
    fi
  done

  local init=""
  if [ -e "$root/sbin/init" ] || [ -L "$root/sbin/init" ]; then
    init="$root/sbin/init"
  elif [ -e "$root/usr/sbin/init" ] || [ -L "$root/usr/sbin/init" ]; then
    init="$root/usr/sbin/init"
  fi

  if [ -n "$init" ] && [ -L "$init" ]; then
    local tgt
    tgt="$(readlink "$init")"
    case "$tgt" in
      *systemd*)
        printf 'FAIL: init symlink targets systemd: %s -> %s\n' "$init" "$tgt"
        fail=1
        ;;
    esac
  fi

  if [ -z "$init" ]; then
    printf 'FAIL: no init at sbin/init or usr/sbin/init\n'
    fail=1
  fi

  local unit_dirs=(lib/systemd/system usr/lib/systemd/system etc/systemd lib/systemd/user usr/lib/systemd/user)
  local shown=0
  local d entry rel
  for d in "${unit_dirs[@]}"; do
    if [ -d "$root/$d" ]; then
      while IFS= read -r -d '' entry; do
        fail=1
        if [ "$shown" -lt 10 ]; then
          rel="${entry#"$root"/}"
          printf 'FAIL: systemd unit tree present: %s\n' "$rel"
          shown=$((shown + 1))
        fi
      done < <(find "$root/$d" \( -type f -o -type l \) -print0)
    fi
  done

  if [ "$fail" -ne 0 ]; then
    return 1
  fi
  printf 'No systemd found in image.\n'
  return 0
}

source_mode() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf 'ERROR: source dir not found: %s\n' "$dir" >&2
    return 2
  fi

  local baseline_file="${SYSTEMD_BASELINE_FILE:-$repo_root/config/systemd-baseline.txt}"
  if [ ! -f "$baseline_file" ]; then
    printf 'ERROR: baseline file not found: %s\n' "$baseline_file" >&2
    return 2
  fi

  local allowlist_file="${SYSTEMD_ALLOWLIST_FILE:-$repo_root/config/systemd-allowlist.txt}"
  local allow_globs=()
  if [ -f "$allowlist_file" ]; then
    local line glob reason
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [ -n "$line" ] || continue
      case "$line" in
        '#'*) continue ;;
      esac
      if [[ "$line" != *'#'* ]]; then
        printf 'ERROR: allowlist line without reason: %s\n' "$line" >&2
        return 2
      fi
      glob="${line%%#*}"
      reason="${line#*#}"
      glob="${glob%"${glob##*[![:space:]]}"}"
      reason="${reason#"${reason%%[![:space:]]*}"}"
      if [ -z "$glob" ] || [ -z "$reason" ]; then
        printf 'ERROR: allowlist line without reason: %s\n' "$line" >&2
        return 2
      fi
      allow_globs+=("$glob")
    done < "$allowlist_file"
  fi

  mkdir -p "$repo_root/build"

  find "$dir" -name .git -prune -o -type f \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.target' -o -name '*.path' -o -name '*.mount' \) -print0 > "$TMP_RAW"
  grep -rIlZE --exclude-dir=.git "$SYSTEMD_PAT" "$dir" >> "$TMP_RAW" || true
  LC_ALL=C sort -zu "$TMP_RAW" > "$TMP_SORTED"

  local n=0
  local allowed=0
  local f rel g match
  while IFS= read -r -d '' f; do
    rel="${f#"$dir"/}"
    match=0
    for g in "${allow_globs[@]}"; do
      # SC2053: glob matching is intended here (allowlist entries are patterns).
      # shellcheck disable=SC2053
      if [[ "$rel" == $g ]]; then
        match=1
        break
      fi
    done
    if [ "$match" -eq 1 ]; then
      allowed=$((allowed + 1))
      continue
    fi
    printf '%s\n' "$f"
    n=$((n + 1))
  done < "$TMP_SORTED"

  printf 'ALLOWED %s\n' "$allowed"
  printf 'COUNT %s\n' "$n"

  local baseline
  baseline="$(tr -dc '0-9' < "$baseline_file")"
  if [ -z "$baseline" ]; then
    printf 'ERROR: no number in baseline file: %s\n' "$baseline_file" >&2
    return 2
  fi
  if [ "$n" -le "$baseline" ]; then
    return 0
  fi
  printf 'FAIL: systemd references %s exceed baseline %s\n' "$n" "$baseline" >&2
  return 1
}

main() {
  case "${1:-}" in
    --image)
      if [ "$#" -lt 2 ]; then usage; return 2; fi
      image_mode "$2"
      ;;
    --source)
      if [ "$#" -lt 2 ]; then usage; return 2; fi
      source_mode "$2"
      ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
