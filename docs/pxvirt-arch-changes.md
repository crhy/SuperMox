# PXVIRT Architecture Changes

Inventory of changes PXVIRT made to Proxmox VE components, for porting onto
the upstream versions SuperMox builds. Each change is classified:
**arch support** (non-amd64), **branding**, **packaging**, or **other**.

## pve-manager

- PXVIRT commit: `74d1bcc54a6e67309b2dc40b6555caf54f0d0e38`
- Upstream base: 9.0.10 (`deb1ca707ec72a89f2f1b4d3b4b33989e99bc9c5`)
- PXVIRT commits: `74d1bcc5 bump pve-manager to 9.0.10-2`

| File | Change | Class |
|------|--------|-------|
| `PVE/API2/Hardware.pm` | Adds Hardware::INFO and Hardware::NET sub-APIs | arch support |
| `PVE/API2/Hardware/INFO.pm` | New: reads `/run/pve/query-machine-info` (lscpu/dmidecode) | arch support |
| `PVE/API2/Hardware/NET.pm` | New: detects network devices via `/sys/class/net/`, virtio detection | arch support |
| `PVE/API2/Hardware/PCI.pm` | Adds `driver`/`driver_inuse` fields, `pcitool` POST for reset/bind/unbind | arch support |
| `PVE/NodeConfig.pm` | Adds IPMI config (address, username, password) | other |
| `bin/query-machine-info` | New bash script: lscpu/dmidecode/jc/jq → `/run/pve/query-machine-info` | arch support |
| `services/pve-query-machine-info.service` | New systemd unit for query-machine-info | arch support |
| `configs/pxvirt-sources.list` | New apt sources file (replaces pve-sources.sources) | packaging |
| `aplinfo/mirrors.lierfang.com.pubkey` | New PGP pubkey for lierfang.com repo | branding |
| `www/manager6/qemu/ArchEdit.js` | New: arch combo (x86_64/riscv64/loongarch64/aarch64/s390x/ppc64) | arch support |
| `www/manager6/qemu/OSDefaults.js` | Defaults: busType→scsi, networkCard→virtio, cputype→host, nvme/spdk priority | arch support |
| `www/manager6/qemu/CreateWizard.js` | Adds nvme bus, arch combo box | arch support |
| `www/manager6/qemu/MachineEdit.js` | Adds pc/virt/pseries/s390-ccw-virtio machine types | arch support |
| `www/manager6/qemu/PCIEdit.js` | Adds ramfb field handling | arch support |
| `www/manager6/qemu/HardwareView.js` | Hardware view changes for arch-aware PCI | arch support |
| `www/manager6/qemu/SystemEdit.js` | System edit changes | arch support |
| `www/manager6/qemu/Options.js` | Options changes | arch support |
| `www/manager6/qemu/DisplayEdit.js` | Display edit changes | arch support |
| `www/manager6/qemu/HDEdit.js` | HD edit changes (nvme/spdk) | arch support |
| `www/manager6/qemu/HDEfi.js` | EFI changes | arch support |
| `www/manager6/qemu/MultiHDEdit.js` | Multi-HD changes | arch support |
| `www/manager6/form/BusTypeSelector.js` | Adds nvme, spdk options | arch support |
| `www/manager6/form/CPUModelSelector.js` | Removes kvm64 default text | arch support |
| `www/manager6/form/ControllerSelector.js` | Refactored auto-select logic | arch support |
| `www/manager6/form/ScsiHwSelector.js` | SCSI hardware selector changes | arch support |
| `www/manager6/form/SpiceEnhancementSelector.js` | New: spice enhancement selector | arch support |
| `www/manager6/form/VMCPUFlagSelector.js` | CPU flag selector changes | arch support |
| `www/manager6/Makefile` | Adds qemu/ArchEdit.js to JSSRC | arch support |
| `www/manager6/Utils.js` | Utility changes | other |
| `www/manager6/Workspace.js` | Workspace changes | other |
| `www/manager6/ceph/OSD.js` | OSD changes | other |
| `www/manager6/ceph/ServiceList.js` | Service list changes | other |
| `www/manager6/ceph/StatusDetail.js` | Status detail changes | other |
| `www/manager6/dc/Config.js` | DC config changes | other |
| `www/manager6/dc/Summary.js` | DC summary changes | other |
| `www/manager6/dc/Support.js` | Support page changes | branding |
| `www/manager6/node/StatusView.js` | Status view changes | other |
| `www/manager6/node/Summary.js` | Node summary changes | other |
| `www/manager6/storage/PBSEdit.js` | ngettext→gettext fix | other |
| `www/manager6/window/LoginWindow.js` | "Proxmox VE Login"→"PXVIRT Login" | branding |
| `www/mobile/Login.js` | New mobile login widget | other |
| `www/mobile/QemuSummary.js` | New mobile qemu summary | other |
| `www/mobile/WidgetToolkitUtils.js` | New 1425-line file copied from widget-toolkit Utils.js | other |
| `www/mobile/index.html.tpl` | New mobile index template | other |
| `bin/pvebanner` | "Welcome to the Proxmox Virtual Environment"→"Welcome to the Pxvirt Powered by Lierfang" | branding |
| `bin/pvessh` | New 795-line parallel SSH script (from nexvium/allssh, MIT) | other |
| `PVE/API2/Subscription.pm` | Hardcoded active subscription, url→lierfang.com, serverid→"lierfangnode" | branding |
| `PVE/APLInfo.pm` | Branding changes | branding |
| `PVE/API2/Cluster.pm` | Cluster API changes | other |
| `PVE/API2/Network.pm` | Network API changes | other |
| `PVE/CLI/pveceph.pm` | pveceph changes | other |
| `PVE/Service/pvestatd.pm` | pvestatd changes | other |
| `www/index.html.tpl` | Title "Proxmox Virtual Environment"→"Pxvirt" | branding |
| `www/images/favicon.ico` | Binary: new favicon | branding |
| `www/images/logo-128.png` | Binary: new logo | branding |
| `www/images/proxmox_logo.png` | Binary: new logo | branding |
| `debian/control` | Maintainer→Lierfang, Architecture: all→any, added libfile-slurp-perl/dmidecode/jc/jq deps | packaging |
| `debian/copyright` | Copyright→Lierfang, AGPL | branding |
| `debian/changelog` | Lierfang entries (js fix, pxvirt patch, spice gstreamer, spdk disk, snapshot flag, sriove mac/tag, ramfb, remove proxmox text, pxvirt icon, pvessh, mdev display, pxvirt subscription) | branding |
| `debian/lintian-overrides` | Lintian overrides | packaging |
| `debian/postinst` | Postinst changes | packaging |
| `Makefile` | Build changes | packaging |
| `bin/Makefile` | Build changes | packaging |
| `configs/Makefile` | `pve-sources.sources`→`pxvirt-sources.list` | packaging |
| `aplinfo/Makefile` | Build changes | packaging |
| `aplinfo/aplinfo.dat` | aplinfo data change | other |
| `services/Makefile` | Build changes | packaging |
| `PVE/API2/Hardware/Makefile` | Build changes | packaging |

## qemu-server

- PXVIRT commit: `9ce19f9cf0a8d78641d4956cd304813f641eb013`
- Upstream base: 9.0.22 (`5208318f8147305891a0b56c00cd1585eaa23f8c`)
- PXVIRT commits: `9ce19f9c Merge remote-tracking branch 'origin/master' into pxvirt`

| File | Change | Class |
|------|--------|-------|
| `src/PVE/QemuServer/CPUConfig.pm` | Adds Hygon, Zhaoxin, ARM (cortex-a*, neoverse-*, Kunpeng-920), LoongArch (la464, la132), RISCV (rv64), POWER CPU types; `get_default_cpu_type()` exported | arch support |
| `src/PVE/QemuServer/OVMF.pm` | aarch64 (AAVMF_CODE/VARS + 4m), loongarch64 (LOONGARCH64_VIRT_CODE/VARS), riscv64 (RISCV_VIRT_CODE/VARS) | arch support |
| `src/PVE/QemuServer/PCI.pm` | Arch-dependent PCI address map (virtio-centric for non-x86_64), mac/tag/ramfb hostpci, SRIOV MAC/VLAN via `ip link set`, spdk disk bus slots, virtio0-5, hostpci0-2 | arch support |
| `src/PVE/QemuServer.pm` | `arch` config option (x86_64/aarch64/loongarch64/riscv64/ppc64/s390x), `gicversion`, `virtualization` for arm, bios→ovmf on non-x86_64, machine→virt, cpu per arch, virtio-gpu vs virtio-vga, tpm-tis vs tpm-tis-device, query_supported_cpu_flags dies on loongarch64, nvme bootindex s390x, virtio-gl egl `$arch-linux-gnu` | arch support |
| `src/PVE/QemuServer/Machine.pm` | Adds `s390-ccw-virtio` and `pseries`; default machines: riscv64→virt, loongarch64→virt, ppc64→pseries, s390x→s390-ccw-virtio; `get_host_arch` import | arch support |
| `src/PVE/QemuServer/Spdk.pm` | New 288-line module: SPDK disk support, arch-aware machine type (pc for x86_64, virt otherwise), CPU mask parsing | arch support |
| `src/PVE/QemuServer/Drive.pm` | nvme format (max_ioqpairs, msix_qsize, mdts, use-intel-id), MAX_SPDK_DISKS=6, MAX_NVME_DISKS=16, `max_spdk_disks()` exported | arch support |
| `src/PVE/QemuServer/USB.pm` | `qemu-xhci` for all non-x86_64 arch (was only aarch64), `use_qemu_xhci=1` for non-x86_64 | arch support |
| `src/PVE/QemuServer/Blockdev.pm` | spdk resize guard, blockdev_replace refactor | arch support |
| `src/PVE/QemuServer/Helpers.pm` | Helper changes | arch support |
| `src/PVE/API2/Qemu.pm` | API changes for arch/spdk/nvme | arch support |
| `src/PVE/API2/Qemu/Machine.pm` | Machine API changes | arch support |
| `src/PVE/API2/NodeCapabilities/Qemu/Migration.pm` | Migration capability changes | arch support |
| `src/PVE/QemuMigrate.pm` | Migration changes | arch support |
| `src/PVE/QemuMigrate/Helpers.pm` | Migration helper changes | arch support |
| `src/PVE/CLI/qm.pm` | qm CLI changes | arch support |
| `src/query-machine-capabilities/query-machine-capabilities.c` | New C binary for machine capabilities | arch support |
| `src/test/cfg2cmd/aarch64.conf` | New test config for aarch64 VM (spdk, virtio, hostpci, virtiofs-mem) | arch support |
| `src/test/cfg2cmd/aarch64.conf.cmd` | Expected qemu cmdline for aarch64 | arch support |
| `src/test/cfg2cmd/nvme.conf` | New nvme test config | arch support |
| `src/test/cfg2cmd/nvme.conf.cmd` | Expected nvme cmdline | arch support |
| `src/test/cfg2cmd/spdk.conf` | New spdk test config | arch support |
| `src/test/cfg2cmd/spdk.conf.cmd` | Expected spdk cmdline | arch support |
| `src/test/cfg2cmd/aio.conf.cmd` | Updated expected cmdline | arch support |
| `src/test/cfg2cmd/bootorder-empty.conf.cmd` | Updated expected cmdline | arch support |
| `src/test/cfg2cmd/bootorder-legacy.conf.cmd` | Updated expected cmdline | arch support |
| `src/test/cfg2cmd/bootorder.conf.cmd` | Updated expected cmdline | arch support |
| `src/test/cfg2cmd/simple-backingchain.conf.cmd` | Updated expected cmdline | arch support |
| `src/usr/pve-port.cfg` | New port config | other |
| `src/usr/bootsplash.jpg` | Binary: new bootsplash | branding |
| `Makefile` | `DEB_BUILD_ARCH`→`DEB_HOST_ARCH`, added `-a$(DEB_HOST_ARCH)` to dpkg-buildpackage | packaging |
| `debian/control` | Maintainer→Lierfang, homepage→lierfang.com | branding |
| `debian/copyright` | Copyright→Lierfang, AGPL | branding |
| `debian/changelog` | virtio-gpu fix on x86_64, spdk disk support, Zhaoxin/Hygon cpu, nvme live migration reject, spice preferredcodec, smbios type2/serial | arch support |
| `debian/rules` | Build rules changes | packaging |
| `src/qmeventd/Makefile` | Build changes | packaging |
| `src/query-machine-capabilities/Makefile` | Build changes | packaging |
| `src/PVE/QemuServer/Makefile` | Build changes | packaging |
| `src/usr/Makefile` | Build changes | packaging |

## pve-common

- PXVIRT commit: `abc46df3cb4fb22a438ae0192275a621b9899c97`
- Upstream base: 9.0.11 (`569bd924e85d5e72b952407f4f87700bc7f46140`)
- PXVIRT commits: `abc46df bump version to 9.0.11-1`

| File | Change | Class |
|------|--------|-------|
| `Makefile` | `ARCH=all`→`ARCH:=$(shell dpkg-architecture -qDEB_BUILD_ARCH)` (arch-specific build) | packaging |
| `src/PVE/Tools.pm` | cpuname arm64 parse, lspci drive show, pcitools | arch support |
| `src/PVE/SysFSTools.pm` | mknodat syscall changes | arch support |
| `src/PVE/Syscall.pm` | Syscall changes | arch support |
| `src/PVE/ProcFSTools.pm` | ProcFS changes | other |
| `src/PVE/Ticket.pm` | Ticket changes | other |
| `debian/control` | Maintainer→Lierfang, homepage→lierfang.com | branding |
| `debian/changelog` | cpuname arm64 parse, mknodat syscall, lspci drive show, pcitools, OpenSSL error queue fix | arch support |

## pve-container

- PXVIRT commit: `08d74c99a76e7f5a66aa70314799b760ceddc133`
- Upstream base: 6.0.13 (`ab898eb9f0280285976d02232094e5f6d0ae168d`)
- PXVIRT commits: `08d74c9 Merge branch 'proxmox:master' into pxvirt`

| File | Change | Class |
|------|--------|-------|
| `src/PVE/LXC/Config.pm` | Adds `loongarch64` to arch enum | arch support |
| `src/PVE/LXC/Setup/Anolis.pm` | New: Anolis OS support | other |
| `src/PVE/LXC/Setup/Plugin.pm` | Unknown ostype→unmanaged | other |
| `src/PVE/LXC/Setup.pm` | Setup changes | other |
| `src/PVE/LXC/Setup/Debian.pm` | Debian setup changes | other |
| `src/PVE/LXC/Setup/Ubuntu.pm` | Ubuntu setup changes | other |
| `src/PVE/LXC/Tools.pm` | Tools changes | other |
| `src/PVE/LXC/Setup/Makefile` | Build changes | packaging |
| `src/Makefile` | Build changes | packaging |
| `debian/changelog` | Changelog | branding |

## proxmox-ve

- PXVIRT commit: `1fefdb6b25261ca3863f7acce3864834193f2f08`
- Upstream base: 9.1.0 (`26cf867b97882c13bd6b10c3b0e052d42372bd60`)
- PXVIRT commits: `1fefdb6 bump version to 8.3.1`

| File | Change | Class |
|------|--------|-------|
| `debian/grub/pxvirt.cfg` | New grub config (replaces proxmox-ve.cfg) | branding |
| `debian/grub/proxmox-ve.cfg` | Removed | branding |
| `debian/proxmox-ve.install` | Install changes | packaging |
| `Makefile` | Removed pve-headers deb from build | packaging |
| `debian/control` | Maintainer→Lierfang, homepage→lierfang.com | branding |
| `debian/changelog` | "Build for pxvirt" | branding |

## pve-storage

- PXVIRT commit: `a9a902afab08ae4cdbcb150f7189e7c4be6b1444`
- Upstream base: 9.0.13 (`609752f3ae371537b65484caeee14d3ed1569743`)
- PXVIRT commits: `a9a902a Merge branch 'proxmox:master' into pxvirt`

| File | Change | Class |
|------|--------|-------|
| `src/PVE/CLI/pvebcache.pm` | New 510-line CLI tool for bcache management (show/make bcache, lsblk) | other |
| `src/bin/pvebcache` | New bcache binary wrapper | other |
| `src/PVE/Storage.pm` | Added `vdisk_clone_pxvirt()` calling `clone_image_pxvirt` | other |
| `src/PVE/Storage/Plugin.pm` | Added `clone_image_pxvirt()` using qemu-img create qcow2 | other |
| `src/PVE/Storage/RBDPlugin.pm` | Added `clone_image_pxvirt()` (rbd clone with snap protect, data-pool) | other |
| `src/PVE/Storage/LvmThinPlugin.pm` | LvmThin changes | other |
| `src/PVE/Storage/ESXiPlugin.pm` | Double-fork daemonize fix for FUSE mount | other |
| `src/PVE/Storage/ISCSIPlugin.pm` | ISCSI changes | other |
| `src/PVE/Storage/ZFSPoolPlugin.pm` | ZFSPool changes | other |
| `src/PVE/API2/Storage/Status.pm` | Added return schema properties (type, content, enabled, active, shared, total, used, avail) | other |
| `src/PVE/Diskmanage.pm` | Diskmanage changes | other |
| `src/test/run_test_zfspoolplugin.pl` | Test refactoring: `$test_vols` hash, `foreach_testvol`/`foreach_basevol` helpers | other |
| `debian/control` | Maintainer→Lierfang, homepage→lierfang.com | branding |
| `debian/copyright` | Copyright→Lierfang, AGPL | branding |
| `debian/changelog` | Changelog | branding |
| `Makefile` | Build changes | packaging |
| `src/PVE/CLI/Makefile` | Build changes | packaging |
| `src/bin/Makefile` | Build changes | packaging |

## pve-cluster

- PXVIRT commit: `5387c013fa3050d6ec8be9a1ab73692eb752b80d`
- Upstream base: 9.0.6 (`253de0cdfe1cd53ab8940c2e5147d363c82f9e46`)
- PXVIRT commits: `5387c01 fix abi issue`

| File | Change | Class |
|------|--------|-------|
| `src/PVE/API2/ClusterConfig.pm` | Added `vmlist` API endpoint (GET, root@pam only, reads `/etc/pve/.vmlist` JSON), uses `verify_root_api_key` | other |

## pve-access-control

- PXVIRT commit: `52ca9bfcbd000228ece0a5d32f56dbc8e001715a`
- Upstream base: 9.0.3 (`2c67c26f61138e9a97c5aab450d05a865eea6413`)
- PXVIRT commits: `52ca9bf Merge branch 'proxmox:master' into pxvirt`

| File | Change | Class |
|------|--------|-------|
| `src/PVE/AccessControl.pm` | Added `verify_root_api_key` function | other |
| `debian/control` | Maintainer→Lierfang, homepage→lierfang.com | branding |
| `debian/copyright` | Copyright→Lierfang, AGPL | branding |
| `debian/changelog` | Changelog | branding |

## Branding-only changes (single line)

All components: Maintainer→Lierfang, homepage→lierfang.com, copyright→AGPL/Lierfang.
pve-manager: pvebanner text, index.html.tpl title, favicon/logo images, LoginWindow text, Subscription.pm hardcoded active, APLInfo.pm, mirrors.lierfang.com.pubkey.
proxmox-ve: grub config renamed proxmox-ve.cfg→pxvirt.cfg.
qemu-server: bootsplash.jpg.
