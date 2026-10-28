#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dir="init.d"
if [ ! -d "$dir" ]; then
  echo "FAIL: $dir does not exist"
  exit 1
fi

fail=0
count=0

for_field="Provides: Required-Start: Required-Stop: Default-Start: Default-Stop: Short-Description:"

while IFS= read -r -d '' f; do
  count=$((count + 1))
  reasons=""

  if ! sh -n "$f" 2>/dev/null; then
    reasons="$reasons sh-n"
  fi

  for field in $for_field; do
    if ! grep -qF "$field" "$f"; then
      reasons="$reasons missing:$field"
    fi
  done

  for label in start stop restart status; do
    if ! grep -qE "^[[:space:]]*${label}\)" "$f"; then
      reasons="$reasons no-case:$label"
    fi
  done

  if grep -qE "systemctl|systemd|sd_notify|journalctl" "$f"; then
    reasons="$reasons systemd-text"
  fi

  if [ -n "$reasons" ]; then
    echo "FAIL: $f ($reasons)"
    fail=1
  else
    echo "OK: $f"
  fi
done < <(find "$dir" -maxdepth 1 -type f -print0)

if [ "$count" -eq 0 ]; then
  echo "FAIL: no files in $dir"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: all $count init.d scripts pass"
