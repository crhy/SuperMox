#!/usr/bin/env bash
# f259: scripts/uninstall-checkout.sh is f253's counterpart (install-checkout).
# Install the checkout, then take it back off: the deploy dir and both shipped
# cron files must go, while an operator's unknown cron file in the same cron
# dir survives untouched, a deploy dir that is not a SuperMox deploy is refused
# with a reason, and --dry-run removes nothing.
#
# Runs offline as a normal user: every real write goes under a --destdir prefix
# inside build/, no sudo anywhere. install-checkout.sh is used to build the
# trees this removes, so the cron files it drops are byte-identical to cron/*.
set -euo pipefail

cd "$(dirname "$0")/.."

install_script="scripts/install-checkout.sh"
script="scripts/uninstall-checkout.sh"
root="build/test-uninstall-checkout"
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

# SuperMox ships crontab files only: the uninstaller may not name a service
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

# The uninstaller default and the crontab command must name the same place.
if ! grep -qF -- '/srv/supermox' "$script"; then
  echo "FAIL: $script does not default to the /srv/supermox deploy dir"
  fail=1
fi
# It is f253's counterpart: it must say so.
if ! grep -qF -- 'f253' "$script"; then
  echo "FAIL: $script does not say it is f253's (install-checkout) counterpart"
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

# 1. --dry-run on a fresh install reports removing every cron file and the
#    deploy dir, and touches nothing.
dry="$root/dry"
if install_out --destdir "$dry"; then
  run_out --dry-run --destdir "$dry"
  assert_rc "--dry-run --destdir $dry"
  for name in "${cron_names[@]}"; do
    if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN cron: remove $dry/etc/cron.d/$name"; then
      echo "FAIL: --dry-run did not report removing the installed cron file $dry/etc/cron.d/$name"
      printf '%s\n' "$out"
      fail=1
    fi
  done
  if ! printf '%s\n' "$out" | grep -qF -- "DRY-RUN deploy: remove $dry/srv/supermox"; then
    echo "FAIL: --dry-run did not report removing the deploy dir $dry/srv/supermox"
    printf '%s\n' "$out"
    fail=1
  fi
  # nothing was written away
  if [ ! -f "$dry/srv/supermox/scripts/monthly-build.sh" ]; then
    echo "FAIL: --dry-run removed the deploy dir $dry/srv/supermox"
    fail=1
  fi
  for name in "${cron_names[@]}"; do
    if [ ! -f "$dry/etc/cron.d/$name" ]; then
      echo "FAIL: --dry-run removed the cron file $dry/etc/cron.d/$name"
      fail=1
    fi
  done
fi

# 2. install-checkout --destdir P then uninstall-checkout --destdir P:
#    the deploy dir and both shipped cron files are gone.
run="$root/run"
if install_out --destdir "$run"; then
  for name in "${cron_names[@]}"; do
    if [ ! -f "$run/etc/cron.d/$name" ] || [ ! -f "$run/srv/supermox/scripts/monthly-build.sh" ]; then
      echo "FAIL: install-checkout did not build the tree under $run"
      fail=1
    fi
  done
  run_out --destdir "$run"
  assert_rc "--destdir $run"
  if [ -e "$run/srv/supermox" ]; then
    echo "FAIL: uninstall left the deploy dir $run/srv/supermox behind"
    fail=1
  fi
  for name in "${cron_names[@]}"; do
    if [ -e "$run/etc/cron.d/$name" ]; then
      echo "FAIL: uninstall left the shipped cron file $run/etc/cron.d/$name behind"
      fail=1
    fi
    if ! printf '%s\n' "$out" | grep -qF -- "removed cron file $run/etc/cron.d/$name"; then
      echo "FAIL: uninstall did not report removing $run/etc/cron.d/$name"
      printf '%s\n' "$out"
      fail=1
    fi
  done
  if ! printf '%s\n' "$out" | grep -qF -- "removed deploy dir $run/srv/supermox"; then
    echo "FAIL: uninstall did not report removing the deploy dir"
    printf '%s\n' "$out"
    fail=1
  fi
fi

# 3. A hand-written unknown cron file in the same --cron-dir survives untouched,
#    and so does a shipped-name file the operator edited away from the shipped
#    contents (the safety contract: only a matching cron.d file is removed).
keep="$root/keep"
if install_out --destdir "$keep"; then
  op="$keep/etc/cron.d/operator-thing"
  printf '0 2 * * * root echo operator-handwritten\n' > "$op"
  op_before="$(cat "$op")"
  edited="$keep/etc/cron.d/pve-daily-update"
  printf '0 4 * * * root /usr/bin/some-operator-command\n' > "$edited"

  run_out --destdir "$keep"
  assert_rc "--destdir $keep (operator cron files)"

  # unknown operator file untouched, byte-for-byte
  if [ ! -f "$op" ]; then
    echo "FAIL: uninstall removed the operator's unknown cron file $op"
    fail=1
  elif [ "$(cat "$op")" != "$op_before" ]; then
    echo "FAIL: uninstall changed the operator's unknown cron file $op"
    fail=1
  fi
  # the edited shipped-name file survives (does not match the shipped cron)
  if [ ! -f "$edited" ]; then
    echo "FAIL: uninstall removed an operator-edited cron file $edited that did not match the shipped cron"
    printf '%s\n' "$out"
    fail=1
  elif ! printf '%s\n' "$out" | grep -qF -- "SKIP pve-daily-update: $edited does not match shipped"; then
    echo "FAIL: uninstall did not SKIP the edited cron file $edited with a reason"
    printf '%s\n' "$out"
    fail=1
  fi
  # the untouched shipped-name file (supermox-monthly-build) is removed
  if [ -e "$keep/etc/cron.d/supermox-monthly-build" ]; then
    echo "FAIL: uninstall left the unmodified shipped cron file supermox-monthly-build behind"
    fail=1
  fi
fi

# 4. A deploy dir that is not a SuperMox deploy is refused with a reason.
foreign="$root/foreign/srv/supermox"
mkdir -p "$foreign/scripts"
printf 'not a SuperMox deploy\n' > "$foreign/README"
rc=0
out="$(bash "$script" --destdir "$root/foreign" 2>&1)" || rc=$?
# refusing the deploy dir is not a hard error; the cron pass is the one that skips
if ! printf '%s\n' "$out" | grep -qF -- "SKIP deploy dir: $foreign is not a SuperMox deploy (no scripts/monthly-build.sh)"; then
  echo "FAIL: a non-SuperMox deploy dir was not refused with a reason"
  printf '%s\n' "$out"
  fail=1
fi
if [ ! -f "$foreign/README" ]; then
  echo "FAIL: uninstall removed a deploy dir that is not a SuperMox deploy"
  fail=1
fi

# 5. Relative paths are refused: a prefix plus a relative target would land
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
echo "OK: uninstall-checkout.sh is f253's counterpart - install-checkout --destdir P then uninstall-checkout --destdir P removes the deploy dir and both shipped cron files, leaves an operator's unknown cron file and an edited cron file that no longer matches the shipped one untouched, refuses a deploy dir that is not a SuperMox deploy (no scripts/monthly-build.sh) with a reason, --dry-run removes nothing, honours the first argument / DEPLOY_DIR / --cron-dir / --destdir, refuses relative targets, and names no service manager, unit or anacron job anywhere in it"
