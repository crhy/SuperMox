"""Tor onion service for a SuperMox node (docs/node-join-architecture.md,
rendezvous mechanism 2: "an onion address for every node").

A node runs a Tor *hidden service* (onion service) for its join daemon, so a
member that knows nobody's current IP can still reach the daemon through an
address that survives NAT, DHCP and reboots. The address is generated from a
long-term key Tor keeps in HiddenServiceDir, so it never changes unless the
node deliberately rotates that key.

This module only produces and reads the pieces:

  torrc_snippet()      the two lines to drop in /etc/tor/torrc.d/supermox.conf
  read_onion_address() the address Tor wrote into <hs_dir>/hostname, or None

scripts/supermox-onion-setup.sh installs the snippet and reloads tor with
/etc/init.d/tor (sysvinit; never systemctl). The address then goes into the
node's membership entry as "onion" (see state.py), which is how the other
members learn it.
"""

import os

# The join daemon's TCP port: init.d/supermox-joind's JOIND_PORT default, and
# the port the HiddenServicePort line forwards to inside the Tor circuit.
JOIN_PORT = 8743

# Tor's HiddenServiceDir for SuperMox's join daemon. Tor creates it and writes
# the onion address into <hs_dir>/hostname, owned by the tor user; keeping that
# directory is what keeps the address stable.
DEFAULT_HS_DIR = "/var/lib/tor/supermox-joind"

# Tor v3 onion addresses: 56 chars of RFC base32 (ed25519, 256 bits) plus the
# ".onion" label. v2 addresses (16 chars, RSA) are retired and must not be
# adopted into the membership list.
_BASE32 = "abcdefghijklmnopqrstuvwxyz234567"
_V3_LOCAL_PART = 56
_ONION_SUFFIX = ".onion"


def torrc_snippet(hs_dir: str = DEFAULT_HS_DIR, join_port: int = JOIN_PORT) -> str:
    """The torrc lines that make the join daemon reachable over Tor.

    Tor forwards connections to its own 127.0.0.1:join_port, i.e. the join
    daemon on this node's loopback, so no port forwarding or NAT rule is needed.
    """
    return (
        "HiddenServiceDir %s\n" % hs_dir
        + "HiddenServicePort %d 127.0.0.1:%d\n" % (join_port, join_port)
    )


def is_onion_address(addr: str) -> bool:
    """True if addr is a well-formed Tor v3 onion address."""
    if not addr.endswith(_ONION_SUFFIX):
        return False
    local = addr[: -len(_ONION_SUFFIX)]
    return len(local) == _V3_LOCAL_PART and all(c in _BASE32 for c in local)


def read_onion_address(hs_dir: str = DEFAULT_HS_DIR):
    """This node's onion address, or None.

    None means "not available yet": Tor has not created the hostname file
    (the service was just configured), or the file holds something that is
    not a v3 address. Callers poll this while tor starts up.
    """
    path = os.path.join(hs_dir, "hostname")
    try:
        with open(path, encoding="ascii") as fh:
            addr = fh.read().strip()
    except (OSError, UnicodeDecodeError):
        return None
    return addr if is_onion_address(addr) else None
