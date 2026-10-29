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
# sysv-rc boots runlevel S make-style: startpar only runs scripts listed in
# /etc/init.d/.depend.boot, so a hand-made rcS.d symlink is not enough. update-rc.d creates
# the link and regenerates the dependency files from the init script's LSB header.
remote 'update-rc.d networking defaults'
remote 'grep -q networking /etc/init.d/.depend.boot'
# ifupdown2's "inet dhcp" method needs dhclient, which Devuan does not ship, so the
# interfaces file must not carry an "inet dhcp" stanza; dhcpcd is run by our init script
# instead. Ship the loopback stanza so ifup -a has something to configure.
remote 'cat > /etc/network/interfaces' < "$repo_root/config/network/interfaces"
# virtio_net is not in the kernel initramfs and nothing autoloads it under sysvinit, so without
# this kmod (rcS.d/S06kmod) never creates eth0 and the VM boots without a network.
remote 'mkdir -p /etc/modules-load.d'
remote 'cat > /etc/modules-load.d/supermox.conf' < "$repo_root/config/modules-load.d/supermox.conf"

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
