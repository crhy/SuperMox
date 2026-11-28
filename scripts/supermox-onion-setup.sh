#!/usr/bin/env bash
# Give this node a Tor onion service for its join daemon.
#
# Rendezvous mechanism 2 of docs/node-join-architecture.md: the onion address
# comes from a long-term key Tor keeps in HiddenServiceDir, so it survives
# NAT, DHCP and reboots and needs no port forwarding. Members that know
# nobody's current IP reach the daemon through it.
#
# Idempotent — safe to re-run. --dry-run prints the whole plan and changes
# nothing.
#
# What this does, in order:
#   1. checks tor is installed with a sysvinit service script (/etc/init.d/tor)
#   2. writes the two HiddenService lines to /etc/tor/torrc.d/supermox.conf
#   3. makes sure /etc/tor/torrc includes /etc/tor/torrc.d/
#   4. prepares HiddenServiceDir (owned by the tor user, mode 0700)
#   5. reloads tor through /etc/init.d/tor (never systemctl)
#   6. waits up to 60 s for Tor to write the address, then prints it
#
# The two config lines mirror supermox.onion.torrc_snippet() in src/supermox/
# onion.py; keep them in sync. The printed address is what goes into the
# node's membership entry as "onion" (supermox.state).
set -euo pipefail

TORRC="${SUPERMOX_ONION_TORRC:-/etc/tor/torrc}"
TORRC_D="${SUPERMOX_ONION_TORRC_D:-/etc/tor/torrc.d}"
CONF="$TORRC_D/supermox.conf"
INIT="${SUPERMOX_ONION_INIT:-/etc/init.d/tor}"
HS_DIR="${SUPERMOX_ONION_HS_DIR:-/var/lib/tor/supermox-joind}"
JOIN_PORT="${SUPERMOX_ONION_PORT:-8743}"
WAIT_SECS="${SUPERMOX_ONION_WAIT:-60}"
dry=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

run() {
  if [ "$dry" -eq 1 ]; then
    printf '   plan: %s\n' "$*"
  else
    "$@"
  fi
}

# Which user tor runs as: the last User= line in its defaults file, then torrc.
detect_tor_user() {
  local f u=""
  for f in /usr/share/tor/tor-service-defaults-torrc "$TORRC"; do
    [ -r "$f" ] || continue
    u="$(awk '/^[[:space:]]*User[[:space:]]/ { v = $2 } END { print v }' "$f")"
  done
  printf '%s\n' "$u"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --hs-dir) [ "$#" -ge 2 ] || die "--hs-dir needs a path"
      HS_DIR="$2"
      shift 2 ;;
    --port) [ "$#" -ge 2 ] || die "--port needs a port number"
      case "$2" in
        '' | *[!0-9]*) die "--port needs a port number" ;;
      esac
      JOIN_PORT="$2"
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# 1. tor must be installed, and it must ship a sysvinit service script.
step "checking tor's sysvinit service script"
if [ ! -x "$INIT" ]; then
  die "no $INIT: install tor first (apt-get install -y tor), and note that a tor build whose only service script is a systemd unit does not qualify here"
fi
printf '   ok: %s\n' "$INIT"

# 2. the HiddenService directives (the same two lines supermox.onion.torrc_snippet
#    produces, plus a comment header of our own).
step "writing $CONF"
run mkdir -p "$TORRC_D"
snippet() {
  printf '# SuperMox: onion service for the join daemon (supermox-joind)\n'
  printf 'HiddenServiceDir %s\n' "$HS_DIR"
  printf 'HiddenServicePort %s 127.0.0.1:%s\n' "$JOIN_PORT" "$JOIN_PORT"
}
if [ "$dry" -eq 1 ]; then
  printf '   plan: write %s\n' "$CONF"
  snippet
else
  snippet >"$CONF"
  chmod 0644 "$CONF"
fi

# 3. torrc has to include the torrc.d directory, or the snippet is never read.
step "making sure $TORRC includes $TORRC_D/"
included=0
for pat in "%include $TORRC_D/" "%include $TORRC_D" \
  "Include $TORRC_D/" "Include $TORRC_D" \
  "include $TORRC_D/" "include $TORRC_D"; do
  if [ -f "$TORRC" ] && grep -qxF "$pat" "$TORRC"; then
    included=1
    break
  fi
done
if [ "$included" -eq 1 ]; then
  printf '   ok: already included\n'
elif [ "$dry" -eq 1 ]; then
  printf '   plan: append %%include %s/ to %s\n' "$TORRC_D" "$TORRC"
else
  printf '\n# SuperMox: pick up /etc/tor/torrc.d/*.conf\n%%include %s/\n' "$TORRC_D" >>"$TORRC"
fi

# 4. Tor writes <HiddenServiceDir>/hostname as the user it runs as, so the
# directory must exist and belong to it. Tor would create it itself, but only
# with the owner it is running as; making it explicit keeps re-runs quiet.
# The user comes from tor's own config (User= in tor-service-defaults-torrc
# or torrc), which is debian-tor on Debian/Devuan and tor on some builds.
step "preparing HiddenServiceDir $HS_DIR"
tor_user="$(detect_tor_user)"
tor_user="${tor_user:-debian-tor}"
run mkdir -p "$HS_DIR"
if [ "$dry" -eq 1 ]; then
  printf '   plan: chown %s:%s %s; chmod 0700 %s\n' "$tor_user" "$tor_user" "$HS_DIR" "$HS_DIR"
else
  if id -u "$tor_user" >/dev/null 2>&1; then
    chown "$tor_user:$tor_user" "$HS_DIR"
    printf '   ok: %s owned by %s, mode 0700\n' "$HS_DIR" "$tor_user"
  else
    printf '   note: user %s does not exist, leaving %s owned as-is\n' "$tor_user" "$HS_DIR" >&2
  fi
  chmod 0700 "$HS_DIR"
fi

# 5. sysvinit only: reload a running tor, start it if it is not up yet.
step "reloading tor"
if [ "$dry" -eq 1 ]; then
  printf '   plan: %s reload (or start, if not running)\n' "$INIT"
elif "$INIT" status >/dev/null 2>&1; then
  run "$INIT" reload || run "$INIT" restart
else
  run "$INIT" start
fi

# 6. Tor generates the key on first start; the address appears in the
# hostname file. Poll for it, then validate it is a v3 onion address.
step "waiting up to ${WAIT_SECS}s for the onion address"
addr=""
if [ "$dry" -eq 1 ]; then
  printf '   plan: read %s/hostname\n' "$HS_DIR"
  exit 0
fi
for _ in $(seq 1 "$WAIT_SECS"); do
  if [ -r "$HS_DIR/hostname" ]; then
    candidate="$(tr -d '[:space:]' <"$HS_DIR/hostname")"
    if printf '%s' "$candidate" | grep -Eq '^[a-z2-7]{56}\.onion$'; then
      addr="$candidate"
      break
    fi
  fi
  sleep 1
done

if [ -z "$addr" ]; then
  step "FAILED: no onion address after ${WAIT_SECS}s"
  printf 'Check the tor log (tail -n 40 /var/log/tor/notices.log) and that %s is writable by the tor user.\n' "$HS_DIR" >&2
  exit 1
fi

printf '\n== onion address of this node\n'
printf '%s\n' "$addr"
printf 'reach the join daemon through it: curl -sS -m 60 -x socks5h://127.0.0.1:9050 http://%s:%s/\n' "$addr" "$JOIN_PORT"
printf '  (curl resolves .onion itself and refuses it per RFC 7686, so the SOCKS\n'
printf '   endpoint has to be passed explicitly; torsocks works for clients that\n'
printf '   resolve through getaddrinfo, e.g. torsocks wget -qO- http://%s:%s/\n' "$addr" "$JOIN_PORT"
printf 'record it in the membership list as the "onion" field of this node'\''s entry.\n'
