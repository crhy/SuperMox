---
name: supermox-release-push
description: "SuperMox 10.26 release push (started 2026-11-03): audit r01-r14 done, fix queue f01-f17, rhY's fork decisions, ISO build state"
metadata:
  node_type: memory
  type: project
  originSessionId: 0b53333f-37c2-55cb-a16a-bff81740d1d0
  modified: 2026-11-04T19:40:16.245Z
---

rhY asked (2026-11-03) for Strata to audit every aspect of SuperMox for release, Claude to double-check, and GitHub issues
for anything not 100% reliable. Audit tasks r01-r14 and fix tasks f01-f17 live in ~/supermox/.strata/ (notes-<task>.md each);
queue = ~/supermox-strata-backlog.txt run by ~/supermox-strata-runner.sh. Header rules 10-12 added: findings table, exact
notes filename, NEVER git commit (Strata self-committed f05/f08/f11).

rhY's decisions: fork rrdcached (Debian ships only systemd units) as our own package (f16); fork isc-dhcp-client from
Debian trixie isc-dhcp 4.4.3-P1-8 because Ceres dropped it and pve-container needs it (f17; long-term port = crhy/SuperMox#9).
Issues filed: #5 LICENSE (blocker, rhY must pick licence), #6 arm64, #7 Android GUI, #8 ISO, #9 DHCP; crhy/spaced#401
(xorg-server 21.1.25-1devuan1 source gone from Devuan pool; worked around with prebuilt debs from spaced-apt).

ISO: rhY approved running the root ISO build (never store credentials anywhere). Worktree build/spaced-iso is a symlink to
/media/rhy/data/supermox-spaced-iso (root disk only 16 GB free). build-iso.sh now swaps systemd-standalone-* for
opensysusers, runs build/iso-pre-clean.sh (unmount chroot leftovers) before make prepare, and checks the chroot with
check-no-systemd on --collect-only. Build attempt 4 got to the install pass; blocked only on isc-dhcp-client.

**Why:** release must be 100% reliable; rhY wants Strata doing the work, Claude reviewing.
**How to apply:** after f16/f17 and f10 (rebuild + clean install) pass, rebuild the ISO as root (mksquashfs -mem 1G
-processors 4, nice), --collect-only, boot-test it in a VM only when no other VM runs; then f13 (release-check + docs).
Related: [[delegate-coding-to-local-qwen]], [[strata-ram-budget]], [[spaced-no-systemd]], [[notes-live-on-github]].
