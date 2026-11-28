#!/usr/bin/env bash
# Two checks on init.d scripts, both aimed at the class of bug where an init
# script invents flags: init.d/supermox-sync used to pass start-stop-daemon
# --okstart (not an option; --oknodo is) and to exec "syncthing --port ...
# --state ..." when syncthing's daemon subcommand is serve and it takes --home
# and --gui-address.  Neither failure was visible without the real binaries,
# so this test uses them: every long option handed to start-stop-daemon must
# appear in its own help output, and the argv supermox-sync builds must really
# start an instance that answers on its localhost GUI port.
set -euo pipefail

cd "$(dirname "$0")/.."

tmp="build/test-init-sync-flags"
rm -rf "$tmp"
mkdir -p "$tmp"

fail=0

# --- every long option passed to start-stop-daemon exists -------------------
SSD=/sbin/start-stop-daemon
if [ -x "$SSD" ]; then
    "$SSD" --help >"$tmp/ssd-help.txt" 2>&1 || true
    checked=0
    while IFS= read -r opt; do
        [ -n "$opt" ] || continue
        checked=$((checked + 1))
        if ! grep -qE -- "(^|[^a-z-])${opt}([^a-z-]|$)" "$tmp/ssd-help.txt"; then
            echo "FAIL: start-stop-daemon has no $opt option"
            fail=1
        fi
    done < <(
        # Join each invocation's backslash continuations, skip comment-only
        # lines, and stop at the bare "--" that separates start-stop-daemon's
        # own options from the program it is starting.
        awk '
            function emit(rest,    n, k, w, opt) {
                n = split(rest, w, /[ \t]+/)
                for (k = 1; k <= n; k++) {
                    if (w[k] == "--") break
                    if (w[k] ~ /^--[a-z]/) {
                        opt = w[k]
                        sub(/=.*/, "", opt)
                        print opt
                    }
                }
            }
            {
                line = $0
                while (line ~ /\\$/ && (getline nxt) > 0) {
                    sub(/\\$/, "", line)
                    line = line " " nxt
                }
                sub(/^[ \t]+/, "", line)
                if (line ~ /^#/) next
                while ((idx = index(line, "start-stop-daemon")) > 0) {
                    line = substr(line, idx + 17)
                    emit(line)
                }
            }
        ' init.d/*
    )
    if [ "$checked" -eq 0 ]; then
        echo "FAIL: no start-stop-daemon options found in init.d/*"
        fail=1
    fi
    [ "$fail" -eq 0 ] && echo "OK: $checked start-stop-daemon options all exist"
else
    echo "SKIP: no start-stop-daemon"
fi

# --- the syncthing argv supermox-sync builds really starts an instance ------
if [ -x /usr/bin/syncthing ] && [ -r /lib/lsb/init-functions ]; then
    port=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
    # Cut the script off before its trailing "case "$1"" so sourcing it only
    # defines its functions; then ask it for the argv it will exec.
    sed '/^case "\$1" in/,$d' init.d/supermox-sync >"$tmp/init-head.sh"
    if ! (
        . "$tmp/init-head.sh"
        syncthing_args "$tmp/home" "$port"
    ) >"$tmp/syncthing-argv.txt" 2>"$tmp/argv.err"; then
        echo "FAIL: init.d/supermox-sync gives no syncthing argv"
        cat "$tmp/argv.err"
        fail=1
    fi
    if [ ! -s "$tmp/syncthing-argv.txt" ]; then
        echo "FAIL: empty syncthing argv"
        fail=1
    fi
    if [ "$(sed -n 1p "$tmp/syncthing-argv.txt")" != serve ]; then
        echo "FAIL: syncthing argv does not start with its serve subcommand"
        fail=1
    fi
    if ! grep -q '^http://127\.0\.0\.1:' "$tmp/syncthing-argv.txt"; then
        echo "FAIL: syncthing GUI address is not localhost"
        fail=1
    fi

    # Only run the argv if it has the shape we expect: an empty or bogus
    # argv would start a syncthing with defaults this test did not ask for.
    if [ -s "$tmp/syncthing-argv.txt" ] &&
        [ "$(sed -n 1p "$tmp/syncthing-argv.txt")" = serve ]; then
        mapfile -t sargs <"$tmp/syncthing-argv.txt"
        mkdir -p "$tmp/home"
        # HOME is pinned to the scratch dir so a stray "default" share can
        # never be made out of the build host's home directory; the argv itself
        # is exactly the one the init script builds.
        env HOME="$tmp" timeout 20 /usr/bin/syncthing "${sargs[@]}" \
            >"$tmp/serve.log" 2>&1 &
        serve_pid=$!
        ok=0
        for _ in $(seq 1 20); do
            if curl -s -m 5 -o /dev/null "http://127.0.0.1:$port/"; then
                ok=1
                break
            fi
            kill -0 "$serve_pid" 2>/dev/null || break
            sleep 1
        done
        kill "$serve_pid" 2>/dev/null || true
        wait "$serve_pid" 2>/dev/null || true
        if [ "$ok" -ne 1 ]; then
            echo "FAIL: syncthing serve did not answer on 127.0.0.1:$port"
            sed -n '1,20p' "$tmp/serve.log"
            fail=1
        elif [ "$fail" -eq 0 ]; then
            echo "OK: syncthing serve answered on its localhost GUI port"
        fi
    fi
else
    echo "SKIP: no syncthing"
fi

exit "$fail"
