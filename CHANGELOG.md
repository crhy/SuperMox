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
- SuperMox Manager: page registry (one module per page), every module shipped and
  smoke-tested by the gate, live test harness (`tests/manager-live.sh`), and native pages
  for VM creation, container creation from templates, storage content, node
  administration, network interfaces, disks with SMART health, users/groups/roles/ACLs/
  API tokens, scheduled backup jobs, resource pools, HA resources and rules, and firewall
  rules/options/aliases/IP sets. RFC 6455 websocket client and termproxy session for the
  node shell.
- Documentation: `docs/README.md` index, `docs/architecture.md`, `docs/development.md`;
  Manager coverage updated.

### Fixed

- Python test harness (`tests/test-python.sh`) runs every `tests/py/test_*.py` module
  in its own process, so a thread, socket or fd left behind by one module can neither
  break a later module nor hide a real failure (SuperMox#11).
- The websocket test server handles each connection in its own thread with its own
  10 s read deadline, and `test_abandoned_connection_does_not_delay_the_next_one`
  pins that an abandoned connection must not delay the next one.
- `WS_DEBUG=1` logs the client socket's fd number, its peer and the elapsed read
  time at connect, at each frame read and at close (stderr only, off by default,
  never a cookie, ticket or request path).
- `api.pinned_socket()` closes the socket it really owns when a pin check fails:
  `wrap_socket()` detaches the plain socket, so the failed handshake used to leave
  an open fd until garbage collection ran, closing an fd number that may by then
  belong to another socket.

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
