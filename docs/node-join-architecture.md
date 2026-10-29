# Node join: 12-word cluster secret and QR invites

Status: design (2026-10-28). Implementation is split into tasks; see "Build order".

## Goals

- Any SuperMox node, on any network, can join a cluster and talk to the other nodes over an encrypted, authenticated
  link.
- People join a device either by typing a 12-word phrase or by scanning a QR code on a device that is already a member.
- One compromised node must not reveal the phrase, and a leaked phrase must be recoverable by re-keying.
- Built only from audited, packaged parts: BIP39 (python3-mnemonic), libsodium (python3-nacl), HKDF
  (python3-cryptography), WireGuard (kernel module, or wireguard-go where the kernel lacks it), qrencode/python3-qrcode.
  No home-made cryptography.

## The cluster secret (12 words)

- The first node creates the cluster. It generates 128 random bits with `os.urandom` and encodes them as a 12-word
  BIP39 English mnemonic (4-bit checksum). The phrase is shown once. People never choose their own words, because only
  a generated phrase carries a full 128 bits.
- Every input is checked: there must be 12 words from the BIP39 list with a valid checksum. A typo is caught before
  anything goes on the network.
- Key derivation: `E` = the 16 entropy bytes. Every key comes from HKDF-SHA256 with `salt = "supermox-cluster-v1"` and a
  fixed `info` label. The labels are part of the protocol and never change; a new scheme gets a new salt version.
  - `cluster_id` = HKDF(E, "cluster-id", 16 bytes). Public; it names the cluster and does not reveal `E`.
  - `join_key` = HKDF(E, "join-key", 32). XSalsa20-Poly1305 secretbox key for messages from phrase-holders.
  - `invite_key` = HKDF(E, "invite-key", 32). HMAC-SHA256 key for QR invite tokens.
  - `wg_psk` = HKDF(E, "wireguard-psk", 32). WireGuard PresharedKey on every peer link: an extra symmetric layer on top
    of the X25519 handshake.
  - `overlay_prefix` = `fd` + the first 5 bytes of HKDF(E, "overlay-prefix", 5). A ULA IPv6 /48 for the overlay, so
    clusters do not collide.
- There is no password stretching: `E` is 128 uniformly random bits, so brute force is already out of reach. Stretching
  only matters for secrets people pick themselves, and those are rejected.
- Nodes store the derived keys (`/etc/supermox/cluster.keys`, root 0600), never the phrase. Anyone holding the phrase
  can rebuild everything; a node's disk alone gives the derived keys but not the phrase.

## Node identity

- Each node generates its own WireGuard X25519 key pair and an Ed25519 signing key pair at install. These are never
  derived from the phrase, so one node's keys say nothing about any other node's.
- A node's overlay address is `overlay_prefix::/48` plus 8 bytes of HKDF(E, "node-addr" + wg_pub).
- Membership is a list of `{name, wg_pub, ed_pub, overlay_addr, endpoints, arch, caps, role}`. Every change to it is
  signed with the Ed25519 key of the member that makes it, and members accept changes only from keys already on the
  list.

## Joining with the 12 words

1. On the new node N, the person enters the 12 words and the address of any member M (or scans a QR, below).
2. N sends `JOIN_REQ = secretbox(join_key, {v:1, cluster_id, name, wg_pub, ed_pub, arch, caps, time, nonce})`
   to M's join daemon (TCP 8743 on the LAN or public address; later also an onion address).
3. M decrypts it, which proves N holds the phrase. M rejects clock skew over 5 minutes and any nonce seen in the last 10
   minutes. It then adds N to the membership list, signs the change, and sends the change to the other members.
4. M replies `JOIN_ACK = secretbox(join_key, {membership list, N's overlay address, M's signature over the list})`.
5. N writes its WireGuard configuration (peers, `wg_psk`, AllowedIPs = each peer's overlay /128) and brings `wg0` up,
   using the `networking` init script, not wg-quick under systemd. After that, all cluster traffic uses overlay
   addresses only.

## Joining with a QR invite

- A member M creates an invite, valid for 15 minutes and usable once: `invite_id` (16 random bytes), `expiry`, and
  `token = HMAC-SHA256(invite_key, cluster_id || invite_id || expiry)[:16]`.
- QR payload: `supermox://join?v=1&c=<cluster_id>&i=<invite_id>&x=<expiry>&t=<token>&f=<M ed_pub fingerprint>&e=<endpoint>[&e=...]`
  (base32, no padding). **The QR never contains the 12 words.** Separately, "Export recovery QR" encodes the phrase
  itself. It is shown only when someone asks for it, with a warning that it is the whole cluster key.
- N scans the QR and connects to an endpoint. M first proves it holds the key matching `f` by signing N's random
  challenge with Ed25519, so a fake endpoint cannot intercept the join. N then sends
  `box(N_ephemeral → M_curve25519, {invite_id, expiry, token, name, wg_pub, ed_pub, arch, caps})`.
- M checks the token, the expiry and that the invite is unused. By default it **asks the person at M to approve**
  ("Pixel-6 (arm64, LXC+KVM) wants to join: allow?"). It then replies with the membership list plus `join_key`,
  `invite_key`, `wg_psk` and `overlay_prefix`. It does not send the phrase. From here, joining continues as in step 5
  above.

## Removing nodes and rotating the secret

- Removing a node is a signed membership change. Every member drops that peer from WireGuard, and its Ed25519 key is
  no longer accepted.
- If the phrase leaks, any member generates a new phrase. The new derived keys travel to the current members over the
  existing authenticated overlay; each member switches, `wg_psk` is changed on every link, and the old phrase stops
  working. A node that was offline during the rotation has to rejoin.

## Reaching nodes anywhere

- v1: nodes reachable directly (same LAN, or a public IP and port).
- v2: nodes behind NAT or carrier-grade NAT, such as phones, connect out to any member with a public endpoint, which
  relays overlay traffic through WireGuard routing.
- v3: Tor onion endpoints for the join daemon and the WireGuard relay (from the whitepaper). These are slower, but they
  work behind any NAT and hide where a node is.
- Kernels without WireGuard use `wireguard-go` in userspace, so this works on any hardware.

## Core and edge nodes (a Proxmox constraint)

Proxmox clustering (corosync and pmxcfs) needs a low, stable round-trip time, roughly under 5 ms, between voting nodes.
Phones and machines reached over the internet cannot meet that. So:

- **Core nodes** have an overlay RTT under 5 ms, measured during the join (usually the same LAN). They become corosync
  members and share `/etc/pve`.
- **Edge nodes** are everything else. They join the overlay and the signed membership list, run their own guests, and
  are managed through the PVE API over the overlay. They do not vote in corosync and do not mount the cluster
  filesystem.
- A node's role is chosen when it joins, from the RTT and its capabilities (`supermox-node-caps`), and it can change
  later.

## Build order

1. `supermox/secret.py`: create and check the mnemonic, plus the HKDF derivations, with known-answer tests (BIP39
   vectors; our labels' outputs pinned).
2. `supermox/invite.py`: build and parse the invite URI, the HMAC token, expiry and single use, and render the QR as
   PNG and terminal text.
3. `supermox/joinproto.py`: build, encrypt and check JOIN_REQ, JOIN_ACK and the invite messages, the replay window, and
   signed membership changes. Pure functions with no network.
4. `supermox-joind` (daemon plus a sysvinit script), the `supermox-join` command, the WireGuard configuration writer,
   and an approval queue.
5. A two-namespace integration test: two network namespaces joined by a veth pair, run through the whole join.
6. Relaying for NAT (v2), Tor (v3), measuring RTT and choosing core or edge.
