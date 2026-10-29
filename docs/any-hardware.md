# Running SuperMox on any hardware

SuperMox must install and run on hardware without CPU virtualisation support:
most phones (a Samsung S9 has no EL2/KVM), old ARM boards, and VMs nested inside
another VM. A node therefore has a *capability tier*, and the cluster places
guests according to the tier of each node.

## The three tiers

| tier | requirement | what it can run |
|------|-------------|---------------|
| KVM | `/dev/kvm` openable rw (VT-x/AMD-V on x86, EL2 on ARM) | QEMU VMs with hardware acceleration: full speed, nested virt, host-passthrough CPU, GPU/PCI passthrough |
| LXC | kernel with PID namespaces + a mounted cgroup fs (`/proc/self/ns/pid`, `/sys/fs/cgroup`) | LXC containers only — no QEMU VMs at all |
| TCG | `qemu-system-*` binaries present | QEMU VMs under QEMU's own software emulator (`-machine accel=tcg`): works on any CPU, any guest arch, 10-100x slower, no host-passthrough CPU, no nested virt |

Tier order: KVM > TCG > LXC. A KVM node is also a TCG node and an LXC node;
a TCG node is also an LXC node. A node with none of the three can still run
pve-cluster/pve-manager services (a pure cluster "manager" node), but no guests.

## How a node finds its tier

`/usr/sbin/supermox-node-caps` (source: `scripts/supermox-node-caps.sh`) prints
`arch=`, `kvm=yes|no`, `lxc=yes|no`, `tcg_targets=`, `cpus=`, `mem_mb=`
(`--json` for machines). It is dependency-free so it also runs on Android/LineageOS,
where there is no `dpkg`, and never fails because a probe is missing. qemu-server
probes the same thing at runtime with `kvm_version()`; pvestatd publishes QEMU's
per-accelerator CPU flags into pmxcfs as `cpuflags-kvm` / `cpuflags-tcg`.

## Placement rules

- KVM VMs (fast, `kvm: 1`) only on nodes reporting `kvm=yes`.
- Same-arch LXC containers anywhere `lxc=yes` — cheapest guest type.
- Cross-arch VMs (`arch:` set) and VMs on `kvm=no` nodes run under TCG: last resort, warned in the task log, single-digit performance.
- Migrate a guest to a KVM node when one exists; TCG -> KVM is free, KVM -> TCG must be a deliberate, warned choice.

## qemu-server code paths found (upstream QemuServer.pm, pinned commit)

- `kvm_version()` (1045-1055): `open '<' /dev/kvm` then `ioctl 0xae00`
  (KVM_GET_API_VERSION); returns undef when the open fails. This is the only
  KVM availability probe in qemu-server.
- `config_to_command()`: `my $kvm = $conf->{kvm}` (3153),
  `$kvm //= 1 if is_native_arch($arch)` (3169), then the hard failure
  `if ($kvm && !defined kvm_version()) { die "KVM virtualisation configured,
  but not available..." }` (3200).
- `if (!$kvm) { push @$machineFlags, 'accel=tcg' }` (3747) — the TCG path.
- Template config minimisation already sets `kvm => 0` with the comment
  "to prevent an error on hosts without virtualization extensions" (3129).
- `query_supported_cpu_flags()` (2995-3080): `$kvm_supported = defined(kvm_version())
  && $arch eq $host_arch` (3001); it always queries the tcg flags and only
  queries kvm flags when supported, publishing them as `cpuflags-<accel>`.
- `PVE/QemuServer/CPUConfig.pm get_cpu_options()` (864): default CPU type,
  `hv-*` enlightenments and `enforce` only when `$kvm && $arch eq x86_64`;
  `PCI::print_hostpci_devices` returns `$kvm_off` into it.
- `PVE/QemuServer/Helpers.pm`: `get_command_for_arch` picks `/usr/bin/kvm`
  for the native arch else `/usr/bin/qemu-system-<arch>`; `get_vm_arch` is
  `conf->{arch} // host arch`.

## What happens today when /dev/kvm is missing

- VM with no `kvm:` setting and guest arch == node arch: `$kvm` defaults to 1
  (3169) and `config_to_command` **dies** at 3200 — `qm start`/`qm restore`/
  `qm clone`-then-start fail with "KVM virtualisation configured, but not
  available. Either disable in VM configuration or enable in BIOS." That is the
  hard failure a phone would hit for every VM it creates.
- VM with `kvm: 0` or `arch:` != node arch: `$kvm` is falsy, `accel=tcg` is
  added (3747) and the VM starts, slowly.
- Templates: forced `kvm => 0`, so template backup/restore works anywhere.
- `pvestatd` cpuflag publication already degrades: only `cpuflags-tcg` is
  filled in, `cpuflags-kvm` stays absent.

## Our change

`patches/qemu-server/0003-tcg-default-without-kvm.patch` replaces the
`$kvm //= 1 if is_native_arch($arch)` default: with `kvm:` unset and `kvm_version()`
unavailable, `$kvm` defaults to 0 (TCG) and a warning naming the node and VMID
goes into the task log. An explicit `kvm: 1` without `/dev/kvm` still dies at
3200, so an operator who wants hardware acceleration gets a clear error instead
of a silently 50x slower VM.
