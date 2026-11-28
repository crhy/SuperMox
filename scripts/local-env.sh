#!/usr/bin/env bash
# Sourced by every script that needs a path or a VM setting; never run directly.
#
# Nothing in this repo points at one machine's disks. Values come from three levels,
# highest first:
#   1. an exported environment variable (SUPERMOX_VM_DIR=... bash scripts/vm-start.sh)
#   2. config/local.env (git-ignored; the maintainer keeps his VM data on his data disk)
#   3. the portable default below, inside this repo's build/ directory
#
# config/local.env may set any SUPERMOX_* variable, so it is sourced first and the
# variables that were already in the environment are put back afterwards.

# This file is sourced, so $0 is the caller's path: use BASH_SOURCE for our own.
_smx_local_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$_smx_local_env_dir/.." && pwd)"
SUPERMOX_REPO="$REPO"

# Level 1: remember what the environment already provides.
_smx_from_env=()
while IFS= read -r _smx_name; do
  _smx_from_env+=("$_smx_name=${!_smx_name}")
done < <(compgen -e | grep -E '^SUPERMOX_[A-Za-z_][A-Za-z0-9_]*$')

# Level 2: the machine-local file, if present.
if [ -f "$REPO/config/local.env" ]; then
  # shellcheck disable=SC1090,SC1091
  source "$REPO/config/local.env"
fi

# Level 1 wins again: put the exported values back over anything local.env set.
if [ "${#_smx_from_env[@]}" -gt 0 ]; then
  for _smx_kv in "${_smx_from_env[@]}"; do
    export "${_smx_kv?}"
  done
fi

# Level 3: portable defaults, only for variables still unset.
: "${SUPERMOX_VM_DIR:=$REPO/build/vm}"
: "${SUPERMOX_TEST_DIR:=$REPO/build/test-data}"
: "${SUPERMOX_DEBS_DIR:=$SUPERMOX_VM_DIR/debs}"
: "${SUPERMOX_SPACED_REPO:=$(cd "$REPO/.." && pwd)/spaced}"
# The live-build worktree build-iso.sh creates in the Spaced checkout; it holds
# the whole ISO tree, so it is the largest thing under build/ and the first
# candidate for a data disk.
: "${SUPERMOX_SPACED_WORKTREE:=$REPO/build/spaced-iso}"

export SUPERMOX_VM_DIR SUPERMOX_TEST_DIR SUPERMOX_DEBS_DIR SUPERMOX_SPACED_REPO SUPERMOX_SPACED_WORKTREE SUPERMOX_REPO

# Not needed by the caller: keep the helper names out of its namespace.
unset _smx_local_env_dir _smx_from_env _smx_kv _smx_name
