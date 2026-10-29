#!/usr/bin/env bash
# Wait (at most 100 s, so an agent's 2-minute command limit is never hit) until the VM's ssh answers.
# Usage: [SUPERMOX_VM_SSH_PORT=2224] vm-wait-ssh.sh ; call it again if it times out.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
for i in $(seq 1 20); do
  if timeout 5 bash "$repo_root/scripts/vm-ssh.sh" true >/dev/null 2>&1; then
    printf 'ssh OK after about %s s\n' "$((i * 5))"
    exit 0
  fi
  sleep 5
done
printf 'ssh not answering after 100 s (run again, or check scripts/vm-status.sh)\n'
exit 1
