#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/vm-start.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

out="$(bash "$target" --dry-run)"

missing=0
for pat in '-cpu host' '-kernel' 'hostfwd=tcp:127.0.0.1:2223-:22'; do
  if ! printf '%s\n' "$out" | grep -qF -- "$pat"; then
    echo "FAIL: --dry-run output missing: $pat"
    missing=1
  fi
done

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "OK: vm-start.sh --dry-run prints -cpu host, -kernel and the hostfwd port"

# SUPERMOX_VM_FWD: extra hostfwd entries must appear in the -nic string, and a
# bad entry must be rejected.
fwd_out="$(SUPERMOX_VM_FWD='tcp:127.0.0.1:18006-:8006,tcp:127.0.0.1:18443-:443' bash "$target" --dry-run)"
for pat in 'hostfwd=tcp:127.0.0.1:18006-:8006' 'hostfwd=tcp:127.0.0.1:18443-:443'; do
  if ! printf '%s\n' "$fwd_out" | grep -qF -- "$pat"; then
    echo "FAIL: SUPERMOX_VM_FWD --dry-run output missing: $pat"
    exit 1
  fi
done
if SUPERMOX_VM_FWD='tcp:10.0.0.1:18006-:8006' bash "$target" --dry-run >/dev/null 2>&1; then
  echo "FAIL: SUPERMOX_VM_FWD accepted a non-localhost entry"
  exit 1
fi

echo "OK: vm-start.sh --dry-run appends SUPERMOX_VM_FWD hostfwd entries and rejects a non-localhost one"
