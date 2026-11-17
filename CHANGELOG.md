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
- pve-container's host-managed container DHCP ported to a maintained client (#9):
  `manage_dhclient` keeps `/sbin/dhclient` as the fallback and otherwise runs the
  container image's busybox `udhcpc6`/`udhcpc` one-shot through the new
  `/usr/share/lxc/hooks/pve-dhcp-client` adapter, which translates the client's
  environment into the `dhclient-script` contract (`reason`, `new_ip_address`,
  routers, DNS) and writes under `ROOTFS`; `patches/pve-container/0003-maintained-dhcp-client.patch`
  and the adapter's contract are checked offline by `tests/test-dhcp-client-port.sh`.
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
- Container DHCP (#9): the live test that creates an OCI application container with
  a host-managed network in the test VM is still open, and the interim
  `isc-dhcp-client` fork has not been dropped.
- Ceph storage built but untested.
- Manager node shell window (copy/paste) and guest consoles are not finished yet
  (parked tasks t70b and t71).
- The newest Manager pages are written by a local model and still await human review.
- `scripts/vm-start.sh` defaults `SUPERMOX_VM_DIR` to the maintainer's data disk; set it
  on other machines.
