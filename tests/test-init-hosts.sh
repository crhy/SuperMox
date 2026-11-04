#!/usr/bin/env bash
# Behavioural test for init.d/supermox-hosts (audit r12-2: a fresh install
# must map the hostname to the node's own non-loopback IP before pve-cluster
# starts, otherwise pmxcfs refuses to run and the web UI on 8006 is dead).
#
# What this guards:
#   * the Debian default "127.0.1.1 <hostname>" line, which pmxcfs rejects,
#     loses the hostname and a managed line with the node's real IP is added;
#   * DHCP moves the address between boots: exactly one managed line, updated;
#   * re-running changes nothing (idempotent);
#   * an admin's own static line for the hostname wins: file untouched;
#   * no address after the wait: exit 0 (boot must not be blocked), file
#     untouched;
#   * `status` is LSB 0 when the hostname resolves to a non-loopback address
#     of this node, LSB 3 when it only resolves to loopback.
#
# `ip` and `hostname` are stubbed through PATH and a state dir; the hosts file
# is a temp file under build/. No root, no network, no real /etc/hosts.
set -euo pipefail

cd "$(dirname "$0")/.."

src="init.d/supermox-hosts"
if [ ! -f "$src" ]; then
  echo "FAIL: $src does not exist"
  exit 1
fi

tmp="$(pwd)/build/test-init-hosts.tmp"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/state"

# --- stubs ---------------------------------------------------------------

# ip: prints the node's address(es) from the state dir. state/ip = "none"
# means DHCP has not answered; state/route = "fail" makes `route get` fail
# so the `addr show scope global` fallback is exercised; state/extra lists
# further global addresses (an admin's static line must match one of them).
cat > "$tmp/bin/ip" <<'EOF'
#!/bin/sh
state="${IP_STATE_DIR:?}"
ip="$(cat "$state/ip" 2>/dev/null || printf 'none\n')"
extra="$(cat "$state/extra" 2>/dev/null || true)"
mode=other
for a in "$@"; do
  case "$a" in
    route) mode=route ;;
    addr) mode=addr ;;
  esac
done
if [ "$(cat "$state/route" 2>/dev/null || true)" = fail ]; then
  case "$*" in *route*) exit 1 ;; esac
fi
[ "$ip" = none ] && exit 1
if [ "$mode" = route ]; then
  printf '1.1.1.1 via 10.0.2.2 dev eth0 src %s\n' "$ip"
  exit 0
fi
if [ "$mode" = addr ]; then
  printf '2: eth0\tinet %s/24 brd 10.0.2.255 scope global dynamic noprefixroute eth0\n' "$ip"
  for e in $extra; do
    printf '3: eth1\tinet %s/24 scope global alias eth0\n' "$e"
  done
  exit 0
fi
exit 1
EOF

# hostname / hostname -f: the names this node answers to.
cat > "$tmp/bin/hostname" <<'EOF'
#!/bin/sh
state="${IP_STATE_DIR:?}"
if [ "${1:-}" = -f ]; then
  cat "$state/fqdn" 2>/dev/null || exit 1
  exit 0
fi
cat "$state/hostname"
EOF

chmod +x "$tmp/bin/ip" "$tmp/bin/hostname"

printf 'myhost\n' > "$tmp/state/hostname"
printf 'myhost.example.com\n' > "$tmp/state/fqdn"
printf '10.0.2.15\n' > "$tmp/state/ip"
: > "$tmp/state/extra"

hosts="$tmp/hosts"
export HOSTS_FILE="$tmp/hosts"
export IP_STATE_DIR="$tmp/state"
export PATH="$tmp/bin:$PATH"

run() { sh "$src" "$1"; }

managed_count() { grep -c "# supermox-managed" "$hosts" || true; }
managed_line() { grep "# supermox-managed" "$hosts" || true; }

fail=0

# --- case 1: fresh Debian hosts, hostname on the 127.0.1.1 line ----------
cat > "$hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
127.0.1.1 myhost
EOF
if ! run start; then
  echo "FAIL: start exited non-zero on a fresh Debian hosts file"
  fail=1
fi
if [ "$(managed_count)" != 1 ]; then
  echo "FAIL: expected exactly one managed line, got $(managed_count)"
  fail=1
fi
if [ "$(managed_line)" != "10.0.2.15 myhost.example.com myhost # supermox-managed" ]; then
  echo "FAIL: managed line is '$(managed_line)'"
  fail=1
fi
if grep -q '^127\.0\.1\.1.*myhost' "$hosts"; then
  echo "FAIL: hostname still on the 127.0.1.1 line"
  fail=1
fi
if ! grep -q '^127\.0\.1\.1$' "$hosts"; then
  echo "FAIL: 127.0.1.1 line was dropped instead of stripped"
  fail=1
fi
for want in '127.0.0.1 localhost' '::1 localhost ip6-localhost ip6-loopback' 'fe00::0 ip6-localnet'; do
  if ! grep -qF "$want" "$hosts"; then
    echo "FAIL: unrelated line changed or lost: $want"
    fail=1
  fi
done
if [ "$(stat -c '%a' "$hosts")" != 644 ]; then
  echo "FAIL: hosts file mode is $(stat -c '%a' "$hosts"), expected 644"
  fail=1
fi

# --- case 2: status must be LSB 0 with the mapping in place ---------------
if ! run status; then
  echo "FAIL: status exited non-zero while the hostname resolves to the node's IP"
  fail=1
fi

# --- case 3: DHCP moved the address -> managed line updated, still one ----
printf '10.0.2.77\n' > "$tmp/state/ip"
if ! run start; then
  echo "FAIL: start exited non-zero after the address changed"
  fail=1
fi
if [ "$(managed_count)" != 1 ]; then
  echo "FAIL: $(managed_count) managed lines after an address change"
  fail=1
fi
if [ "$(managed_line)" != "10.0.2.77 myhost.example.com myhost # supermox-managed" ]; then
  echo "FAIL: managed line after address change is '$(managed_line)'"
  fail=1
fi

# --- case 4: run twice with the same address -> file unchanged ------------
cp "$hosts" "$hosts.before"
if ! run start; then
  echo "FAIL: start exited non-zero on the second run"
  fail=1
fi
if ! cmp -s "$hosts" "$hosts.before"; then
  echo "FAIL: second run changed the hosts file (not idempotent)"
  fail=1
fi

# --- case 5: `route get` fails -> fall back to `addr show scope global` ---
printf 'fail\n' > "$tmp/state/route"
if ! run start; then
  echo "FAIL: start exited non-zero when ip route get fails"
  fail=1
fi
if [ "$(managed_line)" != "10.0.2.77 myhost.example.com myhost # supermox-managed" ]; then
  echo "FAIL: fallback did not produce the same managed line: '$(managed_line)'"
  fail=1
fi
rm -f "$tmp/state/route"

# --- case 6: an admin's static line for the hostname wins ----------------
cat > "$hosts" <<'EOF'
127.0.0.1 localhost
10.0.2.99 myhost
EOF
printf '10.0.2.99\n' > "$tmp/state/extra"
cp "$hosts" "$hosts.before"
if ! run start; then
  echo "FAIL: start exited non-zero with an admin static line"
  fail=1
fi
if ! cmp -s "$hosts" "$hosts.before"; then
  echo "FAIL: admin static mapping was overwritten"
  fail=1
fi
if [ "$(managed_count)" != 0 ]; then
  echo "FAIL: managed line added next to an admin static line"
  fail=1
fi
if ! run status; then
  echo "FAIL: status exited non-zero while the admin line resolves the hostname"
  fail=1
fi

# --- case 7: no address at all -> exit 0, file untouched ------------------
cat > "$hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 myhost
EOF
printf 'none\n' > "$tmp/state/ip"
cp "$hosts" "$hosts.before"
if ! WAIT_SECS=1 run start; then
  echo "FAIL: start exited non-zero with no IPv4 address (must not block boot)"
  fail=1
fi
if ! cmp -s "$hosts" "$hosts.before"; then
  echo "FAIL: hosts file touched although no address was found"
  fail=1
fi

# --- case 8: hostname only on a loopback line -> status is LSB 3 ---------
rc=0
run status >/dev/null 2>&1 || rc=$?
if [ "$rc" != 3 ]; then
  echo "FAIL: status exit code is $rc, expected LSB 3 (hostname only on 127.0.1.1)"
  fail=1
fi
if ! run stop; then
  echo "FAIL: stop exited non-zero"
  fail=1
fi

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/supermox-hosts manages exactly one hostname mapping"
