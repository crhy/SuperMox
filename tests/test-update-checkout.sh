#!/usr/bin/env bash
# f262: scripts/update-checkout.sh is install-checkout's update half (beside
# uninstall-checkout's removal half). install-checkout --destdir P, then
# update-checkout --destdir P moves the deployed checkout to the current one
# WITHOUT an uninstall: deleted files are restored, deployed entries the
# checkout no longer carries are removed (stale cleanup), the deploy ends
# byte-identical to a fresh install-checkout deploy, and the cron files are
# never pulled out from under the running jobs: a matching cron file is left
# alone, a missing one is reinstalled, and a hand-edited one survives with a
# printed SKIP reason. A missing or non-SuperMox deploy dir is refused with a
# reason, and --dry-run prints every action and touches nothing.
#
# Runs offline as a normal user: every real write goes under a --destdir
# prefix inside build/, no sudo anywhere. install-checkout.sh is used to build
# the trees this updates, so the cron files it drops are byte-identical to cron/*.
set -euo pipefail

cd "$(dirname "$0")/.."

install_script="scripts/install-checkout.sh"
script="scripts/update-checkout.sh"
root="build/test-update-checkout"
fail=0

if [ ! -f "$script" ]; then
  echo "FAIL: $script does not exist"
  exit 1
fi
if [ ! -f "$install_script" ]; then
  echo "FAIL: $install_script does not exist (needed to build the trees under test)"
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

# SuperMox ships crontab files only: the updater may not name a service
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

# The updater default and the crontab command must name the same place.
if ! grep -qF -- '/srv/supermox' "$script"; then
  echo "FAIL: $script does not default to the /srv/supermox deploy dir"
  fail=1
fi
# It is install-checkout's update half: it must say so.
if ! grep -qF -- 'install-checkout' "$script"; then
  echo "FAIL: $script does not say it is install-checkout's update half"
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

out=""
rc=0

run_out() {
  rc=0
  out="$(bash "$script" "$@" 2>&1)" || rc=$?
}

assert_rc() {
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $script $1 exited $rc"
    printf '%s\n' "$out"
    fail=1
  fi
}

install_out() {
  if ! out="$(bash "$install_script" "$@" 2>&1)"; then
    echo "FAIL: $install_script $* exited non-zero"
    printf '%s\n' "$out"
    fail=1
    return 1
  fi
  return 0
}

# 1. --dry-run on an install the test broke (a deployed file deleted, a stale
#    file and directory dropped in) reports restoring, syncing and removing
#    every one of them, reports the cron state, and touches nothing.
dry="$root/dry"
if install_out --destdir "$dry"; then
  rm "$dry/srv/supermox/README.md"
  rm "$dry/srv/supermox/init.d/pveproxy"
  printf 'stale from an older checkout\n' > "$dry/srv/supermox/stale-old-file.txt"
  mkdir -p "$dry/srv/supermox/stale-old-dir"
  printf 'stale too\n' > "$dry/srv/supermox/stale-old-dir/inner.txt"

  run_out --dry-run --destdir "$dry"
  assert_rc "--dry-run --destdir $dry"
  if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN deploy: restore $dry/srv/supermox/README.md"; then
    echo "FAIL: --dry-run did not report restoring the deleted $dry/srv/supermox/README.md"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN deploy: sync $dry/srv/supermox/init.d (replaced from checkout)"; then
    echo "FAIL: --dry-run did not report replacing $dry/srv/supermox/init.d (the deleted file is inside it)"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN deploy: remove stale $dry/srv/supermox/stale-old-file.txt"; then
    echo "FAIL: --dry-run did not report removing the stale $dry/srv/supermox/stale-old-file.txt"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN deploy: remove stale $dry/srv/supermox/stale-old-dir"; then
    echo "FAIL: --dry-run did not report removing the stale $dry/srv/supermox/stale-old-dir"
    printf '%s\n' "$out"
    fail=1
  fi
  for name in "${cron_names[@]}"; do
    if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN cron: $dry/etc/cron.d/$name matches shipped cron/$name"; then
      echo "FAIL: --dry-run did not report the installed cron file $dry/etc/cron.d/$name matching the shipped one"
      printf '%s\n' "$out"
      fail=1
    fi
  done
  # nothing was written away: the tree is exactly as the test left it
  if [ -e "$dry/srv/supermox/README.md" ] || [ -e "$dry/srv/supermox/init.d/pveproxy" ]; then
    echo "FAIL: --dry-run restored a deleted deployed file"
    fail=1
  fi
  if [ ! -f "$dry/srv/supermox/stale-old-file.txt" ] || [ ! -f "$dry/srv/supermox/stale-old-dir/inner.txt" ]; then
    echo "FAIL: --dry-run removed a stale deployed entry"
    fail=1
  fi
  for name in "${cron_names[@]}"; do
    if [ ! -f "$dry/etc/cron.d/$name" ] || ! cmp -s "cron/$name" "$dry/etc/cron.d/$name"; then
      echo "FAIL: --dry-run touched the cron file $dry/etc/cron.d/$name"
      fail=1
    fi
  done
fi

# 2. install-checkout --destdir P, break the deploy, then update-checkout
#    --destdir P: the deleted files are restored, the stale entries are gone,
#    the deploy ends byte-identical to a fresh install-checkout deploy, and
#    every cron file is verified intact.
run="$root/run"
if install_out --destdir "$run"; then
  rm "$run/srv/supermox/README.md"
  rm "$run/srv/supermox/init.d/pveproxy"
  printf 'stale from an older checkout\n' > "$run/srv/supermox/stale-old-file.txt"
  mkdir -p "$run/srv/supermox/stale-old-dir"
  printf 'stale too\n' > "$run/srv/supermox/stale-old-dir/inner.txt"
  # an inner stale entry too: install-checkout would not have produced it
  printf 'stale inside a synced dir\n' > "$run/srv/supermox/init.d/stale-old-inner"

  run_out --destdir "$run"
  assert_rc "--destdir $run"
  if ! printf '%s\n' "$out" | grep -qF -- "restored $run/srv/supermox/README.md"; then
    echo "FAIL: update did not report restoring the deleted $run/srv/supermox/README.md"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "removed stale $run/srv/supermox/stale-old-file.txt"; then
    echo "FAIL: update did not report removing the stale $run/srv/supermox/stale-old-file.txt"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "synced $run/srv/supermox/init.d (replaced from checkout)"; then
    echo "FAIL: update did not report replacing $run/srv/supermox/init.d (the deleted file is inside it)"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! cmp -s README.md "$run/srv/supermox/README.md"; then
    echo "FAIL: update did not restore the deleted $run/srv/supermox/README.md"
    fail=1
  fi
  if ! cmp -s init.d/pveproxy "$run/srv/supermox/init.d/pveproxy"; then
    echo "FAIL: update did not restore the deleted $run/srv/supermox/init.d/pveproxy"
    fail=1
  fi
  for stale in stale-old-file.txt stale-old-dir/inner.txt stale-old-dir init.d/stale-old-inner; do
    if [ -e "$run/srv/supermox/$stale" ]; then
      echo "FAIL: update left the stale deployed entry $run/srv/supermox/$stale behind"
      fail=1
    fi
  done
  # byte-identical to a fresh install-checkout deploy
  compare="$root/compare"
  if install_out --destdir "$compare"; then
    diff_out="$(diff -r "$compare/srv/supermox" "$run/srv/supermox" 2>&1)" || rc=$?
    if [ -n "$diff_out" ]; then
      echo "FAIL: the updated deploy does not match a fresh install-checkout deploy"
      printf '%s\n' "$diff_out"
      fail=1
    fi
    if [ "${rc:-0}" -ne 0 ]; then
      echo "FAIL: diff -r between the updated and fresh deploys exited $rc"
      fail=1
    fi
    rc=0
  fi
  # cron files verified intact
  for name in "${cron_names[@]}"; do
    dest="$run/etc/cron.d/$name"
    if [ ! -f "$dest" ]; then
      echo "FAIL: update removed the cron file $dest"
      fail=1
      continue
    fi
    if [ "$(stat -c '%a' "$dest")" != "644" ]; then
      echo "FAIL: $dest is not mode 0644 after update"
      fail=1
    fi
    if ! cmp -s "cron/$name" "$dest"; then
      echo "FAIL: update changed the cron file $dest away from cron/$name"
      fail=1
    fi
  done
fi

# 3. A hand-edited cron file under a shipped name survives with a SKIP reason,
#    an operator's unknown cron file stays untouched, and a missing cron file
#    is reinstalled with the pve-daily-update install line convention.
keep="$root/keep"
if install_out --destdir "$keep"; then
  op="$keep/etc/cron.d/operator-thing"
  printf '0 2 * * * root echo operator-handwritten\n' > "$op"
  op_before="$(cat "$op")"
  edited="$keep/etc/cron.d/pve-daily-update"
  printf '0 4 * * * root /usr/bin/some-operator-command\n' > "$edited"
  edited_before="$(cat "$edited")"
  rm "$keep/etc/cron.d/supermox-monthly-build"

  run_out --destdir "$keep"
  assert_rc "--destdir $keep (operator cron files)"

  # the edited shipped-name file survives, byte-for-byte, with a SKIP reason
  if [ ! -f "$edited" ] || [ "$(cat "$edited")" != "$edited_before" ]; then
    echo "FAIL: update touched the hand-edited cron file $edited"
    printf '%s\n' "$out"
    fail=1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "SKIP pve-daily-update: $edited does not match shipped"; then
    echo "FAIL: update did not SKIP the hand-edited cron file $edited with a reason"
    printf '%s\n' "$out"
    fail=1
  fi
  # unknown operator file untouched, byte-for-byte
  if [ ! -f "$op" ] || [ "$(cat "$op")" != "$op_before" ]; then
    echo "FAIL: update touched the operator's unknown cron file $op"
    fail=1
  fi
  # the missing cron file was reinstalled, matching the shipped file, mode 0644
  rebuilt="$keep/etc/cron.d/supermox-monthly-build"
  if [ ! -f "$rebuilt" ]; then
    echo "FAIL: update did not reinstall the missing cron file $rebuilt"
    printf '%s\n' "$out"
    fail=1
  else
    if ! cmp -s cron/supermox-monthly-build "$rebuilt"; then
      echo "FAIL: the reinstalled cron file $rebuilt does not match cron/supermox-monthly-build"
      fail=1
    fi
    if [ "$(stat -c '%a' "$rebuilt")" != "644" ]; then
      echo "FAIL: the reinstalled cron file $rebuilt is not mode 0644"
      fail=1
    fi
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "installed cron file supermox-monthly-build"; then
    echo "FAIL: update did not report reinstalling the missing cron file supermox-monthly-build"
    printf '%s\n' "$out"
    fail=1
  fi
fi

# 4. A missing deploy dir, and a deploy dir that is not a SuperMox deploy, are
#    refused with a reason telling the user to run install-checkout.
missing="$root/missing/srv/supermox"
run_out --destdir "$root/missing"
if [ "$rc" -eq 0 ]; then
  echo "FAIL: update accepted a deploy dir that does not exist"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -qF -- "no deploy dir at $missing: run install-checkout first"; then
  echo "FAIL: a missing deploy dir was not refused by name with a run-install-checkout reason"
  printf '%s\n' "$out"
  fail=1
fi
if [ -e "$missing" ]; then
  echo "FAIL: update created the deploy dir $missing it should have refused"
  fail=1
fi

foreign="$root/foreign/srv/supermox"
mkdir -p "$foreign/scripts"
printf 'not a SuperMox deploy\n' > "$foreign/README"
run_out --destdir "$root/foreign"
if [ "$rc" -eq 0 ]; then
  echo "FAIL: update accepted a deploy dir that is not a SuperMox deploy"
  printf '%s\n' "$out"
  fail=1
fi
if ! printf '%s\n' "$out" | grep -qF -- "not a SuperMox deploy (no scripts/monthly-build.sh): run install-checkout first"; then
  echo "FAIL: a non-SuperMox deploy dir was not refused by name with a run-install-checkout reason"
  printf '%s\n' "$out"
  fail=1
fi
if [ ! -f "$foreign/README" ]; then
  echo "FAIL: update touched a deploy dir that is not a SuperMox deploy"
  fail=1
fi

# 5. The first argument overrides the deploy dir, --cron-dir the cron dir:
#    install there, update there, nothing written to the default cron dir.
over="$root/over"
if install_out /opt/supermox-edge --cron-dir /etc/cron.d-test --destdir "$over"; then
  run_out /opt/supermox-edge --cron-dir /etc/cron.d-test --destdir "$over"
  assert_rc "/opt/supermox-edge --cron-dir /etc/cron.d-test --destdir $over"
  if [ ! -f "$over/opt/supermox-edge/scripts/monthly-build.sh" ]; then
    echo "FAIL: the first argument did not set the deploy dir for update"
    printf '%s\n' "$out"
    fail=1
  fi
  for name in "${cron_names[@]}"; do
    if [ ! -f "$over/etc/cron.d-test/$name" ]; then
      echo "FAIL: --cron-dir lost the cron file $over/etc/cron.d-test/$name during update"
      fail=1
    fi
  done
  if [ -e "$over/etc/cron.d" ]; then
    echo "FAIL: --cron-dir still wrote the default cron dir during update"
    fail=1
  fi
fi

# 6. DEPLOY_DIR overrides the default without an argument.
envd="$root/envd"
rc=0
if out="$(DEPLOY_DIR=/srv/supermox-next bash "$install_script" --destdir "$envd" 2>&1)"; then
  rc=0
  out="$(DEPLOY_DIR=/srv/supermox-next bash "$script" --destdir "$envd" 2>&1)" || rc=$?
  assert_rc "DEPLOY_DIR=/srv/supermox-next --destdir $envd"
  if [ ! -f "$envd/srv/supermox-next/scripts/monthly-build.sh" ]; then
    echo "FAIL: DEPLOY_DIR did not set the deploy dir for update"
    printf '%s\n' "$out"
    fail=1
  fi
else
  echo "FAIL: install-checkout with DEPLOY_DIR=/srv/supermox-next --destdir $envd exited non-zero"
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
echo "OK: update-checkout.sh is install-checkout's update half - install-checkout --destdir P then update-checkout --destdir P restores deployed files the deploy lost, removes deployed entries the checkout no longer carries (stale cleanup) and ends byte-identical to a fresh install-checkout deploy, leaves matching cron files alone, reinstalls a missing one with install -m 0644, survives a hand-edited cron file with a SKIP reason, refuses a missing or non-SuperMox deploy dir (no scripts/monthly-build.sh) with a run-install-checkout reason, --dry-run prints every action and touches nothing, honours the first argument / DEPLOY_DIR / --cron-dir / --destdir, refuses relative targets, and names no service manager, unit or anacron job anywhere in it"
