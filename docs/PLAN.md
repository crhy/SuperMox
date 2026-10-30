# SuperMox Plan

## M1 — PVE on Devuan sysvinit (DONE)

Bring up a Devuan Ceres amd64 KVM VM and get the core PVE services (pve-cluster,
pve-common, pve-manager, pve-http-server and friends) running under sysvinit with
ZERO systemd. This means replacing every upstream systemd unit, `systemctl` call,
`sd_notify` and libsystemd dependency with `init.d/` service scripts and plain sysv
tooling. This milestone is the foundation everything else builds on. SuperMox targets
all architectures (arm64, armhf, amd64, riscv64, loong64, ...); amd64 is only the first
test target. The single architecture setting is `SUPERMOX_ARCH`, mapped in
`scripts/arch.sh`.

Verified on 2026-10-29: Proxmox VE 9.2 (pve-manager 9.2.24, qemu-server 9.2.13,
pve-container 6.1.15) built from source on Devuan Ceres, running under sysvinit with
no systemd anywhere (checked by `scripts/check-no-systemd.sh` on the running system),
web UI on port 8006, survives reboot.

### Milestone 1 VM
Operate the amd64 KVM VM built by the scripts in `scripts/`. All paths default to
`$SUPERMOX_VM_DIR` (`/media/rhy/data/supermox-vm`), overridable by env.

- Build the rootfs and image: `bash scripts/build-rootfs.sh`
- Start headless in the background: `bash scripts/vm-start.sh --background`
- Check it (waits for ssh, proves PID 1 is sysvinit-core, runs `check-no-systemd.sh --image /`
  in the guest, confirms `/dev/kvm`): `bash scripts/vm-smoke.sh`
- Stop it by pidfile only: `bash scripts/vm-stop.sh`
- Configure Proxmox apt repos (keyring, sources, origin pins, verify installability): `bash scripts/vm-setup-proxmox-repos.sh`
  - Rust crate pins: Proxmox's `librust-proxmox-*` devel crates target Debian trixie crate versions, but Ceres
    crates are too new (e.g. `proxmox-log` needs `nix` 0.29 while Ceres has 0.30, and `tracing-journald` >=0.3.1
    while Ceres has 0.3.0). The script adds Devuan `excalibur` (trixie-era) as a low-priority source and pins
    `librust-*`/`rustc`/`cargo`/`libstd-rust-*`/`dh-cargo` to it (990) with Proxmox's own `librust-*` higher (995);
    crates are build-time source only, nothing from them ships.
- Build a Debian source package in the VM: `bash scripts/vm-build-pkg.sh <name>`. Two kinds: an upstream
  component (patched via `apply-patches.sh`, built from `upstream/pxvirt/packages/<name>/<name>/`) or one of our
  own packages under `packaging/<name>/` (built directly, no patching, into `/root/build/pkg-<name>/<name>/`); a
  name that is both is an error. Debs land in `/root/localrepo` and are copied back to `$SUPERMOX_VM_DIR/debs/`.

## M2 — PC edition 10.26

SuperMox PC edition: Spaced Linux desktop (MATE, Windows-XP style panel, Flatpak apps,
Calamares installer) plus the SuperMox packages (supermox-ve and our rebuilt PVE stack,
supermox-tmpfiles, supermox-joind) plus SuperMox branding. Built by `scripts/build-iso.sh`
from a Spaced checkout (github.com/crhy/spaced). The PC is a full SuperMox node: KVM tier
when VT-x/AMD-V is present. See docs/pc-edition.md.

## M3 — Node join over WireGuard

Any SuperMox node can join a cluster and talk to other nodes over an encrypted,
authenticated WireGuard link. Join by typing a 12-word BIP39 phrase or scanning a QR
invite. Crypto (BIP39, HKDF, libsodium secretbox, WireGuard PSK) and the join daemon
(`supermox-joind`) are built and unit-tested. Real-link test between two VMs in progress.
See docs/node-join-architecture.md.

## M4 — arm64 and other architectures

Reproduce the M1 result on arm64 (and eventually armhf, riscv64, loong64). PXVIRT is
already arm64-capable, so the work is verifying the toolchain, packages and services
build and run correctly on each arch, and fixing any architecture assumptions that
amd64-only testing hid.

## M5 — Android port

Waydroid (Android in an LXC container) on top of LineageOS as the user-facing frontend
on phones. Lawnchair launcher. The phone is a SuperMox node at LXC or TCG tier (no KVM
on Exynos). See docs/android-port.md.

## M6 — Discovery

Cluster discovery without a central authority: gossip protocol, Tor onion routing,
DHT-style bootstrap. Nodes find each other and form overlays without a DNS or
corporate infrastructure.

## Follow-ups
- **Rust log routing (proxmox-perl-rs).** `patches/proxmox-perl-rs/0001-no-journald.patch` drops
  the `.journald()` sink from `common/src/logger.rs` (the single real file behind the `pmg-rs`/`pve-rs`
  `common` symlinks), so `pve-rs`/`pmg-rs` log output goes to stderr only. Follow-up: ensure the
  `init.d/` service scripts redirect daemon stderr into syslog (e.g. via `start-stop-daemon --stderr`
  or a `logger` wrapper) so Rust-side logs remain visible in the system log without journald.
- **Upstream overrides.** `config/upstream-overrides.txt` pins components to upstream commits other
  than what PXVIRT's submodule records (currently `proxmox-perl-rs` at pve-rs 0.15.3). Follow-up: re-validate
  each override against PXVIRT's expected API on every upstream bump, and drop overrides once PXVIRT's
  submodule advances past them.
