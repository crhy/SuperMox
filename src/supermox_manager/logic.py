"""Pure logic for SuperMox Manager: no GTK, no WebKit, importable anywhere.

Everything here is testable on its own (tests/py/test_manager_pin.py). The
GTK/WebKit layer lives in app.py and only calls into this module.

Certificate pinning
-------------------
Every node has one fingerprint we trust, and one certificate we accept:

* the local node: the fingerprint of the leaf certificate in
  /etc/pve/local/pveproxy-ssl.pem (falling back to /etc/pve/pve-ssl.pem);
* a remote member: the ``tls_fingerprint`` of its entry in the signed
  membership list.

Whatever the node actually presents is hashed (SHA256 of the DER certificate)
and compared with that fingerprint. No match -> the node is refused. There is
no first-use exception and no blanket ignoring of certificate errors.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import ssl
from typing import Optional

# pveproxy's HTTPS port; the manager always talks HTTPS.
PVE_PORT = 8006
# The local node's pveproxy is reached over the loopback address.
LOCAL_HOST = "127.0.0.1"
# Where the node's own pveproxy certificate lives, in preference order.
PVE_DIR = "/etc/pve"
CERT_NAMES = ("local/pveproxy-ssl.pem", "pve-ssl.pem")


def cert_file(pve_dir: str = PVE_DIR) -> Optional[str]:
    """Path of the local node's pveproxy certificate, or None if absent.

    pveproxy prefers its own certificate (local/pveproxy-ssl.pem) over the
    cluster-wide one (pve-ssl.pem), so the pin follows the same order.
    """
    for name in CERT_NAMES:
        path = os.path.join(pve_dir, name)
        if os.path.isfile(path):
            return path
    return None


def fingerprint_pem(pem: str | bytes) -> Optional[str]:
    """SHA256 fingerprint of the first certificate in a PEM blob, hex."""
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization

    if isinstance(pem, str):
        pem = pem.encode("ascii")
    try:
        cert = x509.load_pem_x509_certificate(pem)
    except Exception:
        return None
    der = cert.public_bytes(serialization.Encoding.DER)
    return fingerprint_der(der)


def fingerprint_der(der: bytes) -> str:
    return hashlib.sha256(der).hexdigest()


def pem_of_der(der: bytes) -> str:
    """PEM text for a DER certificate (so it can be shown or re-loaded)."""
    from cryptography.hazmat.primitives import serialization

    body = base64.b64encode(der).decode("ascii")
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"


def pin_from_cert_file(path: str) -> Optional[str]:
    """Fingerprint of the local node's own certificate, or None."""
    try:
        with open(path, "r") as f:
            return fingerprint_pem(f.read())
    except (OSError, UnicodeDecodeError):
        return None


def fetch_peer_cert(host: str, port: int = PVE_PORT, timeout: float = 5.0):
    """Fetch the certificate the node at host:port actually presents.

    Returns (der, pem, fingerprint) or None if the connection failed. The
    TLS handshake itself is not verified here: the pinning is done by
    comparing the fingerprint, so a system CA store is never consulted.
    """
    try:
        ctx = ssl._create_unverified_context()
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as tls:
                der = tls.getpeercert(binary_form=True)
    except (ssl.SSLError, OSError):
        return None
    if not der:
        return None
    return der, pem_of_der(der), fingerprint_der(der)


def decide(presented_fp: Optional[str], pinned_fp: Optional[str]):
    """Decide whether a node may be opened. Returns (allowed, reason)."""
    if not pinned_fp:
        return False, "no pinned certificate for this node"
    if presented_fp is None:
        return False, "could not reach the node over TLS"
    if presented_fp != pinned_fp:
        return False, "certificate does not match the pinned fingerprint"
    return True, "certificate matches the pinned fingerprint"


def bare_host(addr: str) -> str:
    """Host part of an overlay address ("10.0.0.5:12345" -> "10.0.0.5")."""
    return addr.rsplit(":", 1)[0] if ":" in addr else addr


def node_url(host: str, port: int = PVE_PORT) -> str:
    """The pveproxy URL of a node, given its host."""
    return "https://{}:{}/".format(host, port)


def membership(state):
    """The membership list of a loaded NodeState (empty if none)."""
    return list(getattr(state, "membership", None) or [])


def entry_for(name: str, state):
    """The membership entry of node *name*, or None."""
    for entry in membership(state):
        if entry.get("name") == name:
            return entry
    return None


def pin_local(pve_dir: str = PVE_DIR) -> Optional[str]:
    """Fingerprint of this node's own pveproxy certificate, or None."""
    path = cert_file(pve_dir)
    return pin_from_cert_file(path) if path else None


def pin_for(name: str, state, my_name: str, pve_dir: str = PVE_DIR,
            is_local: bool = False) -> Optional[str]:
    """The fingerprint we pin node *name* to.

    The local node is pinned to its own certificate on disk; every other
    member to the fingerprint carried by the signed membership list.
    """
    if is_local or name == my_name:
        return pin_local(pve_dir)
    entry = entry_for(name, state)
    return (entry or {}).get("tls_fingerprint") or None


def node_list(state, my_name: str, pve_dir: str = PVE_DIR):
    """Nodes the manager can open: (name, url, is_local), local node first."""
    out = []
    for entry in membership(state):
        name = entry.get("name")
        if not name:
            continue
        if name == my_name:
            out.append((name, node_url(LOCAL_HOST), True))
        else:
            addr = entry.get("overlay_addr")
            if addr:
                out.append((name, node_url(bare_host(addr)), False))
    out.sort(key=lambda t: (not t[2], t[0]))
    return out


# --- what the app keeps on disk: window size and the last node, nothing else

# Everything the app remembers between runs, with its default.
DEFAULTS = {
    "node": "",          # last node shown
    "width": 960,
    "height": 640,
    "text_size": 16,     # base font size, px
    "zoom": 1.0,         # zoom level
}


def settings_path() -> str:
    """Where the app stores window size and the last node."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    return os.path.join(base, "supermox-manager", "settings.json")


def load_settings() -> dict:
    """Window size, last node and text settings; defaults for anything missing."""
    data = dict(DEFAULTS)
    try:
        with open(settings_path(), "r") as f:
            stored = json.load(f)
    except (OSError, ValueError):
        stored = {}
    if isinstance(stored, dict):
        data.update({k: v for k, v in stored.items() if k in DEFAULTS})
    return data


def save_settings(data: dict) -> bool:
    path = settings_path()
    try:
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
        os.replace(tmp, path)
    except OSError:
        return False
    return True
