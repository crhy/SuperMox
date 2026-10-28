#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

dir="init.d"
if [ ! -d "$dir" ]; then
  echo "FAIL: $dir does not exist"
  exit 1
fi

fail=0
count=0

for_field="Provides: Required-Start: Required-Stop: Default-Start: Default-Stop: Short-Description:"

while IFS= read -r -d '' f; do
  count=$((count + 1))
  reasons=""

  if ! sh -n "$f" 2>/dev/null; then
    reasons="$reasons sh-n"
  fi

  for field in $for_field; do
    if ! grep -qF "$field" "$f"; then
      reasons="$reasons missing:$field"
    fi
  done

  for label in start stop restart status; do
    if ! grep -qE "^[[:space:]]*${label}\)" "$f"; then
      reasons="$reasons no-case:$label"
    fi
  done

  if grep -qE "systemctl|systemd|sd_notify|journalctl" "$f"; then
    reasons="$reasons systemd-text"
  fi

  if [ -n "$reasons" ]; then
    echo "FAIL: $f ($reasons)"
    fail=1
  else
    echo "OK: $f"
  fi
done < <(find "$dir" -maxdepth 1 -type f -print0)

# LSB facilities must be real ones; a typo like $localfs makes insserv reject the script.
while IFS= read -r -d '' f; do
  for fac in $(sed -n 's/^# Required-\(Start\|Stop\): *//p' "$f" | tr ' ' '\n' | grep '^\$' || true); do
    case "$fac" in
      '$local_fs'|'$remote_fs'|'$network'|'$named'|'$portmap'|'$syslog'|'$time'|'$all') ;;
      *) echo "FAIL: $f: unknown LSB facility $fac"; fail=1 ;;
    esac
  done
done < <(find "$dir" -maxdepth 1 -type f -print0)

# Daemon init scripts must export PVE_SYSV_INIT=1 so PVE::Daemon treats the run
# as init-started and does not re-exec /etc/init.d/<svc> in a loop
# (see patches/pve-common/0003-init-script-caller.patch).
daemon_scripts="pvedaemon pveproxy spiceproxy pvestatd pvescheduler pve-firewall pve-ha-crm pve-ha-lrm pve-guests pvebanner pvenetcommit"
for s in $daemon_scripts; do
  f="init.d/$s"
  if [ ! -f "$f" ]; then
    echo "FAIL: init.d/$s missing"
    fail=1
    continue
  fi
  if ! grep -qE '^[[:space:]]*export PVE_SYSV_INIT=1' "$f"; then
    echo "FAIL: init.d/$s missing export PVE_SYSV_INIT=1"
    fail=1
  fi
done

if [ "$count" -eq 0 ]; then
  echo "FAIL: no files in $dir"
  exit 1
fi

cron="cron/pve-daily-update"
if [ ! -f "$cron" ]; then
  echo "FAIL: $cron does not exist"
  fail=1
else
  if grep -qE "systemctl|systemd|sd_notify|journalctl" "$cron"; then
    echo "FAIL: $cron (systemd-text)"
    fail=1
  fi
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
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "OK: all $count init.d scripts pass"
