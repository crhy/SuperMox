#!/usr/bin/env bash
# Live tests against a running SuperMox VM. Not part of the gate: it needs a
# booted VM with the test image (ssh port 2224, root password supermox).
# Skips (exit 0) when no VM is running.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# Skip unless a VM is up.
if [ "$(bash "$root/scripts/vm-status.sh")" = "no SuperMox VM running" ]; then
  echo "SKIP: manager-live: no VM running"
  exit 0
fi

# The test image forwards ssh on port 2224 (SUPERMOX_TEST_SSH_PORT). Read the
# SHA-256 fingerprint of the guest's own /etc/pve/local/pve-ssl.pem: DER bytes
# of the leaf certificate, exactly what api.Client pins.
pin="$(SUPERMOX_VM_SSH_PORT=2224 bash "$root/scripts/vm-ssh.sh" \
  "openssl x509 -in /etc/pve/local/pve-ssl.pem -outform der 2>/dev/null | sha256sum | cut -d' ' -f1" \
  | tr -d '[:space:]')"

if ! printf '%s' "$pin" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "SKIP: manager-live: could not read the SSL fingerprint (VM not reachable yet)"
  exit 0
fi

export SUPERMOX_LIVE_URL="https://127.0.0.1:18006/"
export SUPERMOX_LIVE_PIN="$pin"
export SUPERMOX_LIVE_USER="root@pam"
export SUPERMOX_LIVE_PASSWORD="supermox"
# Some live tests read the shorter name; keep both in sync.
export SUPERMOX_LIVE_PASS="$SUPERMOX_LIVE_PASSWORD"

# The live test dir is not a package (hyphen in the name), so make it the
# top-level dir for discovery; supermox_manager comes in via src on the path.
PYTHONPATH="$root/src:$root/tests/manager-live" \
  python3 -m unittest discover -s "$root/tests/manager-live" \
  -t "$root/tests/manager-live" -v
