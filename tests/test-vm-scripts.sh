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

# A VM whose pidfile is gone (QEMU unlinks it when an older instance exits)
# must still be stoppable, only that VM, and vm-start.sh must refuse a second
# instance for the same VM_DIR. Fakes: copies of bash named like qemu, so their
# comm matches and their command line carries -pidfile <dir>/qemu.pid.
fake_root="$(pwd)/build/test-vm-pidless"
rm -rf "$fake_root"
mkdir -p "$fake_root/a" "$fake_root/b"
fake_bin="$fake_root/qemu-system-x86_64"
cp /bin/bash "$fake_bin"
"$fake_bin" -c 'sleep 60; :' x -pidfile "$fake_root/a/qemu.pid" &
fake_a=$!
"$fake_bin" -c 'sleep 60; :' x -pidfile "$fake_root/b/qemu.pid" &
fake_b=$!
cleanup_fakes() { kill "$fake_a" "$fake_b" 2>/dev/null || true; pkill -P "$fake_a" 2>/dev/null || true; pkill -P "$fake_b" 2>/dev/null || true; }
trap cleanup_fakes EXIT
sleep 1
if SUPERMOX_VM_DIR="$fake_root/a" timeout 20 bash scripts/vm-start.sh --background >/dev/null 2>&1; then
  echo "FAIL: vm-start.sh started a second instance for a VM_DIR that already runs one"
  exit 1
fi
if ! SUPERMOX_VM_DIR="$fake_root/a" timeout 40 bash scripts/vm-stop.sh >/dev/null 2>&1 || kill -0 "$fake_a" 2>/dev/null; then
  echo "FAIL: vm-stop.sh did not stop a running VM whose pidfile is missing"
  exit 1
fi
if ! kill -0 "$fake_b" 2>/dev/null; then
  echo "FAIL: vm-stop.sh for one VM_DIR stopped the VM of another"
  exit 1
fi
cleanup_fakes
rm -rf "$fake_root"
echo "OK: vm-stop.sh stops a pidfile-less VM by its command line (only that one); vm-start.sh refuses a second instance"
