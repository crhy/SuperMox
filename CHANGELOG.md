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

- Discovery layer 1: signed gossip of endpoint records (`src/supermox/gossip.py`).
- Discovery layer 3: mainline-DHT locator under a daily key derived from the cluster
  secret (`src/supermox/locator.py`).
- Daemon stderr reaches syslog under sysvinit (`scripts/supermox-logpipe`).
- `scripts/check-overrides.sh`: offline check of `config/upstream-overrides.txt`.
- `patches/qemu-server/0004-bound-cpu-flag-probe.patch` bounds the QEMU CPU-flag
  probe (SuperMox#12): the `query-cpu-model-expansion` QMP call gets a 30 s
  `timeout` and `noerr`, and the probe VM is killed by pidfile (SIGTERM, then
  SIGKILL) and force-stopped on every exit path, so pvestatd always returns to
  its status cycle instead of stalling in `do_select` and filing no RRD history.
  Verified offline by `tests/test-qmp-probe-bound.sh`; the first-boot-after-a-fresh-
  install, bare-metal and ISO runs stay open on the issue.
- Waydroid test VM and debugging notes for the Android layer.
- SuperMox Manager: page registry (one module per page), every module shipped and
  smoke-tested by the gate, live test harness (`tests/manager-live.sh`), and native pages
  for VM creation, container creation from templates, storage content, node
  administration, network interfaces, disks with SMART health, users/groups/roles/ACLs/
  API tokens, scheduled backup jobs, resource pools, HA resources and rules, and firewall
  rules/options/aliases/IP sets. RFC 6455 websocket client and termproxy session for the
  node shell.
- Documentation: `docs/README.md` index, `docs/architecture.md`, `docs/development.md`;
  Manager coverage updated.

### Known limitations

- Web UI still shows Proxmox branding (not yet rebranded in the running UI).
- ZFS is opt-in (requires `zfs-dkms` built against the installed kernel).
- WireGuard join verified end to end between network namespaces in the test VM
  (`scripts/join-e2e.sh`, M3); not yet between two physical machines.
- amd64 only so far; arm64 and other architectures planned but untested.
- Ceph storage built but untested.
- Manager node shell window (copy/paste) and guest consoles are not finished yet
  (parked tasks t70b and t71).
- The newest Manager pages are written by a local model and still await human review.
- `scripts/vm-start.sh` defaults `SUPERMOX_VM_DIR` to the maintainer's data disk; set it
  on other machines.
