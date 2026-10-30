# SuperMox on Android

Status: design (2026-10-30). First building blocks land in `init.d/waydroid-container`,
`packaging/supermox-android/` and `scripts/supermox-android-setup`.

## The shape of the port

A phone is **not** an Android app that talks to a server. The phone runs the **SuperMox host**:
Devuan Ceres under sysvinit with `supermox-ve` installed, so the PVE daemons (`pve-cluster`,
`pvedaemon`, `pveproxy`, `pvescheduler`, `pvestatd`, `supermox-joind`, …) run natively on the
phone's own kernel. Android is the **user interface layer on top of that host**, not the operating
system the cluster runs on.

Per `docs/node-join-architecture.md` ("Core and edge nodes"), a phone joins the cluster as an
**edge node**: it is reached over the internet or over a slow/roaming link, so its overlay RTT is
far above the ~5 ms corosync needs. It therefore

- joins the signed membership list and the WireGuard overlay,
- runs its own guests and its own local `/etc/pve` (not the cluster filesystem),
- is managed through the PVE API over the overlay, and does not vote in corosync.

A phone that sits on the same LAN as the core can measure a low RTT at join time and be recorded
as core; the role is chosen from the measured RTT and `supermox-node-caps`, and can change later.
Roaming phones are expected to be edge nodes.

## Where Android comes in: Waydroid, full screen

The Android UI is **LineageOS running inside a Waydroid LXC container** on the host:

- Waydroid is upstream an LXC container (`/var/lib/waydroid/images` holds the rootfs) plus a
  supervisor process; SuperMox ships `init.d/waydroid-container` as the sysvinit replacement for
  Waydroid's systemd unit, and the container is an ordinary LXC guest, which is exactly the guest
  type a phone can run (see tiers below).
- It is used **full screen**: the container renders to the phone's own display (Waydroid's
  Wayland/OpenGL path), so the user sees Android, not a terminal.
- **Home app: Lawnchair launcher** (<https://github.com/LawnchairLauncher/lawnchair>, Apache-2.0).
  It is the Android "home screen": it owns the app list, the widget/dashboard layer and the
  shortcuts, and it is what makes the desktop usable as a SuperMox console (bookmarks to
  `pveproxy`'s web UI, launchers for `supermox-join`, QR scanning for invites).
- **App store: F-Droid**, so the apps on the phone stay free software and installable without
  Google's tooling; the SuperMox CLI helpers can be shipped as F-Droid apps later.
- `scripts/supermox-android-setup` is the one-shot provisioning step: it loads `binder_linux`
  (Waydroid needs bind mounts inside the container), runs `waydroid init` to fetch the LineageOS
  image, then installs Lawnchair from a release APK that **must** be given with a sha256
  (`--lawnchair-url URL --sha256 SUM`), installs it with `waydroid app install` and sets it as the
  home app.

## Two hardware paths

The phone's kernel decides what is possible. SuperMox supports both paths.

| path | kernel | GPU | who |
|------|--------|-----|-----|
| **A. mainline** | Debian/postmarketOS mainline kernel | Mesa `freedreno`/`panfrost` (open drivers, no vendor blobs) | devices postmarketOS supports; **best first target** |
| **B. vendor** | LineageOS vendor kernel + vendor blobs, host kernel reached through **libhybris** (the Halium approach) | vendor GL/GL ES stack through the hybris shim | everything else, incl. the Samsung S9 (`starlte`) first phone |

Path A is preferred because the whole stack is one kernel: LXC, cgroups, `/dev/dri` GPU
rendering, Wayland and network all come from the same mainline tree, and Waydroid's GPU
passthrough is a mount plus an env var. Path B buys us vendor-only devices (the S9's
kernel is a vendor 4.9/4.14 tree that cannot boot LXC unmodified), at the cost of a
hybris shim that translates a *host* kernel's syscalls into the Android container's view;
GPU, `/dev/binder`/bind mounts and network namespaces all go through that shim and must be
re-verified per device.

## Capability tier: phones are LXC/TCG nodes

`docs/any-hardware.md` defines the tiers. **KVM is usually unavailable on phones**: Qualcomm
keeps the EL2 (LDCR) virtualisation client proprietary, so no mainline ARM virtualisation
extension on the devices we target, and the vendor kernels do not expose `/dev/kvm` either.
A phone therefore reports `kvm=no` and is an **LXC/TCG node**:

- LXC containers (including the Waydroid container itself) are the normal guest type;
- QEMU VMs run under QEMU's own software emulator (`-machine accel=tcg`), which is what
  `patches/qemu-server/0003-tcg-default-without-kvm.patch` makes the default;
- hardware-accelerated VMs belong on KVM nodes; migrating a guest off a phone is a
  deliberate, warned choice.

pKVM (Google's kernel-level virtualisation for Android, upstream in the 6.x Android kernels)
is the path that could give Pixel 6+ devices real acceleration later; it is out of scope for
this milestone and tracked as a separate effort.

## Recommended first test phones

1. **OnePlus 6 / 6T** — best mainline Linux support of any phone we own the budget for
   (path A: mainline kernel, `freedreno` on its Snapdragon 845 GPU, LXC and Waydroid GPU
   expected to work). First target for the whole stack.
2. **Pixel 3a** — Snapdragon, mainline-supported, second path-A device; also the cheapest
   way to test a second hardware vendor.
3. **Samsung Galaxy S9 (`starlte`, Exynos)** — the first *phone* in the device order, on
   path B (vendor kernel + libhybris); it is the reference case for everything that does
   not have mainline support.
4. **Pixel 6 and newer** — for pKVM experiments, later.

## Open questions

- **Modem/network**: on path A the host kernel's NetworkManager/pppoe stack must coexist with
  Waydroid's virtual network (`veth`/`tap` inside the container): does the phone's own uplink
  stay reachable from the container, and how do we keep the WireGuard `wg0` overlay up when the
  phone roams (the join daemon must re-bind, not restart)? On path B the vendor kernel's
  SELinux/NetFilter policies apply to the host side and libhybris must be taught the sockets.
- **Camera**: no mainline camera driver for the sensors we target (the S9's ISP and the
  Snapdragon ISPs need vendor code). Open questions: whether `/dev/shm`-based MI→V4L2 bridging
  is enough for SuperMox's use (document/webcam guests, QR scanning *into* the phone), and
  whether a camera guest inside Waydroid can be exposed to the PVE API at all.
- **Power management**: a phone is battery-powered and its charging, CPU capping and
  display-refresh behaviour are vendor features. Questions: what does a TCG QEMU guest cost
  in milliwatts, how do we cap guests so the device still charges and survives a heat
  throttle, and does Waydroid's full-screen compositor keep the device warm forever?
  Needs a measured power budget per device before we ship a default guest count.
- **Waydroid GPU on each path**: path A — does Mesa `freedreno`/`panfrost` render into
  Waydroid's Wayland session when `/dev/dri` and the Wayland sockets are passed through the
  LXC bind mounts, on a phone rather than a desktop? path B — does the vendor GL stack work
  through libhybris at all, and if not, is a software (AGI/OpenGL ES → framebuffer) fallback
  fast enough for a full-screen UI? Both paths need a per-device "GPU yes/no" probe in
  `supermox-node-caps` before the UI is enabled by default.
- **SELinux/Android security contexts** on path B: LXC inside a vendor kernel with SELinux
  enforcing needs either a permissive context for the container or a policy; unresolved.
- **Updates**: how the LineageOS image inside Waydroid and the Lawnchair APK are updated
  in place (checksum-pinned downloads only, no `apt`-less `curl | sh`), and what happens to
  the container's persistent state across a host kernel upgrade.
