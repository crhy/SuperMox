#!/usr/bin/env bash
# Behavioural test for init.d/supermox-hosts: the boot-time mapping of this
# node's hostname to its own IP in /etc/hosts, which pve-cluster needs on a
# fresh install's first boot.
#
# Guards:
#   * the script is POSIX-clean, LSB-headed, sysvinit-only and registered in
#     all three places a shipped service script has to be (config/init-scripts.txt,
#     debian/rules, pve-cluster's Required-Start);
#   * it writes exactly one "<ip> <hostname>" line, atomically (temp file + mv),
#     is idempotent, and replaces a stale line for the same hostname;
#   * when no address is resolvable yet (DHCP not done) it leaves the file
#     byte-identical, writes no empty-address line and still exits 0;
#   * stop and status never touch the file.
#
# The sandbox points the script at its own hosts file through the documented
# SUPERMOX_HOSTS_FILE override, and shadows `hostname` and `logger` with stubs,
# so no root, no real /etc/hosts and no real syslog are involved.
set -euo pipefail

cd "$(dirname "$0")/.."

script="init.d/supermox-hosts"
rules="packaging/supermox-ve/debian/rules"
init_scripts="config/init-scripts.txt"
cluster="init.d/pve-cluster"

fail=0

note() {
  echo "FAIL: $*"
  fail=1
}

# ---- static: the script itself -----------------------------------------------

if [ ! -f "$script" ]; then
  echo "FAIL: $script missing"
  exit 1
fi
if [ ! -x "$script" ]; then
  note "$script is not executable"
fi
if ! sh -n "$script"; then
  note "sh -n $script"
fi
if ! bash -n "$script"; then
  note "bash -n $script"
fi
if ! command -v shellcheck >/dev/null 2>&1; then
  note "shellcheck is not installed, cannot lint $script"
elif ! shellcheck -S warning "$script"; then
  note "shellcheck -S warning $script"
fi

for field in 'Provides:          supermox-hosts' 'Required-Start:' 'Required-Stop:' \
  'Default-Start:' 'Default-Stop:' 'Short-Description:'; do
  if ! grep -qF "$field" "$script"; then
    note "$script missing LSB field: $field"
  fi
done

# Required-Start must carry the facilities the address depends on, and Default-Start
# must cover the normal runlevels pve-cluster starts in.
if ! grep -qE '^# Required-Start: *.*\$network' "$script"; then
  note "$script Required-Start does not list \$network"
fi
if ! grep -qE '^# Required-Start:.*\$local_fs' "$script"; then
  note "$script Required-Start does not list \$local_fs"
fi
if ! grep -qE '^# Default-Start:.*2 3 4 5' "$script"; then
  note "$script Default-Start is not 2 3 4 5"
fi

for label in start stop restart status; do
  if ! grep -qE "^[[:space:]]*${label}\)" "$script"; then
    note "$script has no $label) case"
  fi
done

# ZERO-systemd: sysvinit only.
if grep -qE "systemctl|systemd|sd_notify|journalctl" "$script"; then
  note "$script mentions systemd"
fi

# ---- static: registration in all three places --------------------------------

if ! grep -q '^supermox-ve supermox-ve supermox-hosts$' "$init_scripts"; then
  note "$init_scripts has no 'supermox-ve supermox-ve supermox-hosts' line"
fi
if ! grep -q -- '--name=supermox-hosts' "$rules"; then
  note "$rules has no dh_installinit --name=supermox-hosts"
fi
# pve-cluster must depend on it, or insserv may start pmxcfs first.
if ! sed -n 's/^# Required-Start: *//p' "$cluster" | grep -qw 'supermox-hosts'; then
  note "$cluster Required-Start does not list supermox-hosts"
fi

# ---- sandbox run -------------------------------------------------------------

tmp="$(pwd)/build/test-supermox-hosts"
rm -rf "$tmp"
mkdir -p "$tmp/bin"

# Shadow `hostname`: -I prints whatever the sandbox file says the interfaces
# answer with; an empty file means "no address yet" (DHCP still running).
cat > "$tmp/bin/hostname" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-I" ]; then
  cat "$tmp/ip" 2>/dev/null
  exit 0
fi
printf 'node41\n'
EOF
chmod +x "$tmp/bin/hostname"

# Shadow `logger` so the syslog note is recorded in the sandbox, not on the host.
cat > "$tmp/bin/logger" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/syslog"
EOF
chmod +x "$tmp/bin/logger"

hosts="$tmp/hosts"
hn=node41

run() {
  # $1 is the subcommand; the rest of the environment is set by the caller.
  SUPERMOX_HOSTS_FILE="$hosts" PATH="$tmp/bin:$PATH" sh "$script" "$1" \
    >"$tmp/out" 2>&1
}

# A fresh install's /etc/hosts: localhost plus a stale line for this node's
# own name, pointing at an address the node no longer has.
cat > "$hosts" <<EOF
127.0.0.1 localhost
::1 localhost
fe80::1 $hn
10.0.0.9 oldname
EOF
cp "$hosts" "$tmp/hosts.orig"
printf '10.0.0.7\n' > "$tmp/ip"

if ! run start; then
  note "start exited non-zero although an address was resolvable"
fi

if [ ! -f "$hosts" ]; then
  note "start removed the hosts file"
elif ! grep -q "^10\.0\.0\.7 $hn\$" "$hosts"; then
  note "start did not write '10.0.0.7 $hn'"
  cat "$hosts"
fi

# The stale line for the same name is gone, and unrelated lines survive.
if grep -q "fe80::1" "$hosts"; then
  note "stale fe80::1 line for $hn still present"
fi
if ! grep -q '^10\.0\.0\.9 oldname$' "$hosts"; then
  note "unrelated line for oldname was dropped"
fi
if ! grep -q '^127\.0\.0\.1 localhost$' "$hosts"; then
  note "localhost line was dropped"
fi

# Exactly one line for this hostname.
if [ "$(awk -v h="$hn" '{ for (i = 2; i <= NF; i++) if ($i == h) n++ } END { print n + 0 }' "$hosts")" != 1 ]; then
  note "not exactly one entry for $hn"
fi

# The temp file is mv-ed into place, never left behind.
if [ -e "$hosts.new" ]; then
  note "$hosts.new left behind"
fi

# The note reached syslog.
if [ ! -f "$tmp/syslog" ] || ! grep -q "$hn" "$tmp/syslog"; then
  note "no syslog note from start"
fi

# Re-run: byte-identical file, still exit 0.
cp "$hosts" "$tmp/hosts.run1"
if ! run start; then
  note "second start exited non-zero"
fi
if ! cmp -s "$tmp/hosts.run1" "$hosts"; then
  note "second start changed the file (not idempotent)"
  diff "$tmp/hosts.run1" "$hosts" || true
fi

# A changed address replaces the line instead of adding a second one.
printf '10.0.0.8\n' > "$tmp/ip"
if ! run start; then
  note "start after the address changed exited non-zero"
fi
if ! grep -q "^10\.0\.0\.8 $hn\$" "$hosts"; then
  note "new address 10.0.0.8 not written"
fi
if grep -q "^10\.0\.0\.7 " "$hosts"; then
  note "old address 10.0.0.7 still mapped"
fi
if [ "$(awk -v h="$hn" '{ for (i = 2; i <= NF; i++) if ($i == h) n++ } END { print n + 0 }' "$hosts")" != 1 ]; then
  note "more than one entry for $hn after the address changed"
fi

# Only real IPv4 counts: an IPv6 or otherwise odd form from `hostname -I` must
# never be written into /etc/hosts, and must not hide the IPv4 behind it.
printf 'fe80::1 10.0.0.9\n' > "$tmp/ip"
if ! run start; then
  note "start exited non-zero with an IPv6 form listed first"
fi
if ! grep -q "^10\.0\.0\.9 $hn\$" "$hosts"; then
  note "the IPv4 behind an IPv6 form was not used"
fi
if grep -q "fe80" "$hosts"; then
  note "an IPv6 form was written into the hosts file"
fi

# DHCP-safe: no address resolvable. File untouched, exit 0, no empty-address
# line, note logged.
: > "$tmp/ip"
cp "$hosts" "$tmp/hosts.before"
start_ts=$(date +%s)
if ! run start; then
  note "start exited non-zero with no address (must exit 0)"
fi
end_ts=$(date +%s)
if ! cmp -s "$tmp/hosts.before" "$hosts"; then
  note "the hosts file changed when no address was resolvable"
  diff "$tmp/hosts.before" "$hosts" || true
fi
if grep -qE "^ *${hn}( |\$)" "$hosts"; then
  note "an entry with an empty address was written"
fi
if [ -e "$hosts.new" ]; then
  note "$hosts.new left behind after the DHCP-safe exit"
fi
if ! grep -q "no non-loopback address" "$tmp/out"; then
  note "no console note about the missing address"
fi
if ! grep -q "no non-loopback address" "$tmp/syslog"; then
  note "no syslog note about the missing address"
fi
# Bounded: the retry loop must not hang the boot (10 tries, 1 s apart).
if [ "$((end_ts - start_ts))" -gt 30 ]; then
  note "the retry loop took $((end_ts - start_ts)) s, not bounded"
fi

# stop and status must never touch the file.
if ! run stop; then
  note "stop exited non-zero"
fi
if ! run status; then
  note "status exited non-zero while the mapping is present"
fi
if ! cmp -s "$tmp/hosts.before" "$hosts"; then
  note "stop or status changed the hosts file"
fi

# status reports honestly when the name is not mapped.
printf '127.0.0.1 localhost\n' > "$hosts"
if run status; then
  note "status exited 0 although $hn is not mapped"
fi
if ! grep -q "not mapped" "$tmp/out"; then
  note "status did not report $hn as unmapped"
fi
if [ ! -s "$hosts" ] || ! grep -q '^127\.0\.0\.1 localhost$' "$hosts"; then
  note "status touched the hosts file"
fi

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: supermox-hosts maps the node hostname, is idempotent, DHCP-safe, and registered"
