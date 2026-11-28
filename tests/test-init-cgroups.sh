#!/usr/bin/env bash
# Behavioural test for init.d/supermox-cgroups (audit f24-A: on a clean SuperMox
# install nothing mounts a cgroup filesystem at all -- an init system that
# mounts the hierarchy itself does it, mountkernfs.sh only does it when EXTRAKERNELFS
# names cgroup2, and that variable is unset in the base image. lxc-pve 7.x is
# built for cgroup v2 only, so every container start dies with
#   lxc-start: NNNN: wait_on_daemonized_start: 829 No such file or directory -
#   Failed to receive the container state).
#
# What this guards:
#   * `start` mounts cgroup2 on the cgroup mountpoint when nothing is there;
#   * the controllers LXC needs for resource limits are delegated through
#     cgroup.subtree_control -- a container cgroup only sees what its parent
#     delegated, so mounting alone leaves lxc.*.max settings dead;
#   * only controllers the kernel actually offers are delegated;
#   * delegation is additive: controllers already delegated are not rewritten
#     and an already-delegated set is left alone (writing the empty set would
#     clear the delegation);
#   * an already-mounted hierarchy (Spaced/elogind, fstab) is not mounted again;
#   * a failing mount is a warning and exit 0 -- the node must still boot;
#   * `stop` never unmounts (that would pull the hierarchy out from under
#     running containers);
#   * `status` is LSB 0 mounted / LSB 3 not mounted;
#   * the script is shipped: listed in config/init-scripts.txt for supermox-ve
#     and enabled by dh_installinit in packaging/supermox-ve/debian/rules.
#
# `mount` and `mountpoint` are stubbed through PATH; the hierarchy is a
# directory under build/. No root, no real /sys, no reboot.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/supermox-cgroups"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-init-cgroups.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/mnt"

# --- stubs ---------------------------------------------------------------
# mount: records its arguments, and only succeeds unless state/mount_fail is
# set. It never touches the filesystem: the fake hierarchy files are created
# by the test so the delegation path reads real content from build/.
cat > "$tmp/bin/mount" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOUNT_LOG:?}"
[ -n "${MOUNT_FAIL:-}" ] && exit 32
exit 0
EOF

# mountpoint -q <path>: driven by state/mounted.
cat > "$tmp/bin/mountpoint" <<'EOF'
#!/bin/sh
last=''
for a in "$@"; do last="$a"; done
case "$last" in
  */mnt) [ "$(cat "${STATE_DIR:?}/mounted" 2>/dev/null || echo no)" = yes ] ;;
  *) exit 1 ;;
esac
EOF

chmod +x "$tmp/bin/mount" "$tmp/bin/mountpoint"

export PATH="$tmp/bin:$PATH"
export STATE_DIR="$tmp/state"
export CGROUP_MNT="$tmp/mnt"
export MOUNT_LOG="$tmp/mount.log"

fail=0

reset() {
  rm -f "$tmp/mount.log" "$tmp/mnt/cgroup.controllers" "$tmp/mnt/cgroup.subtree_control"
  printf 'no\n' > "$tmp/state/mounted"
}

# fake unified hierarchy: the kernel's controller list and the delegation set.
fake_hierarchy() {
  printf '%s\n' "$1" > "$tmp/mnt/cgroup.controllers"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$tmp/mnt/cgroup.subtree_control"
  return 0
}

mark_mounted() { printf 'yes\n' > "$tmp/state/mounted"; }

mount_calls() { grep -c -- '-t cgroup2 ' "$tmp/mount.log" 2>/dev/null || true; }

# --- case 1: nothing mounted -> cgroup2 mounted, controllers delegated ----
reset
fake_hierarchy 'cpuset cpu io memory pids rdma'
if ! sh "$src" start; then
  echo "FAIL: start exited non-zero with no cgroup hierarchy"
  fail=1
fi
if [ "$(mount_calls)" != 1 ]; then
  echo "FAIL: expected one cgroup2 mount, got $(mount_calls)"
  fail=1
fi
if ! grep -q -- '-o rw,nosuid,nodev,noexec,relatime,nsdelegate' "$tmp/mount.log"; then
  echo "FAIL: mount options wrong: $(cat "$tmp/mount.log")"
  fail=1
fi
want='+cpu +memory +io +pids +cpuset'
got="$(cat "$tmp/mnt/cgroup.subtree_control" 2>/dev/null)"
if [ "$got" != "$want" ]; then
  echo "FAIL: subtree_control is '$got', expected '$want'"
  fail=1
fi

# --- case 2: status is LSB 0 once mounted ---------------------------------
mark_mounted
if ! sh "$src" status; then
  echo "FAIL: status exited non-zero while cgroup2 is mounted"
  fail=1
fi

# --- case 3: already mounted -> no second mount, delegation still applied --
reset
fake_hierarchy 'cpuset cpu io memory pids rdma'
mark_mounted
rm -f "$tmp/mnt/cgroup.subtree_control"
if ! sh "$src" start; then
  echo "FAIL: start exited non-zero with the hierarchy already mounted"
  fail=1
fi
if [ -f "$tmp/mount.log" ] && [ -s "$tmp/mount.log" ]; then
  echo "FAIL: mounted again over an existing cgroup2 mount"
  fail=1
fi
if [ "$(cat "$tmp/mnt/cgroup.subtree_control" 2>/dev/null)" != "$want" ]; then
  echo "FAIL: controllers not delegated on an already-mounted hierarchy"
  fail=1
fi

# --- case 4: kernel without io -> only what exists is delegated ----------
reset
fake_hierarchy 'cpuset cpu memory pids'
if ! sh "$src" start; then
  echo "FAIL: start exited non-zero on a kernel without the io controller"
  fail=1
fi
if [ "$(cat "$tmp/mnt/cgroup.subtree_control")" != '+cpu +memory +pids +cpuset' ]; then
  echo "FAIL: delegated '$(cat "$tmp/mnt/cgroup.subtree_control")' on a kernel without io"
  fail=1
fi

# --- case 5: partially delegated -> only the missing ones are added -------
reset
fake_hierarchy 'cpuset cpu io memory pids' '+memory'
if ! sh "$src" start; then
  echo "FAIL: start exited non-zero with a partially delegated hierarchy"
  fail=1
fi
if [ "$(cat "$tmp/mnt/cgroup.subtree_control")" != '+cpu +io +pids +cpuset' ]; then
  echo "FAIL: delegation is not additive: '$(cat "$tmp/mnt/cgroup.subtree_control")'"
  fail=1
fi

# --- case 6: fully delegated already -> file untouched -------------------
reset
fake_hierarchy 'cpuset cpu io memory pids' '+cpu +memory +io +pids +cpuset'
cp "$tmp/mnt/cgroup.subtree_control" "$tmp/sub.before"
if ! sh "$src" start; then
  echo "FAIL: start exited non-zero on a fully delegated hierarchy"
  fail=1
fi
if ! cmp -s "$tmp/mnt/cgroup.subtree_control" "$tmp/sub.before"; then
  echo "FAIL: fully delegated set was rewritten (may clear delegation)"
  fail=1
fi

# --- case 7: mount fails -> warning, exit 0, no delegation attempt --------
reset
MOUNT_FAIL=1 sh "$src" start
if [ -s "$tmp/mount.log" ] && [ -f "$tmp/mnt/cgroup.subtree_control" ]; then
  echo "FAIL: delegated controllers after a failed mount"
  fail=1
fi

# --- case 8: no hierarchy files (kernel without cgroup2) -> exit 0 -------
reset
rm -f "$tmp/mnt/cgroup.controllers"
if ! sh "$src" start; then
  echo "FAIL: start exited non-zero when the kernel has no cgroup2"
  fail=1
fi

# --- case 9: stop never unmounts ----------------------------------------
reset
mark_mounted
fake_hierarchy 'cpuset cpu io memory pids'
if ! sh "$src" stop; then
  echo "FAIL: stop exited non-zero"
  fail=1
fi
if grep -q ' -u ' "$tmp/mount.log" 2>/dev/null; then
  echo "FAIL: stop unmounted the cgroup hierarchy"
  fail=1
fi

# --- case 10: status is LSB 3 when not mounted --------------------------
reset
rc=0
sh "$src" status >/dev/null 2>&1 || rc=$?
if [ "$rc" != 3 ]; then
  echo "FAIL: status exit code is $rc, expected LSB 3 when not mounted"
  fail=1
fi

# --- case 11: unknown action is a usage error ---------------------------
rc=0
sh "$src" bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" != 2 ]; then
  echo "FAIL: unknown action exit code is $rc, expected 2"
  fail=1
fi

# --- case 12: the script is actually shipped --------------------------------
if ! grep -qE '^supermox-ve supermox-ve supermox-cgroups$' config/init-scripts.txt; then
  echo "FAIL: config/init-scripts.txt does not ship init.d/supermox-cgroups in supermox-ve"
  fail=1
fi
if ! grep -q 'dh_installinit --name=supermox-cgroups' packaging/supermox-ve/debian/rules; then
  echo "FAIL: packaging/supermox-ve/debian/rules does not enable supermox-cgroups"
  fail=1
fi
# rcS ordering: it must come up before the services that need the hierarchy.
if ! grep -q 'Default-Start:     S' "$src"; then
  echo "FAIL: supermox-cgroups is not a rcS.d script"
  fail=1
fi
for before in lxcfs pve-cluster pve-guests; do
  if ! grep -q "X-Start-Before:.*$before" "$src"; then
    echo "FAIL: supermox-cgroups does not start before $before"
    fail=1
  fi
done

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/supermox-cgroups mounts cgroup2 and delegates the LXC controllers"
