#!/usr/bin/env bash
# Prepare a SuperMox node for the Android layer: Waydroid container + Lawnchair.
#
# Idempotent — safe to re-run. --dry-run prints the whole plan and changes
# nothing; tests/test-android-setup.sh checks that plan.
#
# What this does, in order:
#   1. loads binder_linux (Waydroid bind-mounts the Android root with it)
#   2. downloads the Waydroid image (waydroid init, ~1 GB, the slow step)
#   3. enables and starts the waydroid-container service (sysvinit, no units)
#   4. fetches the pinned Lawnchair APK and checks its sha256
#   5. installs it into the Android layer and makes it the home app
#
# Steps 4-5 need the Android session running, which needs a Wayland compositor.
# On a headless amd64 VM that means weston; the script detects the missing
# session and prints the commands to run instead of failing.
set -euo pipefail

# Pinned launcher build. The package id is what the APK manifest declares
# (this fork still ships as ch.deletescape.lawnchair), and it is the value
# Waydroid stores in waydroid.active_apps to pick the home app.
# Lawnchair 15 (current line, still tagged beta upstream); 1.2.0.1884, GitHub's "latest", is from 2018 (Android 8 era).
# The checksum is the SHA-256 GitHub publishes for this asset, checked against a download on 2026-10-29.
LAWNCHAIR_VERSION="15.0.0-beta3.0"
LAWNCHAIR_URL="https://github.com/LawnchairLauncher/lawnchair/releases/download/v15.0.0-beta3.0/Lawnchair.15.0.0.Beta.3.0.apk"
LAWNCHAIR_SHA256="d4200d0985169fd79ba1bd225d653f2a2fe7b50aa07cb0d05ca64c7623f86059"
LAWNCHAIR_PACKAGE="ch.deletescape.lawnchair"

variant="VANILLA"
# Debian architecture name of this node; same vocabulary as SUPERMOX_ARCH in
# scripts/arch.sh. amd64 is only the first test target, so the Waydroid image
# has to be picked from the node, not assumed.
arch="$(dpkg --print-architecture)"
url="$LAWNCHAIR_URL"
sha256="$LAWNCHAIR_SHA256"
home_app="$LAWNCHAIR_PACKAGE"
cache="/var/cache/supermox-android"
want_lawnchair=1
dry=0

# Waydroid publishes two images only: x86_64 and aarch64. The Debian arch
# names of the nodes SuperMox runs on map onto those two; the rest of the
# vocabulary has no image and is refused before anything is downloaded.
WAYDROID_MIN_VERSION="1.6.3"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# scripts/arch.sh is the project's single architecture vocabulary, but it is a
# build-time library and is not shipped to the node, so the case and its exact
# error text are mirrored here; tests/test-android-setup.sh fails if the two
# wordings ever drift apart.
arch_known() {
  case "$1" in
    amd64 | arm64 | armhf | riscv64 | loong64) return 0 ;;
    *)
      printf 'ERROR: unknown SUPERMOX_ARCH=%s (known: amd64 arm64 armhf riscv64 loong64)\n' "$1" >&2
      return 2
      ;;
  esac
}

step() {
  printf '\n== %s\n' "$*"
}

waydroid_available() {
  local policy installed candidate
  policy="$(apt-cache policy waydroid 2>/dev/null)" ||
    die "apt-cache policy waydroid failed; cannot check waydroid availability on $arch nodes"
  installed="$(printf '%s\n' "$policy" | sed -n 's/^[[:space:]]*Installed:[[:space:]]*//p')"
  candidate="$(printf '%s\n' "$policy" | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p')"

  case "$candidate" in
    '' | '(none)')
      die "no waydroid candidate for $arch nodes (apt-cache policy waydroid reports no candidate); refusing to download the $image_arch image"
      ;;
  esac
  dpkg --compare-versions "$candidate" ge "$WAYDROID_MIN_VERSION" ||
    die "waydroid candidate $candidate on $arch nodes is older than $WAYDROID_MIN_VERSION (the floor supermox-android declares); refusing to download the $image_arch image"

  if [ "$installed" != '(none)' ] && [ -n "$installed" ]; then
    printf '   waydroid %s installed (candidate %s, need >= %s on %s nodes)\n' "$installed" "$candidate" "$WAYDROID_MIN_VERSION" "$arch"
  else
    printf '   waydroid not installed yet; candidate %s satisfies >= %s on %s nodes\n' "$candidate" "$WAYDROID_MIN_VERSION" "$arch"
  fi
}

run() {
  if [ "$dry" -eq 1 ]; then
    printf '   plan: %s\n' "$*"
  else
    "$@"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --variant) [ "$#" -ge 2 ] || die "--variant needs VANILLA or MAINLINE"
      variant="$2"
      shift 2 ;;
    --arch) [ "$#" -ge 2 ] || die "--arch needs a Debian architecture name (amd64 arm64 armhf riscv64 loong64)"
      arch="$2"
      shift 2 ;;
    --lawnchair-url) [ "$#" -ge 2 ] || die "--lawnchair-url needs a URL"
      url="$2"
      if [ "$url" != "$LAWNCHAIR_URL" ] && [ "$sha256" = "$LAWNCHAIR_SHA256" ]; then
        die "a custom --lawnchair-url needs --sha256 too (the pinned sum is for the pinned URL)"
      fi
      shift 2 ;;
    --sha256) [ "$#" -ge 2 ] || die "--sha256 needs a digest"
      sha256="$2"
      shift 2 ;;
    --home-app) [ "$#" -ge 2 ] || die "--home-app needs a package id"
      home_app="$2"
      shift 2 ;;
    --cache) [ "$#" -ge 2 ] || die "--cache needs a path"
      cache="$2"
      shift 2 ;;
    --no-lawnchair) want_lawnchair=0; shift ;;
    -h|--help)
      cat <<'EOF'
usage: supermox-android-setup [--dry-run] [--variant VANILLA|MAINLINE]
                              [--arch DEBIAN_ARCH]
                              [--lawnchair-url URL --sha256 SUM]
                              [--home-app PACKAGE] [--cache DIR] [--no-lawnchair]

Prepares this node's Android layer: binder_linux, the Waydroid image,
the waydroid-container service, and the Lawnchair home screen.

--arch takes a Debian architecture name (the same names SUPERMOX_ARCH takes
in scripts/arch.sh: amd64 arm64 armhf riscv64 loong64) and defaults to
dpkg --print-architecture. It selects the Waydroid image this node can run
(amd64 -> x86_64, arm64/armhf -> aarch64); architectures Waydroid has no
image for are refused, and the waydroid package is checked before the
image download starts.
EOF
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$variant" in
  VANILLA | MAINLINE) ;;
  *) die "--variant must be VANILLA or MAINLINE (got $variant)" ;;
esac

arch_known "$arch" || exit 2

# Debian arch -> the image tag waydroid init downloads. Waydroid ships x86_64
# and aarch64 images only, so riscv64 and loong64 nodes are refused here,
# before the root check and before any change to the system.
case "$arch" in
  amd64) image_arch="x86_64" ;;
  arm64 | armhf) image_arch="aarch64" ;;
  *) die "waydroid publishes no $arch image" ;;
esac

if [ "$dry" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "run as root: this installs an image, a service and an app"
fi

# ---------------------------------------------------------------------------
step "1/5 binder_linux (Waydroid bind mounts)"
if [ -e /dev/binder ]; then
  printf '   already present (/dev/binder)\n'
else
  if [ "$dry" -eq 0 ] && ! modprobe -n binder_linux 2>/dev/null; then
    die "no binder_linux module on this kernel; Waydroid cannot bind-mount without it"
  fi
  run modprobe binder_linux devices=binder,hwbinder,vndbinder
fi
# The package ships /etc/modules-load.d/waydroid.conf so the module (with
# its device arguments) comes back on the next boot; warn if it is not there.
if [ ! -f /etc/modules-load.d/waydroid.conf ]; then
  printf '   WARNING: /etc/modules-load.d/waydroid.conf missing; binder_linux will not load at next boot\n'
fi
# Android's init opens the binder API nodes as non-root UIDs (media.metrics,
# keystore2, idmap2d, ...). The kernel creates them 0600 (root-only), so those
# opens fail with EACCES and init aborts the container. Android proper and
# waydroid's own binderfs path expose them world-readable/writable; match that.
if [ "$dry" -eq 0 ]; then
  chmod 666 /dev/binder /dev/hwbinder /dev/vndbinder 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "2/5 Waydroid image ($variant, $image_arch)"
# The image is about 1 GB and useless on a node that cannot even install the
# waydroid package, which is the arm64 gap crhy/SuperMox#6 names. Check the
# package against the floor the supermox-android package declares
# (waydroid (>= 1.6.3)) before the download starts. apt-cache policy is
# read-only, so --dry-run prints the plan line and still runs the check: a
# node that cannot get the package must be told before the plan promises a
# download.
printf '   plan: apt-cache policy waydroid (waydroid >= %s must be installable on %s nodes)\n' "$WAYDROID_MIN_VERSION" "$arch"
waydroid_available
img_dir="/var/lib/waydroid/images"
cfg="/var/lib/waydroid/waydroid.cfg"
if [ -f "$cfg" ] && [ -f "$img_dir/system.img" ] && [ -f "$img_dir/vendor.img" ]; then
  printf '   image already initialized (%s)\n' "$img_dir/system.img"
else
  # waydroid's own "already initialized" check only looks at waydroid.cfg and
  # the rootfs directory, both of which a half-finished setup leaves behind,
  # so a plain init on a node with a cfg but no images prints "Already
  # initialized" and downloads nothing. --force is only added in that case.
  # -a is waydroid's image architecture tag (x86_64 / aarch64), not its
  # -b branch switch, which -s above already sets. The exact command is
  # printed in the plan, so a live arm64 node can correct the flag against
  # `waydroid init --help` without editing this script.
  init_cmd=(waydroid init -s "$variant" -a "$image_arch")
  if [ -f "$cfg" ]; then
    init_cmd+=(--force)
  fi
  if [ "$dry" -eq 1 ]; then
    printf '   plan: %s (downloads about 1 GB, the slow step)\n' "${init_cmd[*]}"
  else
    printf '   downloading the %s image; this is the slow step, re-run if interrupted\n' "$image_arch"
    run "${init_cmd[@]}"
  fi
fi

# ---------------------------------------------------------------------------
step "3/5 waydroid-container service"
if [ ! -f /etc/init.d/waydroid-container ] && [ "$dry" -eq 0 ]; then
  die "/etc/init.d/waydroid-container missing; install the supermox-android package first"
fi
if [ "$dry" -eq 1 ]; then
  printf '   plan: update-rc.d waydroid-container defaults (sysvinit, no unit files)\n'
else
  run update-rc.d waydroid-container defaults
  if /etc/init.d/waydroid-container status >/dev/null 2>&1; then
    printf '   service already running\n'
  else
    run /etc/init.d/waydroid-container start
  fi
fi

# ---------------------------------------------------------------------------
if [ "$want_lawnchair" -eq 1 ]; then
  step "4/5 Lawnchair APK (sha256 verified)"
  apk="$cache/Lawnchair-${LAWNCHAIR_VERSION}.apk"
  if [ "$dry" -eq 1 ]; then
    printf '   plan: mkdir -p %s\n' "$cache"
    printf '   plan: download %s -> %s\n' "$url" "$apk"
    printf '   plan: verify sha256 %s\n' "$sha256"
  else
    mkdir -p "$cache"
    if [ ! -f "$apk" ]; then
      printf '   downloading %s\n' "$url"
      curl -fL --retry 3 -o "$apk.part" "$url"
      mv "$apk.part" "$apk"
    fi
    printf '%s  %s\n' "$sha256" "$apk" | sha256sum -c - \
      || die "sha256 mismatch for $apk (refusing to install an unverified APK)"
  fi

  step "5/5 install Lawnchair and make it the home app"
  if [ "$dry" -eq 1 ]; then
    printf '   plan: waydroid app install %s\n' "$apk"
    printf '   plan: waydroid prop set waydroid.active_apps %s\n' "$home_app"
  else
    # waydroid app install / prop set talk to the Android platform service,
    # which only exists while a session runs, and a session needs a Wayland
    # compositor. Headless nodes get the commands printed instead.
    if waydroid status 2>/dev/null | grep -q "^Session:[[:space:]]*RUNNING"; then
      run waydroid app install "$apk"
      run waydroid prop set waydroid.active_apps "$home_app"
    else
      printf '   Android session is not running (no Wayland compositor here).\n'
      # The container's LXC config bind-mounts the Wayland socket into the
      # rootfs, so without a live compositor the container itself cannot start
      # either; seatd keeps weston's seat alive on a headless node.
      printf '   APK is staged at %s\n' "$apk"
      printf '   once a compositor is up, run:\n'
      printf '     waydroid start\n'
      printf '     waydroid app install %s\n' "$apk"
      printf '     waydroid prop set waydroid.active_apps %s\n' "$home_app"
    fi
  fi
else
  step "4/5 Lawnchair APK (skipped: --no-lawnchair)"
  step "5/5 home app (skipped: --no-lawnchair)"
fi

printf '\nAndroid layer ready. Boot state: container service enabled at runlevels 2-5.\n'
