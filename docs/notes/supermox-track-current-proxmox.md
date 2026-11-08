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
