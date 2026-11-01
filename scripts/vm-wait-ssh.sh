#!/usr/bin/env bash
# Wait (at most SUPERMOX_WAIT_SECS seconds, default 100, so an agent's 2-minute command
# limit is never hit) until the VM's ssh answers. Call it again if it times out.
# A foreign-arch guest booted under QEMU TCG emulation answers ssh only after several
# minutes, so raise it for those: SUPERMOX_WAIT_SECS=600 vm-wait-ssh.sh
# Usage: [SUPERMOX_VM_SSH_PORT=2224] vm-wait-ssh.sh
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
WAIT_SECS="${SUPERMOX_WAIT_SECS:-100}"
if ! [[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || [ "$WAIT_SECS" -lt 5 ]; then
  printf 'ERROR: SUPERMOX_WAIT_SECS must be an integer >= 5: %s\n' "$WAIT_SECS" >&2
  exit 2
fi
for i in $(seq 1 $((WAIT_SECS / 5))); do
  if timeout 5 bash "$repo_root/scripts/vm-ssh.sh" true >/dev/null 2>&1; then
    printf 'ssh OK after about %s s\n' "$((i * 5))"
    exit 0
  fi
  sleep 5
done
printf 'ssh not answering after %s s (run again, or check scripts/vm-status.sh)\n' "$WAIT_SECS"
exit 1
