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
- Waydroid test VM and debugging notes for the Android layer.
- `init.d/waydroid-container` owns both halves of the Android layer under
  one `update-rc.d` entry: the container (`waydroid container start`,
  pid `/run/waydroid-container.pid`) and the session (`waydroid session
  start`, pid `/run/waydroid-session.pid`, the half that bind-mounts the
  Wayland socket and serves `waydroid app install`). `start` proves the
  container RUNNING and never starts a session; `session-start` refuses
  unless the container is RUNNING and a Wayland socket exists, naming the
  missing half; `stop` tears the session down first; `status` reports
  both halves. `tests/test-waydroid-session.sh` covers start, stop,
  reboot and the refusals offline (#7).
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

- Android session layer: the handover is implemented and tested offline,
  but `Session: RUNNING` on a real amd64 VM with seatd and weston, the
  Lawnchair install and a compositor screenshot are still unverified (#7).
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
