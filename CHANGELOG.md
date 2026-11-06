# Changelog

## 11.26 (unreleased)

### Added

- Proxmox VE 9.2 (pve-manager 9.2.24, qemu-server 9.2.13, pve-container 6.1.15) built
  from source on Devuan Ceres, running under sysvinit with zero systemd.
- Web UI on port 8006, survives reboot.
- Node join with a 12-word BIP39 phrase or QR invite (`supermox-join`,
  `supermox-joind`), built and unit-tested.
- PC edition: Spaced Linux desktop (MATE, Windows-XP panel, Flatpak, Calamares)
  with the SuperMox packages and branding. Built by `scripts/build-iso.sh`.
- `supermox-ve` meta-package (it carries the `supermox-joind` join daemon) and `supermox-tmpfiles`.
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

### Changed

- `rrdcached` and `isc-dhcp-client` are SuperMox's own packages, built from pinned Debian
  source: Devuan's `rrdcached` ships only systemd units, and Devuan dropped `isc-dhcp-client`,
  which `pve-container` needs.
- Every upstream component we rebuild carries a `+supermox1` version, and `supermox-ve`
  ships apt pins (`/etc/apt/preferences.d/supermox-origins`, `supermox-no-systemd`) so
  neither Proxmox's nor Devuan's builds can replace ours and systemd can never be pulled in.
- `pve-firewall` uses the nft backend for iptables/ebtables; Devuan kernels have no legacy
  ebtables module.

### Fixed

- A fresh install maps the hostname to the node's own IP at every boot (`supermox-hosts`),
  so pve-cluster starts on first boot and after a DHCP address change.
- A joined node brings its WireGuard overlay up by itself at boot and when membership
  changes (`supermox-wg`); the config lives where WireGuard's AppArmor profile allows.
- A new cluster's founding node writes its overlay config too.
- Home sync works: the init script started Syncthing with flags it does not have, and
  `supermox-sync` spoke an API Syncthing does not serve.
- A crashed web UI or API daemon recovers on `start`: its orphaned workers no longer hold
  the port, and `start` no longer reports success when the daemon did not come up.
- `rrdcached` now runs under sysvinit, so the graphs have history.
- Service restarts from the web UI and the Manager work (they passed the wrong argument).
- The web UI shows the SuperMox logo and name instead of Proxmox's trademark.
- `pve-firewall` no longer logs an error every 10 seconds.
- The join daemon: limits on frame size, idle time and connections; failed attempts are
  throttled per source address; replayed requests are refused across restarts; the
  lockout warning is logged correctly; on a node that is not in a cluster it says so
  instead of reporting a start that then dies.
- The Waydroid container service reports failure when the container is not running.
- The SuperMox Manager fits small screens on every page; errors keep their HTTP status;
  a failed certificate check no longer leaks a socket.
- The ISO no longer ships a DHCP server or development packages, uses no systemd
  helpers, and refuses an image that contains systemd.
- Build tooling: patches must apply exactly (no fuzz), superseded packages are pruned,
  VMs can always be stopped and never start twice, and the gate builds and runs every test.

### Known limitations

- The PC-edition ISO has not been built or boot-tested yet (issue #8).
- Installed systems have no update channel yet (issue #10).
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
