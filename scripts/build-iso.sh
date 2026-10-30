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

SPACED_REPO="${SUPERMOX_SPACED_REPO:-/home/rhy/spaced-10.26}"
DEB_DIR="${SUPERMOX_DEB_DIR:-$repo_root/build/vm-data/debs}"
WORKTREE="$repo_root/build/spaced-iso"
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
    if [ "$arch_f" != all ] && [ "$arch_f" != "$SUPERMOX_ARCH" ]; then
      printf 'WARN: skipping %s (deb arch %s != target %s)\n' "$base" "$arch_f" "$SUPERMOX_ARCH" >&2
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

  step "stage ${#names[@]} SuperMox .deb from $dir (newest version per package, no -dbgsym, no -build-deps)"
  if [ "${#names[@]}" -eq 0 ]; then
    printf 'WARN: no SuperMox .debs found in %s\n' "$dir" >&2
    return 0
  fi
  run mkdir -p "$WORKTREE/build/local-packages"
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
}

[ -d "$SPACED_REPO/.git" ] || fail "Spaced checkout not found at $SPACED_REPO (set SUPERMOX_SPACED_REPO)"
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
stage_debs "$DEB_DIR"

step "stage the live-build tree: make -C $WORKTREE prepare (runs lb config; a few steps use sudo)"
run make -C "$WORKTREE" prepare

# --- package list, Proxmox sources, pins, branding --------------------------
step "package list: append supermox-ve and supermox-tmpfiles to $lb_dir/config/package-lists/spaced.list.chroot"
run mkdir -p "$lb_dir/config/package-lists"
append_block "$lb_dir/config/package-lists/spaced.list.chroot" "supermox-ve
supermox-tmpfiles"

step "apt sources: $lb_dir/config/archives/proxmox.list.chroot (download.proxmox.com pve + devel, trixie)"
run mkdir -p "$lb_dir/config/archives"
write_file "$lb_dir/config/archives/proxmox.list.chroot" <<'LIST'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
deb http://download.proxmox.com/debian/devel trixie main
LIST

if [ -s "$HOST_KEY" ]; then
  key_src="$HOST_KEY"
else
  key_src="$KEY_CACHE"
  if [ ! -s "$KEY_CACHE" ]; then
    step "Proxmox archive key: fetch $KEY_URL -> $KEY_CACHE"
    run curl -fsSL -o "$KEY_CACHE" "$KEY_URL"
  fi
  if [ "$dry_run" -ne 1 ] && [ ! -s "$key_src" ]; then
    fail "Proxmox archive key missing at $key_src (no network? fetch it manually)"
  fi
fi
step "Proxmox key: $lb_dir/config/archives/proxmox.key.chroot (live-build installs it into /etc/apt/trusted.gpg.d/)"
run cp "$key_src" "$lb_dir/config/archives/proxmox.key.chroot"

step "pins: $lb_dir/config/archives/supermox.pref.chroot (local 999 > Proxmox 100, swtpm+pve1 600, systemd -1)"
write_file "$lb_dir/config/archives/supermox.pref.chroot" <<'PREF'
Explanation: SuperMox ships its own rebuilt PVE stack; local .debs must win.
Package: *
Pin: origin ""
Pin-Priority: 999

Explanation: Proxmox's trixie pve and devel repositories fill in the rest.
Package: *
Pin: origin download.proxmox.com
Pin-Priority: 100

Explanation: qemu-server needs Proxmox's patched swtpm (0.10.2+pve1), not Devuan's.
Package: swtpm swtpm-libs swtpm-tools
Pin: origin download.proxmox.com
Pin-Priority: 600

Explanation: ZERO systemd. sysvinit-core and the standalone sysusers/tmpfiles
binaries installed at bootstrap stay; nothing may pull systemd in later.
Package: systemd systemd-sysv libsystemd0 libpam-systemd libsystemd-twitch-1 libsystemd-twitch2 systemd-notify systemd-loginctl
Pin: version *
Pin-Priority: -1
PREF

step "branding: $lb_dir/config/includes.chroot/etc/supermox/release (Spaced's /etc/os-release is left as is)"
run mkdir -p "$lb_dir/config/includes.chroot/etc/supermox"
write_file "$lb_dir/config/includes.chroot/etc/supermox/release" <<EOF
SUPERMOX_VERSION=$release
SUPERMOX_EDITION=pc
SUPERMOX_BASE=spaced-$spaced_version
EOF

# --- build ---------------------------------------------------------------
if [ "$prepare_only" -eq 1 ]; then
  step "prepare-only: live-build tree staged, lb build NOT run"
  printf '\nFinish the build as root:\n  cd %s && sudo env MKSQUASHFS_OPTIONS="%s" lb build\n' "$lb_dir" "$MKSQUASHFS"
  printf 'Then collect and size-check the ISO:\n  bash %s/scripts/build-iso.sh --collect-only\n' "$repo_root"
  exit 0
fi

step "live-build: lb build in $lb_dir (needs root)"
if [ "$dry_run" -eq 1 ]; then
  printf 'DRY-RUN: cd %s && sudo env MKSQUASHFS_OPTIONS="%s" lb build\n' "$lb_dir" "$MKSQUASHFS"
else
  (cd "$lb_dir" && sudo env "MKSQUASHFS_OPTIONS=$MKSQUASHFS" lb build)
fi
collect_iso
