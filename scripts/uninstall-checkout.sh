#!/usr/bin/env bash
# f259: take the SuperMox checkout and its cron jobs back off cleanly.
#
# This is f253's counterpart (scripts/install-checkout.sh). install-checkout
# deploys the checkout to the deploy dir (default /srv/supermox, the path
# cron/supermox-monthly-build runs) and installs every cron/* file into the
# cron dir (default /etc/cron.d). Nothing in the chain removes that deployment:
# once the supermox-monthly-build crontab is live, deleting /srv/supermox by
# hand leaves cron running a missing script every month and leaves stale cron
# files behind. This takes both back off, safely:
#
#   deploy dir  default /srv/supermox, overridden by the first argument or DEPLOY_DIR
#   cron dir    default /etc/cron.d,   overridden by --cron-dir
#
# Safety contract (cron/pve-daily-update and cron/supermox-monthly-build are
# the source of truth): a cron.d file is removed ONLY when its contents match
# the shipped file (byte-identical, or every shipped SuperMox line still
# present); an operator's unknown or edited cron file is never touched. The
# deploy dir is removed ONLY when it IS a SuperMox deploy, that is it contains
# scripts/monthly-build.sh; anything else is refused with a reason.
#
# --destdir PREFIX prefixes both targets (a test runs this as a normal user, no
# sudo: everything is written under PREFIX), --dry-run prints every action and
# touches nothing. Everything here is plain rm + cron; no service manager, no
# timer: SuperMox ships crontab files (AGENTS.md: sysvinit + cron only).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

deploy_dir="${DEPLOY_DIR:-/srv/supermox}"
cron_dir="/etc/cron.d"
destdir=""
dry=0
pos_given=0

usage() {
  printf 'usage: %s [DEPLOY-DIR] [--cron-dir DIR] [--destdir PREFIX] [--dry-run]\n' "${0##*/}" >&2
  printf 'defaults: DEPLOY-DIR %s (first argument or DEPLOY_DIR), cron dir %s\n' \
    "$deploy_dir" "$cron_dir" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cron-dir)
      if [ "$#" -lt 2 ]; then usage; exit 2; fi
      cron_dir="$2"
      shift 2
      ;;
    --destdir)
      if [ "$#" -lt 2 ]; then usage; exit 2; fi
      destdir="$2"
      shift 2
      ;;
    --dry-run)
      dry=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf 'ERROR: unknown option: %s\n' "$1" >&2
      usage
      exit 2
      ;;
    *)
      if [ "$pos_given" -eq 1 ]; then
        printf 'ERROR: deploy dir given twice: %s\n' "$1" >&2
        usage
        exit 2
      fi
      deploy_dir="$1"
      pos_given=1
      shift
      ;;
  esac
done

# The targets are absolute paths under an optional prefix; the prefix is the
# only way this runs unprivileged, and the only place a /srv-style default
# cannot be written.
case "$deploy_dir" in
  /*) ;;
  *)
    printf 'ERROR: deploy dir must be absolute: %s\n' "$deploy_dir" >&2
    exit 2
    ;;
esac
case "$cron_dir" in
  /*) ;;
  *)
    printf 'ERROR: cron dir must be absolute: %s\n' "$cron_dir" >&2
    exit 2
    ;;
esac

target_deploy="$destdir$deploy_dir"
target_cron="$destdir$cron_dir"

# The shipped cron files are the source of truth: iterate over the checkout's
# cron/*, not whatever happens to sit in the cron dir.
cron_files=()
while IFS= read -r -d '' entry; do
  cron_files+=("${entry#"$repo_root/cron/"}")
done < <(find "$repo_root/cron" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
if [ "${#cron_files[@]}" -eq 0 ]; then
  printf 'ERROR: no crontab files in %s/cron\n' "$repo_root" >&2
  exit 1
fi

# A cron.d file is SuperMox's only when it is byte-identical to the shipped
# cron/$1, or when every non-blank, non-comment line the shipped file carries
# (the crontab command lines) still appears verbatim in the installed file.
# Anything else - an operator file with a different command, a different
# schedule, or extra content - is unknown and left alone.
cron_matches() {
  local shipped="$1" target="$2"
  if cmp -s "$shipped" "$target"; then
    return 0
  fi
  local line trimmed found=0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      '#'*) continue ;;
    esac
    found=1
    if ! grep -qxF -- "$line" "$target"; then
      return 1
    fi
  done < "$shipped"
  # A shipped file with no real cron line matches only byte-identically.
  [ "$found" -eq 1 ]
}

if [ "$dry" -eq 1 ]; then
  for name in "${cron_files[@]}"; do
    target="$target_cron/$name"
    if [ ! -e "$target" ]; then
      printf 'DRY-RUN cron: no %s installed, nothing to remove\n' "$target"
    elif cron_matches "$repo_root/cron/$name" "$target"; then
      printf 'DRY-RUN cron: remove %s (matches shipped cron/%s)\n' "$target" "$name"
    else
      printf 'DRY-RUN cron: SKIP %s (does not match shipped cron/%s)\n' "$target" "$name"
    fi
  done
  if [ -f "$target_deploy/scripts/monthly-build.sh" ]; then
    printf 'DRY-RUN deploy: remove %s (SuperMox deploy: scripts/monthly-build.sh present)\n' "$target_deploy"
  elif [ -e "$target_deploy" ]; then
    printf 'DRY-RUN deploy: SKIP %s (not a SuperMox deploy: no scripts/monthly-build.sh)\n' "$target_deploy"
  else
    printf 'DRY-RUN deploy: no %s, nothing to remove\n' "$target_deploy"
  fi
  printf 'DRY-RUN %s: nothing written\n' "${0##*/}"
  exit 0
fi

# The cron jobs: remove only the files that are still the shipped SuperMox ones.
for name in "${cron_files[@]}"; do
  target="$target_cron/$name"
  if [ ! -e "$target" ]; then
    printf 'SKIP %s: no %s installed\n' "$name" "$target"
    continue
  fi
  if cron_matches "$repo_root/cron/$name" "$target"; then
    rm -f "$target"
    printf 'removed cron file %s (matched shipped cron/%s)\n' "$target" "$name"
  else
    printf 'SKIP %s: %s does not match shipped cron/%s (operator cron file?)\n' \
      "$name" "$target" "$name"
  fi
done

# The deploy dir: only when it really is a SuperMox deploy.
if [ -f "$target_deploy/scripts/monthly-build.sh" ]; then
  rm -rf "$target_deploy"
  printf 'removed deploy dir %s (SuperMox deploy: scripts/monthly-build.sh present)\n' "$target_deploy"
elif [ -e "$target_deploy" ]; then
  printf 'SKIP deploy dir: %s is not a SuperMox deploy (no scripts/monthly-build.sh), refusing to remove\n' \
    "$target_deploy"
else
  printf 'SKIP deploy dir: no %s installed\n' "$target_deploy"
fi

printf 'uninstall-checkout: cron files checked in %s, deploy dir %s\n' "$target_cron" "$target_deploy"
