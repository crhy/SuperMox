# SuperMox architecture

How the pieces fit together today (2026-10-31). The vision and roadmap are in the
[whitepaper](../supermox_white_paper_1.pdf) and [PLAN.md](PLAN.md); this page describes what
exists in the repository.

## The base: Proxmox VE on Devuan, without systemd

SuperMox forks [PXVIRT](https://github.com/jiangcuo/pxvirt) (an arm64-capable fork of
Proxmox VE, AGPLv3) and rebuilds it on **Devuan Ceres with sysvinit**. Zero systemd is a hard
requirement: no systemd packages, units, `systemctl` calls, `sd_notify` or libsystemd in
anything SuperMox ships.

- **Upstream sources** are fetched by `scripts/fetch-upstream.sh` into `upstream/pxvirt`
  (git-ignored, pinned commit). Components whose PXVIRT version is replaced by a newer
  upstream commit are listed in `config/upstream-overrides.txt`, kept honest by
  `scripts/check-overrides.sh`.
- **Our changes to upstream** live as patch files under `patches/` (applied by
  `scripts/apply-patches.sh`, recorded with `scripts/patch-save.sh`) or as new files. Nothing
  under `upstream/` is edited directly.
- **Init scripts** for every PVE daemon live in `init.d/` (pve-cluster, pvedaemon, pveproxy,
  pvestatd, pve-firewall, pve-ha-crm/lrm, pvescheduler, qmeventd, spiceproxy, networking...)
  plus SuperMox's own (`supermox-joind`, `supermox-sync`, `supermox-tmpfiles`,
  `supermox-binfmt`). See [init-scripts.md](init-scripts.md). Daemons that only write to stderr
  are wrapped by `scripts/supermox-logpipe` so their output reaches syslog (rsyslog) under
  sysvinit (t57).
- **No-systemd proof**: `scripts/check-no-systemd.sh` checks the source tree and a running
  system; [systemd-inventory.md](systemd-inventory.md) lists every systemd dependency that was
  replaced and how.
- **Packages**: `supermox-ve` (meta-package), `supermox-tmpfiles`, `supermox-joind`, the
  rebuilt PVE packages, and `supermox-manager` (the desktop client).

Verified on 2026-10-29: Proxmox VE 9.2 (pve-manager 9.2.24, qemu-server 9.2.13,
pve-container 6.1.15) built from source, running under sysvinit with no systemd, web UI on
port 8006, surviving reboot.

## Joining devices into one cluster

Design: [node-join-architecture.md](node-join-architecture.md). Code: `src/supermox/`,
commands in `bin/`.

| Piece | Module | What it does |
| --- | --- | --- |
| Cluster secret | `secret.py` | A 12-word BIP39 phrase (128 random bits); every cluster key is derived from it with HKDF-SHA256. Never logged or written in clear. |
| Node identity | `identity.py` | Each node's own WireGuard X25519 and Ed25519 signing keypairs, generated at install, never derived from the phrase. |
| Node state | `state.py` | The small set of JSON files under `/etc/supermox` (cluster keys mode 0600, identity, signed membership). |
| Invites | `invite.py` | QR invite URIs that prove possession of the cluster secret with an HMAC token; the QR never carries the phrase or any key. |
| Join protocol | `joinproto.py` | JOIN_REQ / JOIN_ACK, invite challenge/answer, signed membership lists. Pure functions, versioned JSON. |
| Join daemon | `joind.py`, `bin/supermox-joind` | The TCP endpoint nodes join through: phrase joins, invite joins with an approval queue, writes the WireGuard configuration. |
| CLI | `bin/supermox-join` | Create a cluster, invite a node, join, approve or deny. |
| Discovery layer 1 | `gossip.py` | Signed endpoint records (`node, endpoints, seq, time, sig`) exchanged with every reachable peer; reaching one member is enough to learn where all are (t62). |
| Discovery layer 3 | `locator.py` | Publishes each node's signed endpoint record to the BitTorrent mainline DHT under a key derived from the cluster secret, the node id and the UTC day, so members can find each other across NAT changes (t63). |

The WireGuard overlay between two real nodes was verified end to end in network namespaces
inside the test VM (`scripts/join-e2e.sh`, milestone M3, t49d).

## One home folder on every device

Design: [shared-home.md](shared-home.md). `src/supermox/sync.py` and `bin/supermox-sync`
turn the signed membership list into the configuration of one Syncthing instance per user
(`init.d/supermox-sync`): one device per member over the WireGuard overlay, the home
folders, discovery, relays and NAT traversal off. `supermox-sync status` reports per-folder
state and conflicts.

## Any hardware, every architecture

[any-hardware.md](any-hardware.md): `scripts/supermox-node-caps.sh` reports each node's
capability tier (KVM, LXC-only or TCG emulation) so the cluster places work where it can
run. `scripts/arch.sh` maps `SUPERMOX_ARCH` (Debian architecture names) to kernel, QEMU and
console settings for the build and test VMs; amd64 is verified, arm64 and others are in
progress.

## Android: phones as nodes

[android-port.md](android-port.md): phones run SuperMox with the Android experience on top
through **Waydroid**, full screen, with the Lawnchair launcher
(`scripts/supermox-android-setup.sh`). Phones are LXC/TCG-tier nodes. A Waydroid test VM and
its debugging notes came from tasks t56 and t60. The first target phone is a Samsung Galaxy
S9 (Exynos, LineageOS "starlte").

## The PC edition

[pc-edition.md](pc-edition.md): an installable ISO built by `scripts/build-iso.sh` from a
Spaced Linux checkout: the Spaced desktop (MATE, Windows XP-style panel, Flatpak, Calamares
installer) plus the SuperMox node packages and branding
([ui-and-branding.md](ui-and-branding.md)).

## SuperMox Manager

[supermox-manager.md](supermox-manager.md): a standalone GTK 3 desktop client for the
SuperMox/PXVIRT API with native pages for the dashboard, guests, creation, storage, node
administration, network, disks, permissions, backups, pools, HA and firewall, a certificate
pin checked before any credentials are sent, and an optional embedded "Full management"
browser for the workflows not yet rebuilt.
