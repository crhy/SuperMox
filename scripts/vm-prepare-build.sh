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

# ifupdown2 (pulled in by some build deps) ships no init script; the leftover classic-ifupdown
# /etc/init.d/networking then breaks networking on the next boot and ssh stops answering. Install
# ours so the build VM stays reachable after builds. dpkg drops the rcS.d link when it
# removes classic ifupdown, so recreate that too.
remote 'cat > /etc/init.d/networking' < "$repo_root/init.d/networking"
remote 'chmod 755 /etc/init.d/networking'
remote 'ln -sf ../init.d/networking /etc/rcS.d/S10networking'

remote 'set -e
export DEBIAN_FRONTEND=noninteractive
# Build VM only: install scripts must not start services (PVE services fail without a running cluster).
printf "#!/bin/sh\nexit 101\n" > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
mkdir -p /root/build /root/localrepo
chmod o+x /root
chmod 755 /root/localrepo
printf "deb [trusted=yes] file:/root/localrepo ./\n" > /etc/apt/sources.list.d/supermox-local.list
cd /root/localrepo && dpkg-scanpackages . > Packages 2>/dev/null || true
chmod 644 /root/localrepo/Packages 2>/dev/null || true
apt-get update
apt-get -y --no-install-recommends install build-essential libcrypt-dev devscripts equivs debhelper dpkg-dev git rsync lintian
apt-get update'

printf 'VM build environment ready (/root/build, /root/localrepo).\n'
