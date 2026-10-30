# SuperMox

## Purpose
SuperMox forks PXVIRT (an arm64-capable fork of Proxmox VE, AGPLv3) onto Devuan Ceres
running under sysvinit. ZERO systemd is a hard requirement: no systemd packages, units,
`systemctl` calls, `sd_notify`, or libsystemd in anything we ship. SuperMox is architecture-neutral
(arm64, armhf, amd64, riscv64, loong64, ...); amd64 is only the first test target. Target devices,
in order: amd64 KVM VM first, then arm64, then a Samsung Galaxy S9 (Exynos, LineageOS device "starlte")
as the first phone.

## Versioning
SuperMox follows Spaced Linux versioning. The release line is named for the month and
two-digit year it opens in (10.26 = October 2026). The number before the dot is a month,
so after 12.26 comes 1.27. Patch releases add a third part (10.26.1). A line keeps its
name if it slips past its month.

## Layout
- `scripts/` — build and check scripts (bash, `set -euo pipefail`, shellcheck-clean).
- `tests/` — `test-*.sh` test scripts run by the gate.
- `tests/py/` — Python unit tests for the join protocol (run via `tests/test-python.sh`).
- `bin/` — user-facing CLI tools (supermox-join, supermox-joind).
- `src/supermox/` — Python package: identity, invite, join protocol, secret, state.
- `packaging/` — Debian package sources for our own packages (supermox-ve, supermox-tmpfiles).
- `patches/<component>/` — our changes to upstream code, as patch files or new files.
- `init.d/` — sysvinit service scripts for the PVE services.
- `cron/` — cron jobs shipped to the target (pve-daily-update).
- `docs/` — planning and design documents.
- `config/` — configuration shipped to the target.
- `upstream/` — git-ignored, read-only PXVIRT sources (pinned commit). Never edited.
- `build/` — git-ignored scratch and temporary files. Never use `/tmp` for temp files.

## Licensing
PXVIRT/Proxmox code is AGPLv3 and stays AGPLv3; keep upstream copyright notices intact.
LineageOS parts are Apache-2.0/GPL; keep their notices. Never use the "Proxmox" name or
logo for our branding — it is a trademark.

## Commands
- Gate: `bash scripts/check.sh`. It must end with "All checks passed."
- Unit tests: `bash tests/test-python.sh` (Python join-protocol tests, run by the gate).
- Build ISO: `bash scripts/build-iso.sh` (requires a Spaced checkout; see docs/pc-edition.md).
