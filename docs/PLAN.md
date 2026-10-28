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
