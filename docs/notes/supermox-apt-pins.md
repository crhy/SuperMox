---
name: supermox-apt-pins
description: The apt origin pins are a file shipped by supermox-ve (/etc/apt/preferences.d/supermox-origins); the build VM and ISO scripts copy it, they never re-type it.
metadata:
  type: feedback
---
The single source of truth for apt origin pins is `packaging/supermox-ve/etc/apt/preferences.d/supermox-origins`,
installed by the `supermox-ve` package at `/etc/apt/preferences.d/supermox-origins`. `scripts/vm-setup-proxmox-repos.sh`
copies it into the build VM (`install -m 0644 /dev/stdin …` over ssh) and `scripts/build-iso.sh` copies it to
`config/archives/supermox.pref.chroot`; neither may carry an inline `Pin-Priority:` block again.

**Why:** issue crhy/SuperMox#10 (release blocker): the pins existed only as two inline heredocs in build scripts, and
`dpkg -S /etc/apt/preferences.d/supermox-origins` found no path — so an *installed* system had no pin at all and a plain
`apt upgrade` after a user added the Proxmox repo replaced our sysvinit builds with upstream systemd-based ones, security
updates included. A pin that is not in a package protects nothing on the machine that matters.

**What the file pins:** `Package: *` from origin `""` at 999 (our local builds win), `Package: *` from
`download.proxmox.com` at 100, `swtpm swtpm-libs swtpm-tools` at 600 (qemu-server needs Proxmox's patched swtpm
0.10.2+pve1, not Devuan's), `Pin-Priority: -1` from `download.proxmox.com` for exactly the packages SuperMox rebuilds,
and `Pin: version *` / `Pin-Priority: -1` for the systemd packages (naming packages to block them is existing practice;
SuperMox itself stays sysvinit-only: the block names packages only, never a service-manager command, a path or a unit file).

**The -1 set is the rebuild set, and the names are not the component names:** the components are the directories under
`patches/` (proxmox-perl-rs pve-cluster pve-common pve-container pve-firewall pve-ha-manager pve-manager pve-storage
qemu-server) plus the components `config/upstream-overrides.txt` pins to an upstream commit without a patch of its own
yet (pve-access-control pve-guest-common pve-http-server proxmox-ve librados2-perl). `proxmox-perl-rs` builds the package
`pve-rs` (from its `pve-rs` subdir, see `config/build-subdirs.txt`), and upstream's `proxmox-ve` meta package is replaced
by our `supermox-ve`, which `Provides: proxmox-ve`. The pin file carries that component → package mapping as comments, and
`tests/test-apt-pins.sh` fails if a `patches/` directory or an `upstream-overrides.txt` component is missing from it, so
adding a rebuilt component without pinning it is caught by the gate.

**These are structural pins, not holds** (see [[supermox-track-current-proxmox]]): nothing here keeps a Proxmox package
behind the version upstream ships today; they only decide which origin a package may come from.

**Still open in #10:** the signed SuperMox apt repository configured by `supermox-ve` (item 1), the `+supermoxN` version
suffix on rebuilt components (item 3) and the release routine (item 4). Until item 1 lands the pins have no published
SuperMox origin to prefer, so an installed system still gets no updates.

**How to apply:** change the pins in the package file only; run `bash tests/test-apt-pins.sh` (it also asks apt itself to
parse the file, because a continuation line without its leading space makes apt reject the whole record — the bug the old
ISO heredoc had) and `bash scripts/check-no-systemd.sh --source .`; the pin file is listed in `config/systemd-allowlist.txt`
because it names systemd packages in order to refuse them. Related: [[supermox-track-current-proxmox]],
[[supermox-release-push]].
