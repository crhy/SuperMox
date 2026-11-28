#!/usr/bin/env bash
# f253: deploy the SuperMox checkout and install its cron jobs.
#
# The crontab file cron/supermox-monthly-build runs
# /srv/supermox/scripts/monthly-build.sh, so the checkout has to BE at
# /srv/supermox before that job can do anything. This is the installer that
# puts it there and carries cron/* into the cron dir:
#
#   deploy dir  default /srv/supermox, overridden by the first argument or DEPLOY_DIR
#   cron dir    default /etc/cron.d,   overridden by --cron-dir
#
# Cron files land with the same filename and the same install line
# convention as cron/pve-daily-update always used:
#   install -m 0644 cron/<file> /etc/cron.d/<file>
#
# --destdir PREFIX prefixes both targets (a test can run this as a normal
# user, no sudo needed: everything is written under PREFIX), --dry-run
# prints every action and touches nothing. Everything here is plain copy +
# install + cron; no service manager, no timer: SuperMox ships crontab files.
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

cron_files=()
while IFS= read -r -d '' entry; do
  cron_files+=("${entry#"$repo_root/cron/"}")
done < <(find "$repo_root/cron" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
if [ "${#cron_files[@]}" -eq 0 ]; then
  printf 'ERROR: no crontab files in %s/cron\n' "$repo_root" >&2
  exit 1
fi

if [ "$dry" -eq 1 ]; then
  printf 'DRY-RUN deploy: %s -> %s (git and build scratch stay behind)\n' "$repo_root" "$target_deploy"
  for name in "${cron_files[@]}"; do
    printf 'DRY-RUN cron: install -m 0644 cron/%s %s/%s\n' "$name" "$target_cron" "$name"
  done
  printf 'DRY-RUN %s: nothing written\n' "${0##*/}"
  exit 0
fi

# The checkout copy: every top-level entry except the git metadata and the
# git-ignored build/ scratch, preserving times and permissions.
mkdir -p "$target_deploy"
while IFS= read -r -d '' entry; do
  base="${entry#"$repo_root"/}"
  case "$base" in
    .git | build) continue ;;
  esac
  cp -a "$entry" "$target_deploy/"
done < <(find "$repo_root" -mindepth 1 -maxdepth 1 -print0)
printf 'deployed %s -> %s\n' "$repo_root" "$target_deploy"

# The cron jobs, with the same filename and install line as always:
# install -m 0644 cron/<file> <cron dir>/<file>
mkdir -p "$target_cron"
for name in "${cron_files[@]}"; do
  install -m 0644 "$repo_root/cron/$name" "$target_cron/$name"
  printf 'installed cron file %s -> %s/%s\n' "$name" "$target_cron" "$name"
done

printf 'install-checkout: checkout at %s, cron files in %s\n' "$target_deploy" "$target_cron"
