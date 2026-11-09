---
name: supermox-track-current-proxmox
description: SuperMox is a Proxmox fork that should stay close to current upstream; target what Proxmox ships today, not an older point release.
metadata:
  type: feedback
---
When updating SuperMox's upstream base, move every pinned component (config/upstream-overrides.txt) to the version Proxmox's
trixie pve-no-subscription repo ships *now*. Don't stop at a point release named in an older issue or note.

**Why:** rhY, 2026-11-08: "as a proxmox fork we should try to stay mostly current". Issue #10 said 9.2.25, but by then Proxmox
had shipped 9.2.26 and nine other components had moved too; pinning only the old version would have left a mismatched set.
**How to apply:** read the current Packages index before writing the task, pin the whole matching set, and restart the
`+supermoxN` suffixes at `+supermox1`. Do these updates regularly (#10 item 4) rather than letting them pile up. Related: [[supermox-release-push]].

**No version holds (rhY, 2026-11-08: "Stop pinning things. We want to stay in sync with proxmox"):** never add an apt
`Pin: version` hold that keeps a Proxmox package behind. The one we had (libpve-network-* at 1.6.7) broke the 11.26 clean
install once the base moved; u04 removes it. Pins that stay because they are structural, not holds: the systemd -1 blocks, and
our-build-over-Proxmox priorities for the packages we rebuild (without them apt upgrade replaces our sysvinit builds with
Proxmox's systemd builds). Stay in sync by rebuilding promptly when Proxmox moves (drift check, task u05).
