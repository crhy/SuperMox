#!/usr/bin/env bash
set -euo pipefail

# tests/test-init-wg.sh — init.d/supermox-wg must bring the wg0 overlay up
# from /etc/wireguard/wg0.conf, refuse a config that is world-readable, and
# never read the old /etc/supermox/wg0.conf location.
#
# The script is POSIX sh, so it runs under dash when dash is available
# (the target's /bin/sh) and under /bin/sh otherwise.
cd "$(dirname "$0")/.."

script="init.d/supermox-wg"
if [ ! -f "$script" ]; then
  echo "FAIL: $script missing"
  exit 1
fi

if [ ! -r /lib/lsb/init-functions ]; then
  echo "SKIP"
  exit 0
fi

if [ -x /usr/bin/dash ]; then
  sh_bin=/usr/bin/dash
else
  sh_bin=/bin/sh
fi

tmp="build/test-init-wg"
rm -rf "$tmp"
mkdir -p "$tmp"

# SUPERMOX_WG_ROOT is the directory the script treats as /etc/wireguard.
conf_dir="$tmp/root"
legacy_dir="$tmp/supermox"
stub_bin="$tmp/stub-bin"
mkdir -p "$conf_dir" "$legacy_dir" "$stub_bin"
conf="$conf_dir/wg0.conf"

# --- stubs for wg-quick, wg and ip ------------------------------------------
cat >"$stub_bin/wg-quick" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
if [ "$1" = strip ]; then
    printf '[Interface]\nPersistentKeepalive = 25\n'
fi
exit 0
EOF
cat >"$stub_bin/wg" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$STUB_LOG"
if [ "$1" = syncconf ]; then
    # the mode the stripped conf had while wg was reading it
    stat -c '%a' "$3" >> "$MODE_LOG" 2>/dev/null
    cp "$3" "$SYNC_COPY" 2>/dev/null
fi
exit 0
EOF
cat >"$stub_bin/ip" <<'EOF'
#!/bin/sh
# "ip link show <iface>" exits non-zero when the interface is absent. Route
# calls are logged and applied to a fake routing table of their own, so the
# bring-up assertions below stay readable while the routing table is still
# observable.
if [ "$1" = "-6" ] && [ "$2" = "route" ]; then
    printf '%s\n' "$*" >> "$ROUTE_LOG"
    case "$3" in
        show)
            cat "$ROUTE_TABLE" 2>/dev/null
            exit 0
            ;;
        replace|add)
            grep -v "^$4" "$ROUTE_TABLE" 2>/dev/null > "$ROUTE_TABLE.tmp" || true
            printf '%s proto static metric 1 pref medium\n' "$4" >> "$ROUTE_TABLE.tmp"
            mv "$ROUTE_TABLE.tmp" "$ROUTE_TABLE"
            exit 0
            ;;
        del)
            grep -v "^$4" "$ROUTE_TABLE" 2>/dev/null > "$ROUTE_TABLE.tmp" || true
            mv "$ROUTE_TABLE.tmp" "$ROUTE_TABLE"
            exit 0
            ;;
    esac
    exit 0
fi
if [ -f "$IP_UP" ]; then
    printf '1: wg0\tinet\tstate up\n'
    exit 0
fi
printf 'wg0: (not present)\n' >&2
exit 1
EOF
chmod 0755 "$stub_bin/wg-quick" "$stub_bin/wg" "$stub_bin/ip"

export PATH="$stub_bin:$PATH"
export SUPERMOX_WG_ROOT="$conf_dir"
export SUPERMOX_WG_LOG="$tmp/wg.log"
STUB_LOG="$tmp/calls.log"
MODE_LOG="$tmp/modes.log"
IP_UP="$tmp/ip-up"
SYNC_COPY="$tmp/syncconf-copy"
ROUTE_LOG="$tmp/route-calls.log"
ROUTE_TABLE="$tmp/route-table"
export STUB_LOG MODE_LOG IP_UP SYNC_COPY ROUTE_LOG ROUTE_TABLE

fail=0
LAST_RC=0

run() {
  local rc=0
  : > "$STUB_LOG"
  "$sh_bin" "$script" "$@" || rc=$?
  LAST_RC=$rc
}

up() { touch "$IP_UP"; }
down() { rm -f "$IP_UP"; }

calls() {
  if [ -s "$STUB_LOG" ]; then
    tr '\n' '|' < "$STUB_LOG"
    printf '\n'
  else
    printf '(none)\n'
  fi
}

make_conf() {
  cat >"$conf" <<'EOF'
[Interface]
Address = 10.9.0.1/16
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
ListenPort = 51820

[Peer]
Endpoint = 10.9.0.2 51821
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
AllowedApps = wg, wg-quick
AllowedIPs = fd05:0000:0000:0000:0000:0000:0000:0001/128
EOF
  chmod 0600 "$conf"
}

# --- start with no conf: this node is not a member yet, and that is not an
#     error that should stop the boot ----------------------------------------
run start
if [ "$LAST_RC" -ne 0 ]; then
  echo "FAIL: start with no conf exits $LAST_RC"
  fail=1
fi
if [ -s "$STUB_LOG" ]; then
  echo "FAIL: start with no conf calls $(calls)"
  fail=1
fi

# --- a conf left in the old /etc/supermox location is never read ------------
cat >"$legacy_dir/wg0.conf" <<'EOF'
[Interface]
Address = 10.9.0.9/16
EOF
chmod 0600 "$legacy_dir/wg0.conf"
run start
if [ -s "$STUB_LOG" ]; then
  echo "FAIL: start reads the legacy conf: $(calls)"
  fail=1
fi

# --- a world-readable conf carries the node's private key: refuse ----------
make_conf
chmod 0644 "$conf"
down
run start
if [ -s "$STUB_LOG" ]; then
  echo "FAIL: start brings up a world-readable conf: $(calls)"
  fail=1
fi
chmod 0600 "$conf"

# --- start with the conf present: wg-quick up wg0 --------------------------
down
run start
if [ "$(tr '\n' ' ' < "$STUB_LOG")" != "up wg0 " ]; then
  echo "FAIL: start does not run wg-quick up wg0 (got $(calls))"
  fail=1
fi

# --- status reflects the interface state ------------------------------------
up
run status
if [ "$LAST_RC" -ne 0 ]; then
  echo "FAIL: status of an up overlay exits $LAST_RC"
  fail=1
fi
down
run status
if [ "$LAST_RC" -ne 3 ]; then
  echo "FAIL: status of a down overlay exits $LAST_RC"
  fail=1
fi

# --- stop when not up: nothing to take down, and no error ------------------
down
run stop
if [ -s "$STUB_LOG" ]; then
  echo "FAIL: stop of a down overlay calls $(calls)"
  fail=1
fi

# --- stop when up: wg-quick down wg0 ---------------------------------------
up
run stop
if [ "$(tr '\n' ' ' < "$STUB_LOG")" != "down wg0 " ]; then
  echo "FAIL: stop of an up overlay does not run wg-quick down wg0 (got $(calls))"
  fail=1
fi

# --- reload of a down overlay brings the overlay up ------------------------
down
run reload
if [ "$(tr '\n' ' ' < "$STUB_LOG")" != "up wg0 " ]; then
  echo "FAIL: reload of a down overlay does not bring it up (got $(calls))"
  fail=1
fi

# --- reload of an up overlay swaps keys without dropping the interface ----
up
rm -f "$MODE_LOG" "$SYNC_COPY"
run reload
if [ "$(tr '\n' ' ' < "$STUB_LOG")" != "strip wg0 syncconf wg0 $conf_dir/.wg0.syncconf " ]; then
  echo "FAIL: reload does not syncconf wg0 from a stripped conf (got $(calls))"
  fail=1
fi
if [ "$(cat "$MODE_LOG" 2>/dev/null)" != "600" ]; then
  echo "FAIL: the stripped conf was mode $(cat "$MODE_LOG" 2>/dev/null), not 0600"
  fail=1
fi
if [ -f "$conf_dir/.wg0.syncconf" ]; then
  echo "FAIL: reload leaves the stripped conf behind"
  fail=1
fi

# --- start of an overlay that is already up re-applies the file: the join
#     CLI runs start after every rewrite, and a stale interface must not win
#     over the config on disk -------------------------------------------------
up
run start
if [ "$(tr '\n' ' ' < "$STUB_LOG")" != "strip wg0 syncconf wg0 $conf_dir/.wg0.syncconf " ]; then
  echo "FAIL: start of an up overlay does not re-apply the config (got $(calls))"
  fail=1
fi

# --- reload must also fix up the routing table -----------------------------
# wg syncconf swaps keys and peers on the live interface but never touches the
# routing table, and the kernel only sends a packet into the tunnel when a
# route points the peer's address at wg0: a member added after the interface
# came up is listed by `wg show` and unreachable in fact. The interface's own
# address route is the kernel's and must survive.
up
: > "$ROUTE_LOG"
printf 'fd0a:1111:1111:1111:1111:1111:1111:1111/128 proto kernel metric 256 pref medium\n' > "$ROUTE_TABLE"
printf 'fd0b:2222:2222:2222:2222:2222:2222:2222/128 proto static metric 1 pref medium\n' >> "$ROUTE_TABLE"
run reload
if [ "$LAST_RC" -ne 0 ]; then
  echo "FAIL: reload with a routing table to fix exits $LAST_RC"
  fail=1
fi
if ! grep -q '^fd05:0000:0000:0000:0000:0000:0000:0001/128' "$ROUTE_TABLE"; then
  echo "FAIL: reload leaves the new peer's address unrouted"
  sed 's/^/    /' "$ROUTE_TABLE"
  fail=1
fi
if grep -q '^fd0b:2222' "$ROUTE_TABLE"; then
  echo "FAIL: reload leaves a departed peer's route pointing at wg0"
  sed 's/^/    /' "$ROUTE_TABLE"
  fail=1
fi
if ! grep -q 'proto kernel' "$ROUTE_TABLE"; then
  echo "FAIL: reload deleted the interface's own address route"
  sed 's/^/    /' "$ROUTE_TABLE"
  fail=1
fi

# --- a nested-namespace config is reported, not guessed at ----------------
mkdir -p "$conf_dir/node-b"
cp "$conf" "$conf_dir/node-b/wg0.conf"
chmod 0600 "$conf_dir/node-b/wg0.conf"
nested_rc=0
: > "$STUB_LOG"
(
  SUPERMOX_WG_DIR="$conf_dir/node-b" \
    "$sh_bin" "$script" reload >"$tmp/nested.out" 2>&1
) || nested_rc=$?
if [ "$nested_rc" -ne 0 ]; then
  echo "FAIL: reload of a nested namespace exits $nested_rc"
  cat "$tmp/nested.out"
  fail=1
fi
if ! grep -q 'nested-namespace config' "$tmp/nested.out"; then
  echo "FAIL: a nested namespace is not reported"
  cat "$tmp/nested.out"
  fail=1
fi
if [ -s "$STUB_LOG" ]; then
  echo "FAIL: a nested namespace is applied in the wrong namespace: $(calls)"
  fail=1
fi

# --- the boot order the cluster depends on --------------------------------
# corosync resolves ring0_addr when it starts, so wg0 must already carry the
# overlay address when corosync reads /etc/corosync/corosync.conf. Measured
# in the VM: with wg0 late, corosync exits with "No valid name found for
# local host" and pmxcfs then runs without quorum.
for want in '^# Required-Start:.*\$network' \
            '^# X-Start-Before:.*corosync' \
            '^# X-Start-Before:.*pve-cluster'; do
  if ! grep -qE "$want" "$script"; then
    echo "FAIL: $script LSB header is missing: $want"
    fail=1
  fi
done

rm -rf "$tmp"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "OK: init.d/supermox-wg brings wg0 up from /etc/wireguard/wg0.conf"
