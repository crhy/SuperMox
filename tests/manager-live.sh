#!/usr/bin/env bash
# Live tests against a running SuperMox VM. Not part of the gate: it needs a
# booted VM with the test image (ssh port 2224, root password supermox).
# Skips (exit 0) when no VM is running.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ssh_port="${SUPERMOX_VM_SSH_PORT:-2224}"

# Skip unless a VM is up.
if [ "$(bash "$root/scripts/vm-status.sh")" = "no SuperMox VM running" ]; then
  echo "SKIP: manager-live: no VM running"
  exit 0
fi

# The guest's API listens on 8006 and pveproxy answers plain HTTP there too
# (a 301/308 redirect to https), so the transport has to carry the TLS
# ClientHello intact. QEMU's user-mode hostfwd does not: under load it
# delivers the hello in pieces, pveproxy's sniff then reads it as plain HTTP,
# and the client gets "SSL: WRONG_VERSION_NUMBER" about 15% of the time.
# Forward through ssh instead, which is a plain TCP pipe.
api_port="${SUPERMOX_LIVE_PORT:-18006}"
while python3 -c "
import socket, sys
s = socket.socket()
try:
    s.bind(('127.0.0.1', int(sys.argv[1])))
except OSError:
    sys.exit(0)
sys.exit(1)
" "$api_port"; do
  api_port=$((api_port + 1))
done

sshpass -p supermox ssh -p "$ssh_port" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ExitOnForwardFailure=yes -N \
  -L "${api_port}:127.0.0.1:8006" root@127.0.0.1 &
tunnel=$!
cleanup() {
  kill "$tunnel" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# The tunnel only answers once ssh has set the forward up; a TLS handshake
# that succeeds is the proof, and it costs nothing to wait for it.
for _ in $(seq 1 20); do
  if python3 -c "
import socket, ssl, sys
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    plain = socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=5)
    ctx.wrap_socket(plain, server_hostname=None).close()
except Exception:
    sys.exit(1)
" "$api_port"; then
    break
  fi
  sleep 1
done

# Read the SHA-256 fingerprint of the guest's own /etc/pve/local/pve-ssl.pem:
# DER bytes of the leaf certificate, exactly what api.Client pins.
pin="$(SUPERMOX_VM_SSH_PORT="$ssh_port" bash "$root/scripts/vm-ssh.sh" \
  "openssl x509 -in /etc/pve/local/pve-ssl.pem -outform der 2>/dev/null | sha256sum | cut -d' ' -f1" \
  | tr -d '[:space:]')"

if ! printf '%s' "$pin" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "SKIP: manager-live: could not read the SSL fingerprint (VM not reachable yet)"
  exit 0
fi

export SUPERMOX_LIVE_URL="https://127.0.0.1:${api_port}/"
export SUPERMOX_LIVE_PIN="$pin"
export SUPERMOX_LIVE_USER="root@pam"
export SUPERMOX_LIVE_PASSWORD="supermox"
# Some live tests read the shorter name; keep both in sync.
export SUPERMOX_LIVE_PASS="$SUPERMOX_LIVE_PASSWORD"

# The live test dir is not a package (hyphen in the name), so make it the
# top-level dir for discovery; supermox_manager comes in via src on the path.
PYTHONPATH="$root/src:$root/tests/manager-live" \
  python3 -m unittest discover -s "$root/tests/manager-live" \
  -p "${1:-test_*.py}" -v
