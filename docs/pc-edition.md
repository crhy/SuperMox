# SuperMox PC Edition (10.26)

The PC edition is a full SuperMox node with a desktop.

## What it is

SuperMox PC edition = Spaced Linux desktop + SuperMox packages + SuperMox branding.

- **Spaced Linux** (source: github.com/crhy/spaced) provides the desktop: MATE window
  manager, Windows-XP style task panel, Flatpak app ecosystem, Calamares installer.
- **SuperMox packages** provide the node services: `supermox-ve` (meta-package pulling in
  the rebuilt PVE stack), `supermox-tmpfiles`, `supermox-joind` (join daemon).
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
2. Adds the SuperMox packages (supermox-ve, supermox-tmpfiles, supermox-joind,
   our rebuilt PVE stack) into the image's package pool.
3. Applies SuperMox branding (replaces Proxmox names, logos, and trademarks).
4. Produces a bootable ISO with the Calamares installer.

The build VM (from M1) is used to compile the packages; the ISO assembly runs on the
host with the Spaced tree.
