# SuperMox Plan

## M1 — Devuan Ceres amd64 VM under sysvinit
Bring up a Devuan Ceres amd64 KVM VM and get the core PVE services (pve-cluster, pve-common,
pve-manager, pve-http-server and friends) running under sysvinit with ZERO systemd. This means
replacing every upstream systemd unit, `systemctl` call, `sd_notify` and libsystemd dependency with
`init.d/` service scripts and plain sysv tooling. This milestone is the foundation everything else
builds on.

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

## M2 — arm64 QEMU VM
Reproduce the M1 result on an arm64 QEMU VM. PXVIRT is already arm64-capable, so the work is
verifying the toolchain, packages and services build and run correctly on arm64, and fixing any
architecture assumptions that amd64-only testing hid.

## M3 — Galaxy S9 (Exynos) boot
Boot a Samsung Galaxy S9 (Exynos, LineageOS device "starlte") using the LineageOS starlte kernel
and device tree, running LXC containers for the PVE services. KVM availability on the Exynos 9810
platform is unverified, so full virtualization on the phone is not assumed; the phone is treated
first as an LXC host.

## M4 — Waydroid frontend
Run Waydroid (Android in an LXC container, on top of LineageOS) as the user-facing frontend, so
the phone's interface and the SuperMox services share one platform.

## Follow-ups
- **Rust log routing (proxmox-perl-rs).** `patches/proxmox-perl-rs/0001-no-journald.patch` drops
  the `.journald()` sink from `common/src/logger.rs` (the single real file behind the `pmg-rs`/`pve-rs`
  `common` symlinks), so `pve-rs`/`pmg-rs` log output goes to stderr only. Follow-up: ensure the
  `init.d/` service scripts redirect daemon stderr into syslog (e.g. via `start-stop-daemon --stderr`
  or a `logger` wrapper) so Rust-side logs remain visible in the system log without journald.
- **Upstream overrides.** `config/upstream-overrides.txt` pins components to upstream commits other
  than what PXVIRT's submodule records (currently `proxmox-perl-rs` at pve-rs 0.15.3). Follow-up:
  re-validate each override against PXVIRT's expected API on every upstream bump, and drop overrides
  once PXVIRT's submodule advances past them.
