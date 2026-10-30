# Changelog

## 10.26 (unreleased)

### Added

- Proxmox VE 9.2 (pve-manager 9.2.24, qemu-server 9.2.13, pve-container 6.1.15) built
  from source on Devuan Ceres, running under sysvinit with zero systemd.
- Web UI on port 8006, survives reboot.
- Node join with a 12-word BIP39 phrase or QR invite (`supermox-join`,
  `supermox-joind`), built and unit-tested.
- PC edition: Spaced Linux desktop (MATE, Windows-XP panel, Flatpak, Calamares)
  with the SuperMox packages and branding. Built by `scripts/build-iso.sh`.
- `supermox-ve` meta-package, `supermox-tmpfiles`, `supermox-joind` packages.
- `scripts/check-no-systemd.sh` verifies no systemd on the running system.
- `scripts/supermox-node-caps.sh` reports node capability tier (KVM/LXC/TCG).

### Known limitations

- Web UI still shows Proxmox branding (not yet rebranded in the running UI).
- ZFS is opt-in (requires `zfs-dkms` built against the installed kernel).
- WireGuard link between nodes not yet tested end to end (crypto and daemon are
  unit-tested; real two-VM link in progress).
- amd64 only so far; arm64 and other architectures planned but untested.
- Ceph storage built but untested.
