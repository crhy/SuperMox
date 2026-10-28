#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_PAT='systemctl|sd_notify|libsystemd|systemd-run|journalctl|dh_installsystemd|dh-sequence-systemd|systemd-sysv'

TMP_RAW="build/check-no-systemd.raw"
TMP_SORTED="build/check-no-systemd.sorted"

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

  local baseline_file="${SYSTEMD_BASELINE_FILE:-config/systemd-baseline.txt}"
  if [ ! -f "$baseline_file" ]; then
    printf 'ERROR: baseline file not found: %s\n' "$baseline_file" >&2
    return 2
  fi

  mkdir -p build

  find "$dir" -name .git -prune -o -type f \
    \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.target' -o -name '*.path' -o -name '*.mount' \) -print0 > "$TMP_RAW"
  grep -rIlZE --exclude-dir=.git "$SYSTEMD_PAT" "$dir" >> "$TMP_RAW" || true
  LC_ALL=C sort -zu "$TMP_RAW" > "$TMP_SORTED"

  local n
  n="$(grep -zc . < "$TMP_SORTED" || true)"

  local f
  while IFS= read -r -d '' f; do
    printf '%s\n' "$f"
  done < "$TMP_SORTED"

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
