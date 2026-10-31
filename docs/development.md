# Developing SuperMox

How to build, test and change SuperMox. For what the pieces are, see
[architecture.md](architecture.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `src/supermox/` | Cluster join, discovery (gossip, DHT locator), home sync. Python 3, pure where possible. |
| `src/supermox_manager/` | SuperMox Manager desktop client: `api.py` (pinned HTTPS client), `app.py`, `pages/` (one module per native page), `ops/` (API logic). |
| `bin/` | `supermox-join`, `supermox-joind`, `supermox-sync`, `supermox-manager`. |
| `init.d/` | sysvinit scripts for every PVE daemon and SuperMox service. |
| `patches/` | Our changes to upstream components, as patch files. |
| `config/` | `upstream-overrides.txt`, `shipped-scripts.txt` (every file the packages ship), `init-scripts.txt`, the systemd allowlist and baseline, network and module-load settings. |
| `packaging/` | Debian packaging for SuperMox's own packages. |
| `scripts/` | Build, VM, check and helper scripts (table below). |
| `tests/` | Shell tests (`test-*.sh`), Python unit tests (`tests/py/`), the Manager GUI smoke test (`gui-manager.py`) and live tests (`manager-live.sh`, `manager-live/`). |
| `upstream/` | Fetched PXVIRT sources. Git-ignored and never edited. |
| `build/` | All build output and temporary files. Git-ignored. |
| `website/` | supermox.me (built by `scripts/build-website.sh`, which stages only public assets). |

## The gate

```sh
bash scripts/check.sh
```

Every change must leave it ending with `All checks passed.` It runs shellcheck on every
script, the shell and Python test suites, the no-systemd checks, the upstream-overrides
check, checks that every Manager module is listed in `config/shipped-scripts.txt`, and the
Manager GUI smoke test (every registered page, headless).

## Build and test VMs

All PVE work happens in KVM virtual machines, never on the host.

| VM | Data | ssh | Start |
| --- | --- | --- | --- |
| Build VM | `SUPERMOX_VM_DIR` (default in `scripts/vm-start.sh` is the maintainer's data disk: set it on your machine) | port 2223 | `bash scripts/vm-start.sh --background` |
| Test VM | `SUPERMOX_VM_DIR=build/test-data` | port 2224, API forwarded to 127.0.0.1:18006 | `SUPERMOX_VM_DIR=... SUPERMOX_VM_SSH_PORT=2224 bash scripts/vm-start.sh --background` |

- Always pass BOTH `SUPERMOX_VM_DIR` and `SUPERMOX_VM_SSH_PORT` for the test VM: the port alone
  boots the build VM's disk.
- One VM at a time: the development PC runs out of RAM with two. `bash scripts/vm-status.sh`
  shows what is running; `scripts/vm-stop.sh` (with the same `SUPERMOX_VM_DIR`) stops it.
- On the development PC, start VMs with `SUPERMOX_VM_RAM=2048`: the local model and the
  desktop leave about 2 GB free.
- Run commands inside a VM with `bash scripts/vm-ssh.sh '<cmd>'`; wait for ssh with
  `scripts/vm-wait-ssh.sh` (at most 100 s).

Typical package build:

```sh
bash scripts/fetch-upstream.sh
bash scripts/build-rootfs.sh
bash scripts/vm-start.sh --background && bash scripts/vm-smoke.sh
bash scripts/vm-setup-proxmox-repos.sh
bash scripts/vm-build-pkg.sh pve-manager        # one component at a time
bash scripts/vm-test-install.sh                 # milestone 1 on a clean test VM
```

## Scripts

| Script | Purpose |
| --- | --- |
| `fetch-upstream.sh` | Clone PXVIRT and apply the pinned upstream overrides. |
| `apply-patches.sh`, `patch-workspace.sh`, `patch-save.sh` | Apply our patches, open a component for editing, save changes back as a patch. |
| `build-rootfs.sh`, `arch.sh` | Build the Devuan Ceres VM image for `SUPERMOX_ARCH`. |
| `vm-start.sh`, `vm-stop.sh`, `vm-status.sh`, `vm-ssh.sh`, `vm-wait-ssh.sh`, `vm-smoke.sh` | VM lifecycle and access. |
| `vm-setup-proxmox-repos.sh`, `vm-prepare-build.sh`, `vm-missing-build-deps.sh`, `vm-build-pkg.sh` | Build PVE packages inside the build VM. |
| `vm-test-install.sh` | Install our packages on a clean VM, start PVE under sysvinit, prove there is no systemd. |
| `join-e2e.sh` | Real WireGuard join between network namespaces in the test VM. |
| `build-iso.sh` | PC edition ISO (needs a Spaced Linux checkout). |
| `build-manager.sh` | The architecture-neutral `supermox-manager` package. |
| `build-website.sh`, `branding-assets.sh` | Website and branding exports. |
| `check.sh`, `check-no-systemd.sh`, `check-overrides.sh`, `inventory-systemd.sh`, `build-deps-report.sh` | Gate and audits. |
| `supermox-node-caps.sh` | Node capability tier probe (KVM / LXC / TCG). |
| `supermox-android-setup.sh` | Prepare a node for the Android layer (Waydroid + Lawnchair). |
| `supermox-logpipe` | Send a daemon's stderr to syslog under sysvinit. |

## Live Manager tests

```sh
bash tests/manager-live.sh
```

Needs the booted test VM (ssh 2224, root password `supermox` in the test image). It reads the
VM's certificate fingerprint over ssh and runs `tests/manager-live/test_*.py` against the real
API. Not part of the gate; skips when no VM is running.

## How work is done here

Most code is written by a local model ("Strata", Qwen3.8 Flash Next) through small task files
(`.strata/`, git-ignored): each task names exact files, functions and tests, runs the gate, and
is committed by a runner as `<task> (local model task, pending review)` on the `strata-m1`
branch. Tasks that fail the gate get one fix-up attempt and are otherwise parked on a
`failed/<task>` branch. Rules every task follows: no git operations, no sudo, no systemd, never
edit `upstream/`, temporary files under `build/`, one VM at a time. See [AGENTS.md](../AGENTS.md).
