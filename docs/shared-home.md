# Shared home folder across all nodes

Status: design (2026-10-29).

## Goal

A person's home folder is the same on every SuperMox device they own: laptop, desktop, phone, server, or a box at a
relative's house. Changes on one device show up on the others. It still works offline (phones, trains), and no company's
cloud is involved.

## Why sync, not a network filesystem

Network filesystems (NFS, CephFS, GlusterFS) need the storage nodes to be reachable and fast all the time. CephFS needs low
latency between its nodes, like corosync (see "Core and edge nodes" in docs/node-join-architecture.md). Phones and nodes
reached over the internet cannot give that. So the home folder is **synchronised**: every device holds a real local copy,
works on it at full speed, and exchanges changes when it can reach the others.

- Tool: **Syncthing** (in Devuan; MPL-2.0; peer to peer, encrypted with TLS, no central server, handles conflicts and
  versions). There is no Syncthing relay or discovery server: devices only talk over the SuperMox WireGuard overlay, using
  overlay addresses from the membership list.
- CephFS stays available for **core** nodes on one LAN as PVE storage for VM and container disks. That is separate from
  the home folder.

## How it is wired

1. Every node runs Syncthing for each SuperMox user, started by `init.d/supermox-sync`, with `--no-browser`; its GUI and
   API listen only on 127.0.0.1.
2. Syncthing's device ID is added to the node's entry in the signed membership list. Members learn each other's IDs from
   the list and configure each other automatically: no clicking "accept device". `supermox-sync reconcile` turns the
   membership list into Syncthing configuration (devices, folder sharing, addresses `tcp://[overlay-addr]:22000`). It
   runs after every membership change.
3. Global discovery, relays and NAT punching are turned off. Only the overlay is used, so nothing leaves the encrypted
   SuperMox network.
4. Folder: `/home/<user>`, with a built-in ignore list (`.cache`, `.local/share/Trash`, `.var/app/*/cache`, build trees,
   `*.iso`, `.thumbnails`), and Syncthing's staggered file versioning so deleted and overwritten files can be recovered.

## Priorities and who keeps what

- **Full copy** (the default for PCs and servers): the whole folder.
- **Selective** (the default for phones and small devices): only the folders the person marks (for example Photos and
  Documents), so a phone's storage is not filled. The rest is reachable through SuperMox Home.
- **Encrypted backup holder**: a device at someone else's place, or rented storage from the whitepaper. It uses
  Syncthing's untrusted (receive-encrypted) mode, so the holder stores the data but cannot read it. This is the
  whitepaper's "backups on other people's hardware".
- **Important**: folders the person marks (for example Photos) must be on at least N devices, by default 3, in at least
  2 places. SuperMox Home warns when that is not met.

## Build order

1. Package Syncthing's sysvinit script (`init.d/supermox-sync`) and `supermox-sync reconcile` (membership list ->
   Syncthing configuration through its REST API on 127.0.0.1), with tests on a fake membership list.
2. A two-namespace test in the test VM, like the join test: an edit on node A shows up on node B over the overlay.
3. Selective folders and encrypted backup holders; the "important" rule and its warning in SuperMox Home.
