#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -d upstream/pxvirt/packages/pve-manager ]; then
  echo "SKIP"
  exit 0
fi

tmp="build/test-init-sync"
rm -rf "$tmp"
mkdir -p "$tmp"

if ! bash scripts/apply-patches.sh "$tmp/patched" >/dev/null; then
  echo "FAIL: apply-patches.sh failed"
  exit 1
fi

# Upstream components (from fetch-upstream.sh --list) get their debian/<pkg>.<svc>.init
# copied by apply-patches.sh; packaging/<name> dirs get theirs copied by vm-build-pkg.sh
# (which needs a VM), so here we reproduce that same copy into a staged dir.
components=()
while IFS= read -r c; do
  [ -n "$c" ] && components+=("$c")
done < <(bash scripts/fetch-upstream.sh --list)

is_component() {
  local want="$1" c
  for c in "${components[@]}"; do
    [ "$c" = "$want" ] && return 0
  done
  return 1
}

fail=0
checked=0

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -n "$line" ] || continue
  read -r comp pkg svc <<< "$line"

  if [ ! -f "init.d/$svc" ]; then
    echo "FAIL: $line (no init.d/$svc source)"
    fail=1
    continue
  fi

  if is_component "$comp"; then
    target="$tmp/patched/$comp/$comp/debian/$pkg.$svc.init"
  else
    stage="$tmp/stage/$comp"
    if [ ! -d "packaging/$comp" ]; then
      echo "FAIL: $line (no packaging/$comp dir)"
      fail=1
      continue
    fi
    rm -rf "$stage"
    mkdir -p "$stage"
    rsync -a --exclude .git "packaging/$comp/" "$stage/"
    mkdir -p "$stage/debian"
    install -m 0755 "init.d/$svc" "$stage/debian/$pkg.$svc.init"
    target="$stage/debian/$pkg.$svc.init"
  fi

  if [ ! -f "$target" ]; then
    echo "FAIL: $line (missing target $target)"
    fail=1
    continue
  fi
  if ! cmp -s "$target" "init.d/$svc"; then
    echo "FAIL: $line (target differs from init.d/$svc)"
    fail=1
    continue
  fi
  checked=$((checked + 1))
done < config/init-scripts.txt

if [ "$checked" -eq 0 ]; then
  echo "FAIL: config/init-scripts.txt has no usable lines"
  exit 1
fi

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: all $checked init.d copies are byte-identical to their source"
