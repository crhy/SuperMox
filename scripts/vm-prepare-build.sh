#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vm_ssh="$repo_root/scripts/vm-ssh.sh"

remote() {
  bash "$vm_ssh" "$@"
}

waited=0
until remote true 2>/dev/null; do
  if [ "$waited" -ge 180 ]; then
    printf 'FAIL: ssh not reachable within 180s\n' >&2
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done

remote 'set -e
export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/build /root/localrepo
chmod o+x /root
chmod 755 /root/localrepo
printf "deb [trusted=yes] file:/root/localrepo ./\n" > /etc/apt/sources.list.d/supermox-local.list
cd /root/localrepo && dpkg-scanpackages . > Packages 2>/dev/null || true
chmod 644 /root/localrepo/Packages 2>/dev/null || true
apt-get update
apt-get -y --no-install-recommends install build-essential devscripts equivs debhelper dpkg-dev git rsync lintian
apt-get update'

printf 'VM build environment ready (/root/build, /root/localrepo).\n'
