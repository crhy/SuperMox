#!/usr/bin/env bash
# f262: move a deployed SuperMox checkout to a newer checkout WITHOUT an uninstall.
#
# This is install-checkout's (f253, scripts/install-checkout.sh) update half,
# beside its removal half uninstall-checkout (f259, scripts/uninstall-checkout.sh).
# install-checkout deploys the checkout to the deploy dir (default /srv/supermox,
# the path cron/supermox-monthly-build runs) and installs every cron/* file into
# the cron dir (default /etc/cron.d). Nothing updates a deployment in place: the
# only way to move /srv/supermox to a newer checkout was uninstall + install,
# which pulls the cron files out from under the running jobs between the two
# steps. This syncs the deployed tree to the current checkout and tops the cron
# files up, never removing one:
#
#   deploy dir  default /srv/supermox, overridden by the first argument or DEPLOY_DIR
#   cron dir    default /etc/cron.d,   overridden by --cron-dir
#
# Safety contract, inherited from uninstall-checkout:
#   * the deploy dir is touched ONLY when it IS a SuperMox deploy, that is it
#     contains scripts/monthly-build.sh; a missing or foreign deploy dir is
#     refused with a reason telling the user to run install-checkout
#   * a cron.d file is touched ONLY when it is missing (then it is reinstalled
#     with the same install line as always: install -m 0644); a file that
#     matches the shipped cron/* is left alone, and one that differs gets a
#     printed SKIP reason and stays: update never silently overwrites an
#     operator's hand-edited crontab
#   * the deployed tree is synced with install-checkout's copy rule (every
#     top-level entry except the git metadata and the git-ignored build/
#     scratch, via cp -a) plus stale cleanup: deployed entries that no longer
#     exist in the checkout are removed, so the deploy dir ends byte-identical
#     to what install-checkout would have produced
#
# --destdir PREFIX prefixes both targets (a test runs this as a normal user, no
# sudo: everything is written under PREFIX), --dry-run prints every action and
# touches nothing. Everything here is plain cp + install + cron; no service
# manager, no timer: SuperMox ships crontab files (AGENTS.md: sysvinit + cron).
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

# The deploy dir must be a SuperMox deploy before anything touches it:
# uninstall-checkout's rule. A missing or foreign deploy dir is refused with a
# reason - there is nothing here to update in place.
if [ ! -d "$target_deploy" ]; then
  printf 'ERROR: no deploy dir at %s: run install-checkout first\n' "$target_deploy" >&2
  exit 1
fi
if [ ! -f "$target_deploy/scripts/monthly-build.sh" ]; then
  printf 'ERROR: %s is not a SuperMox deploy (no scripts/monthly-build.sh): run install-checkout first\n' \
    "$target_deploy" >&2
  exit 1
fi

# The copy rule and the stale pass both work on top-level entries: the
# checkout's, except the git metadata and the git-ignored build scratch.
top_entries=()
top_bases=()
while IFS= read -r -d '' entry; do
  base="${entry#"$repo_root"/}"
  case "$base" in
    .git | build) continue ;;
  esac
  top_entries+=("$entry")
  top_bases+=("$base")
done < <(find "$repo_root" -mindepth 1 -maxdepth 1 -print0 | sort -z)

# Deployed top-level entries the checkout no longer carries (and the git and
# build entries install-checkout never deploys): the stale cleanup.
stale_entries=()
while IFS= read -r -d '' entry; do
  base="${entry#"$target_deploy"/}"
  case "$base" in
    .git | build) continue ;;
  esac
  known=0
  for want in "${top_bases[@]}"; do
    if [ "$want" = "$base" ]; then
      known=1
      break
    fi
  done
  if [ "$known" -eq 0 ]; then
    stale_entries+=("$entry")
  fi
done < <(find "$target_deploy" -mindepth 1 -maxdepth 1 -print0 | sort -z)

if [ "$dry" -eq 1 ]; then
  for entry in "${stale_entries[@]}"; do
    printf 'DRY-RUN deploy: remove stale %s (not in %s)\n' "$entry" "$repo_root"
  done
  for entry in "${top_entries[@]}"; do
    base="${entry#"$repo_root"/}"
    if [ -e "$target_deploy/$base" ]; then
      printf 'DRY-RUN deploy: sync %s (replaced from checkout)\n' "$target_deploy/$base"
    else
      printf 'DRY-RUN deploy: restore %s (missing from the deploy)\n' "$target_deploy/$base"
    fi
  done
  for name in "${cron_files[@]}"; do
    target="$target_cron/$name"
    if [ ! -e "$target" ]; then
      printf 'DRY-RUN cron: install -m 0644 cron/%s %s/%s\n' "$name" "$target_cron" "$name"
    elif cron_matches "$repo_root/cron/$name" "$target"; then
      printf 'DRY-RUN cron: %s matches shipped cron/%s, nothing to do\n' "$target" "$name"
    else
      printf 'DRY-RUN cron: SKIP %s (does not match shipped cron/%s)\n' "$target" "$name"
    fi
  done
  printf 'DRY-RUN %s: nothing written\n' "${0##*/}"
  exit 0
fi

# Stale first: deployed entries the current checkout no longer carries.
for entry in "${stale_entries[@]}"; do
  rm -rf "$entry"
  printf 'removed stale %s (not in the checkout)\n' "$entry"
done

# The copy rule, exactly as install-checkout deploys it: every top-level entry
# except .git and build/, via cp -a. Replacing each entry whole is what makes
# the tree end byte-identical to a fresh install-checkout deploy (no stale
# files inside deployed directories either); a file the deploy lost is restored.
for entry in "${top_entries[@]}"; do
  base="${entry#"$repo_root"/}"
  if [ -e "$target_deploy/$base" ]; then
    printf 'synced %s (replaced from checkout)\n' "$target_deploy/$base"
  else
    printf 'restored %s (missing from the deploy)\n' "$target_deploy/$base"
  fi
  rm -rf "${target_deploy:?}/$base"
  cp -a "$entry" "$target_deploy/"
done
printf 'deploy tree updated: %s -> %s\n' "$repo_root" "$target_deploy"

# The cron jobs, with the same filename and install line as always:
# install -m 0644 cron/<file> <cron dir>/<file>. A file that is missing is
# reinstalled; one that differs from the shipped file is the operator's and
# stays, with the reason printed.
mkdir -p "$target_cron"
for name in "${cron_files[@]}"; do
  target="$target_cron/$name"
  if [ ! -e "$target" ]; then
    install -m 0644 "$repo_root/cron/$name" "$target_cron/$name"
    printf 'installed cron file %s -> %s/%s\n' "$name" "$target_cron" "$name"
  elif cron_matches "$repo_root/cron/$name" "$target"; then
    printf 'cron file %s matches shipped cron/%s, left alone\n' "$target" "$name"
  else
    printf 'SKIP %s: %s does not match shipped cron/%s (operator cron file?)\n' \
      "$name" "$target" "$name"
  fi
done

printf 'update-checkout: deploy %s synced to the checkout, cron files in %s\n' "$target_deploy" "$target_cron"
