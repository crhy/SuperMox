#!/usr/bin/env bash
set -euo pipefail

PXVIRT_URL=https://github.com/jiangcuo/pxvirt
PXVIRT_COMMIT=57302a2060f34e158b81c471ea68e9ee02ef5d5a
COMPONENTS=(
  pve-manager
  pve-cluster
  pve-common
  qemu-server
  pve-container
  pve-storage
  pve-access-control
  pve-ha-manager
  pve-firewall
  pve-http-server
  pve-guest-common
  proxmox-ve
  proxmox-perl-rs
)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo_root/upstream/pxvirt"
overrides_file="$repo_root/config/upstream-overrides.txt"

declare -a ov_component ov_url ov_commit

parse_overrides() {
  [ -f "$overrides_file" ] || return 0
  local line before reason comp url commit extra lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
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
    if [ -z "$comp" ] || [ -z "$url" ] || [ -z "$commit" ] || [ -n "${extra:-}" ]; then
      printf 'ERROR: override line %d malformed (expected "<component> <git-url> <commit>  # <reason>"): %s\n' "$lineno" "$line" >&2
      exit 2
    fi
    ov_component+=("$comp")
    ov_url+=("$url")
    ov_commit+=("$commit")
  done < "$overrides_file"
}

if [ "${1:-}" = "--list" ]; then
  for c in "${COMPONENTS[@]}"; do
    printf '%s\n' "$c"
  done
  exit 0
fi

if [ "${1:-}" = "--list-overrides" ]; then
  parse_overrides
  for i in "${!ov_component[@]}"; do
    printf '%s %s\n' "${ov_component[$i]}" "${ov_commit[$i]}"
  done
  exit 0
fi

if [ ! -d "$dest" ]; then
  git clone --branch pxvirt "$PXVIRT_URL" "$dest"
  git -C "$dest" checkout "$PXVIRT_COMMIT"
else
  head="$(git -C "$dest" rev-parse HEAD)"
  if [ "$head" != "$PXVIRT_COMMIT" ]; then
    echo "ERROR: $dest HEAD is $head, expected $PXVIRT_COMMIT" >&2
    exit 1
  fi
fi

for c in "${COMPONENTS[@]}"; do
  git -C "$dest" submodule update --init --depth 1 "packages/$c/$c"
done

parse_overrides
for i in "${!ov_component[@]}"; do
  comp="${ov_component[$i]}"
  url="${ov_url[$i]}"
  commit="${ov_commit[$i]}"
  co="$dest/packages/$comp/$comp"
  head="$(git -C "$co" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    git -C "$co" fetch --depth 1 "$url" "$commit"
    git -C "$co" checkout "$commit"
  fi
done
