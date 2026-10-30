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
LAWNCHAIR_VERSION="1.2.0.1884"
LAWNCHAIR_URL="https://github.com/LawnchairLauncher/lawnchair/releases/download/${LAWNCHAIR_VERSION}/Lawnchair-${LAWNCHAIR_VERSION}.apk"
LAWNCHAIR_SHA256="47525c98210fe738414ec2d77d170a51f0ced555ed624499ae2ab9cf804d4865d"
LAWNCHAIR_PACKAGE="ch.deletescape.lawnchair"

variant="VANILLA"
url="$LAWNCHAIR_URL"
sha256="$LAWNCHAIR_SHA256"
home_app="$LAWNCHAIR_PACKAGE"
cache="/var/cache/supermox-android"
want_lawnchair=1
dry=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
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
    --dry-run) dry=1 ;;
    --variant) [ "$#" -ge 2 ] || die "--variant needs VANILLA or MAINLINE"
      variant="$2"
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
                              [--lawnchair-url URL --sha256 SUM]
                              [--home-app PACKAGE] [--cache DIR] [--no-lawnchair]

Prepares this node's Android layer: binder_linux, the Waydroid image,
the waydroid-container service, and the Lawnchair home screen.
EOF
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$variant" in
  VANILLA | MAINLINE) ;;
  *) die "--variant must be VANILLA or MAINLINE (got $variant)" ;;
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

# ---------------------------------------------------------------------------
step "2/5 Waydroid image ($variant)"
img_dir="/var/lib/waydroid/images"
if [ -f /var/lib/waydroid/waydroid.cfg ] && [ -f "$img_dir/system.img" ]; then
  printf '   image already initialized (%s)\n' "$img_dir/system.img"
else
  if [ "$dry" -eq 1 ]; then
    printf '   plan: waydroid init -s %s (downloads about 1 GB, the slow step)\n' "$variant"
  else
    printf '   downloading the image; this is the slow step, re-run if interrupted\n'
    run waydroid init -s "$variant"
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
