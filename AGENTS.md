# SuperMox

## Purpose
SuperMox forks PXVIRT (an arm64-capable fork of Proxmox VE, AGPLv3) onto Devuan Ceres
running under sysvinit. ZERO systemd is a hard requirement: no systemd packages, units,
`systemctl` calls, `sd_notify`, or libsystemd in anything we ship. SuperMox is architecture-neutral
(arm64, armhf, amd64, riscv64, loong64, ...); amd64 is only the first test target. Target devices,
in order: amd64 KVM VM first, then arm64, then a Samsung Galaxy S9 (Exynos, LineageOS device "starlte")
as the first phone.

## Layout
- `scripts/` — build and check scripts (bash, `set -euo pipefail`, shellcheck-clean).
- `tests/` — `test-*.sh` test scripts run by the gate.
- `patches/<component>/` — our changes to upstream code, as patch files or new files.
- `init.d/` — sysvinit service scripts for the PVE services.
- `docs/` — planning and design documents.
- `config/` — configuration shipped to the target.
- `upstream/` — git-ignored, read-only PXVIRT sources (pinned commit). Never edited.
- `build/` — git-ignored scratch and temporary files. Never use `/tmp` for temp files.

## Licensing
PXVIRT/Proxmox code is AGPLv3 and stays AGPLv3; keep upstream copyright notices intact.
LineageOS parts are Apache-2.0/GPL; keep their notices. Never use the "Proxmox" name or
logo for our branding — it is a trademark.

## Commands
Run the gate: `bash scripts/check.sh`. It must end with "All checks passed."
