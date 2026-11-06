#!/usr/bin/env bash
# SuperMox PC edition ISO: Spaced Linux desktop + SuperMox node packages + branding.
#
# The live-build run itself needs root, so the normal flow is:
#   bash scripts/build-iso.sh --prepare-only      # everything except lb build
#   <human runs the sudo command this script prints>
#   bash scripts/build-iso.sh --collect-only      # pick up the ISO, enforce the 2 GiB limit
#
# The Spaced Makefile is used as-is (never edited, never committed to): its `prepare`
# target runs `lb config` and stages build/live-build/config/, and at the end copies
# build/local-packages/*.deb into build/live-build/config/packages.chroot/. That is
# our hook point for the SuperMox .debs. Everything else is added after `prepare`,
# because `prepare` deletes and re-creates build/live-build/.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# SUPERMOX_ARCH names the ISO and the kernel package; amd64 is only the first target.
source "$repo_root/scripts/arch.sh"
# Paths: environment > config/local.env > build/ default (see docs/development.md).
source "$repo_root/scripts/local-env.sh"

SPACED_REPO="$SUPERMOX_SPACED_REPO"
# Packages our forks build that must never be installed on the ISO (exact
# package names, one per line, "# reason" comments allowed). stage_debs() skips
# them by name, so a package that merely starts with a listed name is kept.
EXCLUDE_FILE="$repo_root/config/iso-exclude-debs.txt"
# The .deb files vm-build-pkg.sh writes are read from SUPERMOX_DEBS_DIR (see
# config/local.env.example); a hard-coded default would stage stale debs.
DEB_DIR="$SUPERMOX_DEBS_DIR"
WORKTREE="$SUPERMOX_SPACED_WORKTREE"
KEY_URL='https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg'
HOST_KEY='/usr/share/keyrings/proxmox-archive-keyring.gpg'
KEY_CACHE="$repo_root/build/proxmox-archive-keyring.gpg"
# GitHub releases reject files larger than this.
ISO_MAX_BYTES=$((2 * 1024 * 1024 * 1024))
# Same squashfs tuning the Spaced Makefile uses (docs/10.26.6-IMAGE-SIZE.md).
MKSQUASHFS='-b 1M -Xbcj x86 -Xdict-size 100%'

spaced_ref="${SUPERMOX_SPACED_REF:-main}"
dry_run=0
prepare_only=0
collect_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spaced-ref)
      if [ "$#" -lt 2 ]; then
        printf 'ERROR: --spaced-ref needs a value\n' >&2
        exit 2
      fi
      spaced_ref="$2"
      shift 2
      ;;
    --spaced-ref=*)
      spaced_ref="${1#*=}"
      shift
      ;;
    --dry-run) dry_run=1; shift ;;
    --prepare-only) prepare_only=1; shift ;;
    --collect-only) collect_only=1; shift ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      printf 'usage: %s [--spaced-ref REF] [--dry-run] [--prepare-only] [--collect-only]\n' "$0" >&2
      exit 2
      ;;
  esac
done

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

step() { printf 'STEP: %s\n' "$*"; }

# Strip leading and trailing whitespace from a string.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

# Read config/iso-exclude-debs.txt into EXCLUDE_REASON[<package name>]=<reason>.
# Names are matched exactly, never as a prefix or glob.
declare -A EXCLUDE_REASON=()
load_exclude() {
  local raw name reason
  [ -f "$EXCLUDE_FILE" ] || fail "missing $EXCLUDE_FILE: the ISO must know which fork packages to skip"
  while IFS= read -r raw || [ -n "$raw" ]; do
    name="$(trim "${raw%%#*}")"
    [ -n "$name" ] || continue
    case "$name" in
      *[!a-z0-9+._-]*)
        printf 'WARN: ignoring invalid package name in %s: %s\n' "$EXCLUDE_FILE" "$name" >&2
        continue
        ;;
    esac
    reason="$(trim "${raw#*#}")"
    EXCLUDE_REASON["$name"]="$reason"
  done < "$EXCLUDE_FILE"
}

# Run a command, or just show it under --dry-run.
run() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'DRY-RUN: %s\n' "$*"
    return 0
  fi
  "$@"
}

# Write a file from stdin, or show that we would.
write_file() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'DRY-RUN: write %s\n' "$1"
    return 0
  fi
  cat > "$1"
}

# Append a fixed block to an existing file, or show that we would.
append_block() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'DRY-RUN: append to %s: %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')"
    return 0
  fi
  printf '%s\n' "$2" >> "$1"
}

# Newest .deb per package, no -dbgsym, no mk-build-deps helpers.
stage_debs() {
  local dir="$1"
  local f base name ver arch_f key
  local -A best_ver=()
  local -A best_file=()
  local -A managed=()
  local -a names=()

  if [ ! -d "$dir" ]; then
    if [ "$dry_run" -eq 1 ]; then
      step "no deb dir at $dir yet (dry-run: nothing staged)"
      return 0
    fi
    fail "no SuperMox deb dir at $dir (build the packages in the VM first)"
  fi

  shopt -s nullglob
  for f in "$dir"/*.deb; do
    base="${f##*/}"
    case "$base" in
      *-dbgsym_*.deb | *-build-deps_*.deb) continue ;;
    esac
    if [[ ! "$base" =~ ^(.*)_([0-9][^_]*)_(all|[^_]+)\.deb$ ]]; then
      printf 'WARN: skipping unparseable deb name: %s\n' "$base" >&2
      continue
    fi
    name="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}"
    arch_f="${BASH_REMATCH[3]}"
    managed[$name]=1
    if [ "$arch_f" != all ] && [ "$arch_f" != "$SUPERMOX_ARCH" ]; then
      printf 'WARN: skipping %s (deb arch %s != target %s)\n' "$base" "$arch_f" "$SUPERMOX_ARCH" >&2
      continue
    fi
    if [ -n "${EXCLUDE_REASON[$name]:-}" ]; then
      printf 'SKIP: %s (%s is listed in config/iso-exclude-debs.txt: %s)\n' \
        "$base" "$name" "${EXCLUDE_REASON[$name]}"
      continue
    fi
    if [ -z "${best_ver[$name]:-}" ] || dpkg --compare-versions "$ver" gt "${best_ver[$name]}"; then
      if [ -z "${best_file[$name]:-}" ]; then
        names+=("$name")
      fi
      best_ver[$name]="$ver"
      best_file[$name]="$f"
    fi
  done
  shopt -u nullglob

  step "stage ${#names[@]} SuperMox .deb from $dir (newest version per package, no -dbgsym, no -build-deps, no config/iso-exclude-debs.txt entries)"
  if [ "${#names[@]}" -eq 0 ]; then
    printf 'WARN: no SuperMox .debs found in %s\n' "$dir" >&2
    return 0
  fi
  run mkdir -p "$WORKTREE/build/local-packages"
  # Earlier runs left their copies here (other versions, and packages since
  # added to config/iso-exclude-debs.txt): live-build installs every deb in the
  # pool, so remove every version of each package we manage before staging.
  # Spaced's own builds in the same directory (marco, compiz, ...) are not ours
  # and stay.
  local stale
  for key in "${!managed[@]}"; do
    for stale in "$WORKTREE/build/local-packages/${key}_"*.deb; do
      [ -e "$stale" ] || continue
      run rm -f "$stale"
    done
  done
  while IFS= read -r key; do
    step "  ${best_file[$key]##*/}"
    run cp "${best_file[$key]}" "$WORKTREE/build/local-packages/"
  done < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  step "  -> $WORKTREE/build/local-packages, which the Spaced Makefile copies to $lb_dir/config/packages.chroot/"
}

# Copy the ISO live-build produced into build/iso/ and enforce the size limit.
collect_iso() {
  local built size
  if [ "$dry_run" -eq 1 ]; then
    step "collect: copy the built ISO to $iso_out and fail if it is larger than 2 GiB"
    return 0
  fi
  [ -d "$lb_dir" ] || fail "no live-build tree at $lb_dir (run --prepare-only first)"
  built="$(find "$lb_dir" -maxdepth 1 -type f -name '*.iso' -print -quit)"
  [ -n "$built" ] || fail "no ISO found in $lb_dir (lb build did not run or failed)"
  step "collect: $built -> $iso_out"
  run mkdir -p "$repo_root/build/iso"
  run cp "$built" "$iso_out"
  size="$(stat -c %s "$iso_out")"
  if [ "$size" -gt "$ISO_MAX_BYTES" ]; then
    printf 'FAIL: %s is %s bytes, over the 2 GiB GitHub release limit\n' "$iso_out" "$size" >&2
    return 1
  fi
  printf 'OK: %s (%s bytes, limit %s)\n' "$iso_out" "$size" "$ISO_MAX_BYTES"
  # The image the ISO was squashed from must hold no systemd at all.
  if [ -d "$lb_dir/chroot/var/lib/dpkg" ]; then
    SYSTEMD_IMAGE_ALLOWLIST_FILE="$repo_root/config/systemd-image-allowlist.txt" \
      bash "$repo_root/scripts/check-no-systemd.sh" --image "$lb_dir/chroot" \
      || { printf 'FAIL: the ISO image contains systemd\n' >&2; return 1; }
  fi
}

[ -d "$SPACED_REPO/.git" ] || fail "no Spaced checkout at $SPACED_REPO: set SUPERMOX_SPACED_REPO (export it, or set it in config/local.env) to a Spaced clone"
target_commit="$(git -C "$SPACED_REPO" rev-parse --verify "${spaced_ref}^{commit}" 2>/dev/null || true)"
[ -n "$target_commit" ] || fail "ref '$spaced_ref' not found in $SPACED_REPO"
spaced_version="$(git -C "$SPACED_REPO" show "${target_commit}:VERSION" 2>/dev/null | head -n1)"
[ -n "$spaced_version" ] || fail "no VERSION file at $spaced_ref in $SPACED_REPO"
release="${spaced_version%.*}"
lb_dir="$WORKTREE/build/live-build"
iso_name="supermox-${release}-pc-${SUPERMOX_ARCH}.iso"
iso_out="$repo_root/build/iso/$iso_name"
step "Spaced base $spaced_version ($target_commit); release line $release; ISO $iso_out"

if [ "$collect_only" -eq 1 ]; then
  collect_iso
  exit 0
fi

# --- worktree ---------------------------------------------------------------
step "worktree: git -C $SPACED_REPO worktree add --detach $WORKTREE $spaced_ref"
if [ -e "$WORKTREE/.git" ]; then
  wt_commit="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
  if [ "$wt_commit" = "$target_commit" ]; then
    step "reuse the existing worktree (already at $target_commit)"
  else
    step "worktree is at $wt_commit, replacing it"
    run git -C "$SPACED_REPO" worktree remove --force "$WORKTREE"
    run git -C "$SPACED_REPO" worktree prune
    run git -C "$SPACED_REPO" worktree add --detach "$WORKTREE" "$spaced_ref"
  fi
elif [ -d "$WORKTREE" ]; then
  fail "$WORKTREE exists but is not a git worktree; remove it manually"
else
  run git -C "$SPACED_REPO" worktree add --detach "$WORKTREE" "$spaced_ref"
fi

# --- our packages -----------------------------------------------------------
load_exclude
stage_debs "$DEB_DIR"

# The Manager is built on the host (build-manager.sh), not in the VM; stage the
# newest build/supermox-manager_*.deb so it wins over any older copy in DEB_DIR.
stage_manager() {
  local newest
  newest="$(ls -1t "$repo_root"/build/supermox-manager_*.deb 2>/dev/null | head -1)"
  [ -n "$newest" ] || { step "WARN: no build/supermox-manager_*.deb (run build-manager.sh first)"; return 0; }
  step "stage Manager: ${newest##*/} (newest from build/, overrides DEB_DIR copy)"
  run rm -f "$WORKTREE/build/local-packages/supermox-manager_"*.deb
  run cp "$newest" "$WORKTREE/build/local-packages/"
}
stage_manager

step "stage the live-build tree: make -C $WORKTREE prepare (needs sudo: builds marco in a chroot)"
step "deferring 'make prepare' to the sudo command (it needs root for chroot builds)"

# --- GRUB branding art: the backgrounds/logo the ISO will ship -------------
# scripts/branding-assets.sh renders them from website/assets/supermox-symbol.svg;
# iso-grub-branding.sh copies them over the live menu splash and the installed
# GRUB menu theme's art after make prepare.
grub_bg="$repo_root/build/branding/grub-background-1920x1080.png"
grub_logo="$repo_root/build/branding/logo-512.png"
if [ ! -s "$grub_bg" ] || [ ! -s "$grub_logo" ]; then
  step "GRUB art missing: scripts/branding-assets.sh renders $grub_bg and $grub_logo"
  run bash "$repo_root/scripts/branding-assets.sh"
  if [ "$dry_run" -eq 0 ]; then
    [ -s "$grub_bg" ] || fail "scripts/branding-assets.sh did not produce $grub_bg"
    [ -s "$grub_logo" ] || fail "scripts/branding-assets.sh did not produce $grub_logo"
  fi
fi

# --- post-prepare config (written to a script the human runs after make prepare) ---
post_prepare="$repo_root/build/iso-post-prepare.sh"
step "writing post-prepare config script: $post_prepare"
[ -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-no-systemd" ] \
  || fail "missing packaging/supermox-ve/etc/apt/preferences.d/supermox-no-systemd: the ISO copies it to /etc/apt/preferences.d/"
[ -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-origins" ] \
  || fail "missing packaging/supermox-ve/etc/apt/preferences.d/supermox-origins: the ISO copies it to /etc/apt/preferences.d/"
[ -f "$repo_root/packaging/supermox-ve/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units" ] \
  || fail "missing packaging/supermox-ve/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units: the ISO stages it before any package is installed"
if [ "$dry_run" -eq 1 ]; then
  printf 'DRY-RUN: write %s\n' "$post_prepare"
else
  cat > "$post_prepare" <<POSTPREPARE
#!/usr/bin/env bash
# SuperMox ISO post-prepare config: run after 'make prepare' and before 'lb build'.
# Generated by build-iso.sh --prepare-only.
set -euo pipefail
lb_dir="$lb_dir"
mkdir -p "$lb_dir/config/package-lists" "$lb_dir/config/archives" "$lb_dir/config/includes.chroot/etc/supermox"
printf 'supermox-ve\\nsupermox-tmpfiles\\n' >> "$lb_dir/config/package-lists/spaced.list.chroot"
# ZERO systemd: Spaced bootstraps and installs systemd-standalone-sysusers and
# systemd-standalone-tmpfiles. SuperMox uses opensysusers (Devuan's shell
# sysusers, as scripts/build-rootfs.sh does) and its own supermox-tmpfiles.
# debootstrap ignores apt pins, so its --include must change too, and a
# bootstrap cache made with the old --include must not be reused.
for f in "$lb_dir/auto/config" "$lb_dir/config/common"; do
  if [ -f "\$f" ]; then
    sed -i 's/--include=systemd-standalone-sysusers,systemd-standalone-tmpfiles/--include=opensysusers/' "\$f"
  fi
done
sed -i '/^systemd-standalone-\(sysusers\|tmpfiles\)\$/d' "$lb_dir/config/package-lists/spaced.list.chroot"
grep -qx opensysusers "$lb_dir/config/package-lists/spaced.list.chroot" \\
  || printf 'opensysusers\\n' >> "$lb_dir/config/package-lists/spaced.list.chroot"
if grep -rqs 'systemd-standalone' "$lb_dir/auto/config" "$lb_dir/config/common" "$lb_dir/config/package-lists/"; then
  printf 'ERROR: systemd-standalone still referenced in the live-build config\\n' >&2
  exit 1
fi
rm -rf "$lb_dir/cache/bootstrap"
cat > "$lb_dir/config/archives/proxmox.list.chroot" <<'LIST'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
deb http://download.proxmox.com/debian/devel trixie main
LIST
cp "$KEY_CACHE" "$lb_dir/config/archives/proxmox.key.chroot"
# The origin pins are the supermox-ve package's own conffile, so the ISO and
# the package agree by construction: live-build installs
# config/archives/<name>.pref.chroot as /etc/apt/preferences.d/<name>.pref for
# the chroot phase only and deletes it again before the binary stage, so the
# pin exists before supermox-ve can be installed at all, and the ISO that gets
# shipped carries exactly one copy of it: the package's conffile at
# /etc/apt/preferences.d/supermox-origins. Its -1 stanza names every binary
# package SuperMox rebuilds from patches/, so a missing staged .deb fails the
# build instead of silently pulling Proxmox's systemd build of that name. The
# same conffile also carries the libpve-network-* version hold (1.6.7) that keeps
# the ISO install and later upgrades off the libpve-access-control skew, so the
# ISO needs no pin of its own for it: copying the conffile brings the hold too.
cp -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-origins" "$lb_dir/config/archives/supermox-origins.pref.chroot"
# ZERO systemd: copy the very file supermox-ve ships as its conffile. live-build
# installs config/archives/<name>.pref.chroot as /etc/apt/preferences.d/<name>.pref
# for the chroot phase only and deletes it again before the binary stage, so the
# pin exists before supermox-ve can be installed at all, and the ISO that gets
# shipped carries exactly one copy of it: the package's conffile at
# /etc/apt/preferences.d/supermox-no-systemd.
cp -f "$repo_root/packaging/supermox-ve/etc/apt/preferences.d/supermox-no-systemd" "$lb_dir/config/archives/supermox-no-systemd.pref.chroot"
# The ISO pins four systemd-tainted names the package does not; they live in a
# file the package does not own, so installing supermox-ve cannot drop them.
cat > "$lb_dir/config/archives/supermox-iso-extra.pref.chroot" <<'PREF'
Explanation: additional systemd-tainted names, pinned on the ISO only.
Package: libsystemd-twitch-1 libsystemd-twitch2 systemd-notify systemd-loginctl
Pin: version *
Pin-Priority: -1
PREF
# ZERO systemd unit files: apt pins stop systemd PACKAGES from being installed, but
# stock Devuan packages that ARE installed (ssh, lightdm, avahi, nfs-common, lvm2,
# lxc, wpa_supplicant ...) unpack systemd unit files under lib/systemd, usr/lib/systemd
# and etc/systemd. scripts/build-rootfs.sh keeps them out of the rootfs with mmdebstrap
# --dpkgopt='path-exclude=...'; the ISO needs the same three excludes as a dpkg config
# file that is in place BEFORE any package is unpacked. live-build copies
# config/includes.chroot_before_packages/ into the chroot before the package-install
# stages (see /usr/lib/live/build/chroot: includes_before_packages runs before
# install-packages), so we stage the very file supermox-ve ships as its conffile.
# The ISO that ships then carries exactly one copy: the package's conffile.
mkdir -p "$lb_dir/config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d"
cp -f "$repo_root/packaging/supermox-ve/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units" "$lb_dir/config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units"
# Belt and braces: debootstrap unpacks its packages before includes.chroot_before_packages
# runs, so its copies of those unit files survive the dpkg config. This hook runs at
# chroot_hooks (after every package install) and removes exactly the three trees the
# path-excludes cover, printing what it removed. It never touches anything outside them.
mkdir -p "$lb_dir/config/hooks/normal"
cat > "$lb_dir/config/hooks/normal/9990-supermox-no-systemd-units.hook.chroot" <<'HOOK'
#!/bin/sh
# ZERO systemd: remove systemd unit files the debootstrap stage left under the three
# trees the supermox-no-systemd-units dpkg path-excludes cover. Runs after every
# package install, so packages installed after the dpkg config unpacked nothing here
# and only the bootstrap leftovers remain. Never deletes anything outside these trees.
set -eu
for tree in /lib/systemd /usr/lib/systemd /etc/systemd; do
  [ -d "\$tree" ] || continue
  find "\$tree" -mindepth 1 \( -type f -o -type l \) -print -delete
  find "\$tree" -depth -type d -empty -delete
done
HOOK
chmod 0755 "$lb_dir/config/hooks/normal/9990-supermox-no-systemd-units.hook.chroot"
# GRUB must say SuperMox, not Spaced Linux: the live ISO boot menu, the live
# menu theme (title and splash art), the installed system's GRUB menu name and
# the installed EFI boot entry name. The edits fail if a Spaced string moved,
# so an ISO can never ship the old name; kernel command lines are untouched.
bash "$repo_root/scripts/iso-grub-branding.sh" "$lb_dir" "$release" "$spaced_version" "$grub_bg" "$grub_logo"
cat > "$lb_dir/config/includes.chroot/etc/supermox/release" <<EOF
SUPERMOX_VERSION=$release
SUPERMOX_EDITION=pc
SUPERMOX_BASE=spaced-$spaced_version
EOF
printf 'OK: post-prepare config applied to %s\\n' "$lb_dir"
POSTPREPARE
  chmod +x "$post_prepare"
fi

# A failed lb build can leave proc/sys/devpts mounted inside the chroot, and
# 'make prepare' starts with rm -rf of the live-build tree. Unmount anything
# still mounted below the worktree first (deepest first), as root.
pre_clean="$repo_root/build/iso-pre-clean.sh"
if [ "$dry_run" -eq 1 ]; then
  printf 'DRY-RUN: write %s\n' "$pre_clean"
else
  cat > "$pre_clean" <<PRECLEAN
#!/usr/bin/env bash
set -euo pipefail
root="\$(readlink -f "$WORKTREE")"
findmnt -rn -o TARGET | awk -v r="\$root/" 'index(\$0, r) == 1' | sort -r | while IFS= read -r m; do
  printf 'unmounting leftover %s\\n' "\$m"
  umount -l "\$m"
done
PRECLEAN
  chmod +x "$pre_clean"
fi

# Fetch the Proxmox key now (no sudo needed, just a download).
if [ -s "$HOST_KEY" ]; then
  KEY_CACHE="$HOST_KEY"
elif [ ! -s "$KEY_CACHE" ]; then
  step "Proxmox archive key: fetch $KEY_URL -> $KEY_CACHE"
  run curl -fsSL -o "$KEY_CACHE" "$KEY_URL"
fi

# --- build ---------------------------------------------------------------
if [ "$prepare_only" -eq 1 ]; then
  step "prepare-only: worktree + debs staged; make prepare + config + lb build need sudo"
  printf '\nRun as root (one command):\n  sudo bash %s && cd %s && sudo make prepare && sudo bash %s && cd build/live-build && sudo env MKSQUASHFS_OPTIONS="%s" lb build\n' "$pre_clean" "$WORKTREE" "$post_prepare" "$MKSQUASHFS"
  printf 'Then collect and size-check the ISO:\n  bash %s/scripts/build-iso.sh --collect-only\n' "$repo_root"
  exit 0
fi

step "live-build: make prepare + config + lb build in $WORKTREE (needs root)"
if [ "$dry_run" -eq 1 ]; then
  printf 'DRY-RUN: sudo bash %s && cd %s && sudo make prepare && sudo bash %s && cd build/live-build && sudo env MKSQUASHFS_OPTIONS="%s" lb build\n' "$pre_clean" "$WORKTREE" "$post_prepare" "$MKSQUASHFS"
else
  (sudo bash "$pre_clean" && cd "$WORKTREE" && sudo make prepare && sudo bash "$post_prepare" && cd build/live-build && sudo env "MKSQUASHFS_OPTIONS=$MKSQUASHFS" lb build)
fi

step "apt sources: $lb_dir/config/archives/proxmox.list.chroot (download.proxmox.com pve + devel, trixie)"
step "Proxmox key: $lb_dir/config/archives/proxmox.key.chroot (live-build installs it into /etc/apt/trusted.gpg.d/)"
step "pins: $lb_dir/config/archives/supermox.pref.chroot (local 999 > Proxmox 100, swtpm+pve1 600)"
step "pins: $lb_dir/config/archives/supermox-no-systemd.pref.chroot (a copy of the supermox-ve conffile: systemd -1, chroot-only, the shipped ISO keeps the conffile) and supermox-iso-extra.pref.chroot (extra systemd names -1)"
step "branding: $lb_dir/config/includes.chroot/etc/supermox/release (Spaced's /etc/os-release is left as is)"
step "GRUB branding: $repo_root/scripts/iso-grub-branding.sh renames the live menu, the live menu theme, the installed system's GRUB menu theme, etc/default/grub and the calamares bootloaderEntryName to SuperMox (art from build/branding/), and fails if any 'Spaced Linux' is left"
step "ZERO systemd units: $lb_dir/config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/supermox-no-systemd-units (a copy of the supermox-ve conffile: dpkg path-exclude for lib/systemd, usr/lib/systemd, etc/systemd, staged before any package installs)"
step "ZERO systemd units: $lb_dir/config/hooks/normal/9990-supermox-no-systemd-units.hook.chroot (removes the unit files the debootstrap stage left under those three trees, prints them, touches nothing else)"
collect_iso
