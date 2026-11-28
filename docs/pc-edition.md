# SuperMox PC Edition (11.26)

The PC edition is a full SuperMox node with a desktop.

## What it is

SuperMox PC edition = Spaced Linux desktop + SuperMox packages + SuperMox branding.

- **Spaced Linux** (source: github.com/crhy/spaced) provides the desktop: MATE window
  manager, Windows-XP style task panel, Flatpak app ecosystem, Calamares installer.
- **SuperMox packages** provide the node services: `supermox-ve` (meta-package pulling in
  the rebuilt PVE stack, the join daemon `/usr/sbin/supermox-joind` and the join
  command), `supermox-tmpfiles`, and `supermox-manager` (the desktop client). There is
  no `supermox-joind` package: the join daemon is a program inside `supermox-ve`.
- **SuperMox branding** replaces all upstream Proxmox names and logos.

## The PC is a SuperMox node

A PC running the SuperMox ISO is a full cluster node. It runs the PVE services under
sysvinit (pve-cluster, pve-manager, pve-http-server, qemu-server, pve-storage, etc.)
and can host VMs and containers for the cluster.

### Capability tier

When the CPU supports virtualisation (VT-x on Intel, AMD-V on AMD), `/dev/kvm` is
available and the node is KVM tier: full-speed QEMU VMs with hardware acceleration,
nested virt, host-passthrough CPU, GPU/PCI passthrough.

Without VT-x/AMD-V the node drops to LXC tier (containers only) or TCG tier (software
emulation). See docs/any-hardware.md for the tier rules.

## The desktop is the Spaced desktop

The user sees the Spaced Linux desktop: MATE panel with Windows-XP style buttons,
Flatpak apps, and the SuperMox app for cluster management. The desktop is not a
Proxmox product; it is Spaced Linux with SuperMox services underneath.

## How it is built

`scripts/build-iso.sh` builds the ISO from a Spaced checkout. It:

1. Takes the Spaced base image and installer (Calamares).
2. Adds the packages we build (supermox-ve, supermox-tmpfiles, supermox-manager and
   our rebuilt PVE stack) into the image's package pool, minus the deny list in
   `config/iso-exclude-debs.txt`.
3. Applies SuperMox branding (replaces Proxmox names, logos, and trademarks).
4. Produces a bootable ISO with the Calamares installer.

The build VM (from M1) is used to compile the packages; the ISO assembly runs on the
host with the Spaced tree. As of 2026-11-05 the ISO has not been built or boot-tested
yet (issue #8); `bash scripts/build-iso.sh --dry-run` exercises the tooling without root.

## Forked upstream packages

Two upstream Debian packages do not work on a zero-systemd Devuan Ceres node, so we
build our own from pinned Debian source (`scripts/fetch-upstream.sh`, patches under
`patches/`). Both carry a `+supermoxN` version suffix and install no systemd units.

| Package | Source | Why we fork it |
|---|---|---|
| `rrdcached` (and its libraries) | Debian source `rrdtool 1.9.0-2.1` | Ceres's build ships only systemd units (`rrdcached.service`, `rrdcached.socket`) and gets its unix socket from socket activation; there is no init script, so under sysvinit nothing would start. Our fork installs `/etc/init.d/rrdcached` and starts the daemon with `-l` so it creates the socket itself. |
| `isc-dhcp-client` (plus `isc-dhcp-common`) | Debian source `isc-dhcp 4.4.3-P1-8` | Devuan Ceres dropped the package: `apt-cache policy isc-dhcp-client` has no candidate, and `pve-container` depends on `/sbin/dhclient` for host-managed container networks, so nothing depending on pve-container could be installed. We build the client side only; the DHCP server, relay and LDAP binaries our fork also produces are kept off the ISO by `config/iso-exclude-debs.txt`. Upstream ISC DHCP is end of life (issue #9). |
