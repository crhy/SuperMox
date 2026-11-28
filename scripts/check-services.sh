#!/usr/bin/env bash
set -euo pipefail

# Service check for a SuperMox node, run on the target by release-check.sh.
#
# sysvinit decides "started" from the init script's exit code, so two things
# must hold on every node:
#   * every service script SuperMox ships is enabled (an S link in rc2.d, or
#     in rcS.d for the Default-Start: S boot tasks) and its `status` exits 0,
#     or it is idle by design and allowlisted;
#   * every script that is enabled behaves that way, Debian's own included.
#
# Walking only rc2.d, as the old inline check did, cannot see a script that
# was installed but never enabled: no S link means no iteration, so the service
# is simply absent from the report (f10d-4). The expected set therefore comes
# from config/init-scripts.txt, the list the packaging copies from.
#
#   SERVICES_ETC_ROOT  the /etc whose init.d, rc2.d and rcS.d are inspected (default /etc)
#   SERVICES_ALLOW     names enabled but idle by design (space separated)
#   SERVICES_EXPECT_FILE  the shipped-script list (default config/init-scripts.txt)
#   SERVICES_DPKG      override for the "is this package installed" query; a
#                      package that is not installed on this node (supermox-android
#                      on amd64, say) makes its service a SKIP, not a FAIL.
#
# Exit 0 when nothing failed, 1 otherwise, 2 on a usage or setup error.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

etc_root="${SERVICES_ETC_ROOT:-/etc}"
allow=" ${SERVICES_ALLOW:-supermox-wg networking rsync smartmontools} "
expect_file="${SERVICES_EXPECT_FILE:-$repo_root/config/init-scripts.txt}"

if [ ! -d "$etc_root/init.d" ]; then
  printf 'ERROR: no %s/init.d (SERVICES_ETC_ROOT=%s)\n' "$etc_root" "$etc_root" >&2
  exit 2
fi
if [ ! -f "$expect_file" ]; then
  printf 'ERROR: no shipped-script list at %s\n' "$expect_file" >&2
  exit 2
fi

pkg_installed() {
  local pkg="$1"
  if [ -n "${SERVICES_DPKG:-}" ]; then
    "$SERVICES_DPKG" "$pkg" >/dev/null 2>&1
    return
  fi
  dpkg -s "$pkg" >/dev/null 2>&1
}

rc=0
enabled=""
found=0

# 1. What is enabled must answer `status` honestly.
for link in "$etc_root"/rc2.d/S*; do
  [ -e "$link" ] || continue
  name="${link##*/}"
  svc="${name#S[0-9][0-9]}"
  if [ "$svc" = "$name" ]; then continue; fi # not an S<n><n>name link
  script="$etc_root/init.d/$svc"
  [ -x "$script" ] || continue
  enabled="$enabled $svc"
  found=$((found + 1))
  if "$script" status >/dev/null 2>&1; then
    printf 'PASS: %s status\n' "$svc"
    continue
  fi
  case "$allow" in
    *" $svc "*) printf 'IDLE: %s status (enabled, idle by design)\n' "$svc" ;;
    *) printf 'FAIL: %s status\n' "$svc"; rc=1 ;;
  esac
done
printf 'checked %d enabled service(s)\n' "$found"

# 1b. rcS.d holds the boot-time scripts (Default-Start: S): networking, kmod,
# supermox-tmpfiles, supermox-binfmt. They are one-shot tasks, not long-running
# services, so `status` says nothing useful about them (networking answers 3,
# "not running", forever); they count as enabled but are not status-checked.
boot=0
for link in "$etc_root"/rcS.d/S*; do
  [ -e "$link" ] || continue
  name="${link##*/}"
  svc="${name#S[0-9][0-9]}"
  if [ "$svc" = "$name" ]; then continue; fi # not an S<n><n>name link
  [ -x "$etc_root/init.d/$svc" ] || continue
  enabled="$enabled $svc"
  boot=$((boot + 1))
done
printf 'plus %d boot-time service(s) (rcS.d)\n' "$boot"

# 2. What SuperMox ships must be enabled. Field 3 of config/init-scripts.txt
# is the service name, field 2 the package that owns it; inline "#" comments
# are stripped first, so the explanatory blocks cannot become services.
shipped=0
while IFS= read -r line; do
  pkg="${line%% *}"
  svc="${line##* }"
  shipped=$((shipped + 1))
  case " $enabled " in
    *" $svc "*) continue ;;
  esac
  if ! pkg_installed "$pkg"; then
    printf 'SKIP: %s (package %s not installed on this node)\n' "$svc" "$pkg"
    continue
  fi
  if [ ! -e "$etc_root/init.d/$svc" ]; then
    printf 'FAIL: %s: package %s installed but /etc/init.d/%s missing\n' \
      "$svc" "$pkg" "$svc"
    rc=1
    continue
  fi
  printf 'FAIL: %s: installed but not enabled (no S link in rc2.d or rcS.d)\n' "$svc"
  rc=1
done < <(sed 's/#.*//' "$expect_file" | awk 'NF >= 3 {print $2, $3}' | sort -u)
printf 'expected %d shipped service(s)\n' "$shipped"

exit "$rc"
