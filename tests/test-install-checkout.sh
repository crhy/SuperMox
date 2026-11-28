#!/usr/bin/env bash
# f253: scripts/install-checkout.sh deploys the checkout to the deploy dir the
# crontab files name (/srv/supermox by default) and installs every cron/* file
# into the cron dir (/etc/cron.d) under the same name.
#
# Runs offline as a normal user: every real write goes under a --destdir
# prefix inside build/, no sudo anywhere. --dry-run is checked first: it must
# report the deploy and the cron actions but touch nothing. The deployed cron
# files must still be 5-field crontab form, checked the way
# tests/test-init-scripts.sh checks cron/pve-daily-update.
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/install-checkout.sh"
root="build/test-install-checkout"
fail=0

# The default deploy dir must be the path the monthly crontab runs.
crontab_ref="cron/supermox-monthly-build"

if [ ! -f "$script" ]; then
  echo "FAIL: $script does not exist"
  exit 1
fi
if ! bash -n "$script"; then
  echo "FAIL: $script is not valid bash syntax"
  exit 1
fi
if ! shellcheck -S warning "$script"; then
  echo "FAIL: shellcheck -S warning $script"
  exit 1
fi

# SuperMox ships crontab files only: the installer may not name a service
# manager, a unit or an anacron job anywhere in it.
if grep -qiE 'systemd|anacron|\.timer' "$script"; then
  echo "FAIL: $script names a service manager, unit or anacron job:"
  grep -inE 'systemd|anacron|\.timer' "$script"
  fail=1
fi
# Same rule tests/test-local-env.sh puts on every file in scripts/.
if grep -qE '/media/|/home/' "$script"; then
  echo "FAIL: $script contains a machine-specific path"
  fail=1
fi

# The installer default and the crontab command must name the same place.
if ! grep -qF -- '/srv/supermox/scripts/monthly-build.sh' "$crontab_ref"; then
  echo "FAIL: $crontab_ref does not run /srv/supermox/scripts/monthly-build.sh"
  fail=1
fi
if ! grep -qF -- '/srv/supermox' "$script"; then
  echo "FAIL: $script does not default to the /srv/supermox deploy dir"
  fail=1
fi

# DEPLOY_DIR must not leak in from the caller.
unset DEPLOY_DIR

rm -rf "$root"
mkdir -p "$root"

cron_names=()
while IFS= read -r -d '' f; do
  cron_names+=("${f#cron/}")
done < <(find cron -mindepth 1 -maxdepth 1 -type f -print0)
if [ "${#cron_names[@]}" -eq 0 ]; then
  echo "FAIL: no crontab files in cron/ to test"
  exit 1
fi

run_out() {
  rc=0
  out="$(bash "$script" "$@" 2>&1)" || rc=$?
}

assert_rc() {
  if [ "${rc:-0}" -ne 0 ]; then
    echo "FAIL: $script $1 exited $rc"
    printf '%s\n' "${out:-}"
    fail=1
  fi
}

# 1. --dry-run reports the deploy and every cron action, touches nothing.
dry="$root/dry"
run_out --dry-run --destdir "$dry"
assert_rc "--dry-run --destdir $dry"
if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN deploy: $PWD -> $dry/srv/supermox"; then
  echo "FAIL: --dry-run did not report the deploy to $dry/srv/supermox"
  printf '%s\n' "$out"
  fail=1
fi
for name in "${cron_names[@]}"; do
  if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN cron: install -m 0644 cron/$name $dry/etc/cron.d/$name"; then
    echo "FAIL: --dry-run did not report installing cron/$name to $dry/etc/cron.d/$name"
    printf '%s\n' "$out"
    fail=1
  fi
done
if [ -e "$dry" ]; then
  echo "FAIL: --dry-run wrote under $dry"
  printf '%s\n' "$(find "$dry" 2>/dev/null)"
  fail=1
fi

# 2. A real run with --destdir: the checkout lands under <dest>/srv/supermox
#    and every cron file under <dest>/etc/cron.d with the same name.
run="$root/run"
run_out --destdir "$run"
assert_rc "--destdir $run"
for marker in AGENTS.md scripts/monthly-build.sh cron/pve-daily-update README.md; do
  if [ ! -f "$run/srv/supermox/$marker" ]; then
    echo "FAIL: deployed checkout is missing $marker"
    fail=1
  fi
done
if [ -e "$run/srv/supermox/.git" ] || [ -e "$run/srv/supermox/build" ]; then
  echo "FAIL: deployed checkout carries git metadata or build scratch"
  fail=1
fi
for name in "${cron_names[@]}"; do
  dest="$run/etc/cron.d/$name"
  if [ ! -f "$dest" ]; then
    echo "FAIL: cron/$name was not installed as $dest"
    fail=1
    continue
  fi
  if [ "$(stat -c '%a' "$dest")" != "644" ]; then
    echo "FAIL: $dest is not mode 0644 (the pve-daily-update install line convention)"
    fail=1
  fi
  if ! cmp -s "cron/$name" "$dest"; then
    echo "FAIL: $dest does not match cron/$name"
    fail=1
  fi
done

# 3. The installed cron files are 5-field crontab form, checked the way
#    tests/test-init-scripts.sh checks cron/pve-daily-update.
for name in "${cron_names[@]}"; do
  cron="$run/etc/cron.d/$name"
  [ -f "$cron" ] || continue
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    trimmed=${line#"${line%%[![:space:]]*}"}
    [ -z "$trimmed" ] && continue
    case "$trimmed" in
      '#'*) continue ;;
    esac
    IFS=' ' read -r f1 f2 f3 f4 f5 user cmd <<< "$trimmed"
    if [ -z "$user" ] || [ -z "$cmd" ]; then
      echo "FAIL: $cron line $lineno (missing time/user/command fields)"
      fail=1
      continue
    fi
    for field in "$f1" "$f2" "$f3" "$f4" "$f5"; do
      if ! printf '%s' "$field" | grep -qE '^[0-9*,/-]+$'; then
        echo "FAIL: $cron line $lineno (field '$field' is not a time field)"
        fail=1
      fi
    done
    if [ "$user" != "root" ]; then
      echo "FAIL: $cron line $lineno (user field is '$user', expected root)"
      fail=1
    fi
  done < "$cron"
done

# 4. The deployed monthly crontab can run the deployed checkout: the script
#    its command field names exists under the deploy dir installed beside it.
if [ -f "$run/etc/cron.d/supermox-monthly-build" ]; then
  cmd_path="$(grep -vE '^[[:space:]]*(#|$)' "$run/etc/cron.d/supermox-monthly-build" |
    grep -oE '/[^[:space:];]*monthly-build\.sh' | head -1)"
  if [ "$cmd_path" != "/srv/supermox/scripts/monthly-build.sh" ]; then
    echo "FAIL: the deployed crontab command is not /srv/supermox/scripts/monthly-build.sh (got '$cmd_path')"
    fail=1
  elif [ ! -f "$run$cmd_path" ]; then
    echo "FAIL: deployed crontab runs $cmd_path but the checkout is not deployed at $run$cmd_path"
    fail=1
  fi
fi

# 5. The first argument overrides the deploy dir, --cron-dir the cron dir.
over="$root/over"
run_out /opt/supermox-edge --cron-dir /etc/cron.d-test --destdir "$over"
assert_rc "/opt/supermox-edge --cron-dir /etc/cron.d-test --destdir $over"
if [ ! -f "$over/opt/supermox-edge/scripts/monthly-build.sh" ]; then
  echo "FAIL: the first argument did not set the deploy dir"
  fail=1
fi
for name in "${cron_names[@]}"; do
  if [ ! -f "$over/etc/cron.d-test/$name" ]; then
    echo "FAIL: --cron-dir did not install cron/$name to $over/etc/cron.d-test/$name"
    fail=1
  fi
done
if [ -e "$over/etc/cron.d" ]; then
  echo "FAIL: --cron-dir still wrote the default cron dir"
  fail=1
fi

# 6. DEPLOY_DIR overrides the default without an argument.
envd="$root/envd"
rc=0
out="$(DEPLOY_DIR=/srv/supermox-next bash "$script" --destdir "$envd" 2>&1)" || rc=$?
assert_rc "DEPLOY_DIR=/srv/supermox-next --destdir $envd"
if [ ! -f "$envd/srv/supermox-next/scripts/monthly-build.sh" ]; then
  echo "FAIL: DEPLOY_DIR did not set the deploy dir"
  printf '%s\n' "$out"
  fail=1
fi

# 7. Relative paths are refused: a prefix plus a relative target would land
#    inside the checkout itself.
run_out srv-relative
if [ "$rc" -eq 0 ]; then
  echo "FAIL: a relative deploy dir was accepted"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -qF -- "deploy dir must be absolute"; then
  echo "FAIL: a relative deploy dir was not refused by name"
  printf '%s\n' "$out"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: install-checkout.sh dry-runs reporting every action without writing, deploys the checkout under <destdir>/srv/supermox (first argument, DEPLOY_DIR and --destdir honoured, git and build scratch left behind), installs every cron file to <destdir>/etc/cron.d with install -m 0644 under the same name, keeps the 5-field root-user crontab form and the /srv/supermox command matched to the deploy dir, and refuses relative targets - no service manager, unit or anacron job anywhere in it"
