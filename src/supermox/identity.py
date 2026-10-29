"""SuperMox node identity: WireGuard X25519 keypair and Ed25519 signing keypair.

Each node generates its own keypairs at install time.  These are never
derived from the cluster phrase, so one node's keys say nothing about
any other node's keys.
"""

import hashlib
import json
import os
import stat

from nacl.public import PrivateKey as X25519Private
from nacl.signing import SigningKey


def new_identity() -> dict:
    """Generate a fresh node identity with X25519 and Ed25519 keypairs."""
    wg_priv = X25519Private.generate()
    ed_signing = SigningKey.generate()
    return {
        "wg_priv": bytes(wg_priv),
        "wg_pub": bytes(wg_priv.public_key),
        "ed_priv": bytes(ed_signing),
        "ed_pub": bytes(ed_signing.verify_key),
    }


def fingerprint(ed_pub: bytes) -> bytes:
    """Return the first 16 bytes of SHA-256 of an Ed25519 public key."""
    return hashlib.sha256(ed_pub).digest()[:16]


def save(identity: dict, path: str) -> None:
    """Persist an identity dict to a JSON file with mode 0600."""
    data = {
        "wg_priv": _b64(identity["wg_priv"]),
        "wg_pub": _b64(identity["wg_pub"]),
        "ed_priv": _b64(identity["ed_priv"]),
        "ed_pub": _b64(identity["ed_pub"]),
    }
    # Write atomically with restrictive permissions.
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(data, indent=2).encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def load(path: str) -> dict:
    """Load an identity dict from a JSON file."""
    with open(path, "r") as f:
        data = json.load(f)
    return {
        "wg_priv": _b64d(data["wg_priv"]),
        "wg_pub": _b64d(data["wg_pub"]),
        "ed_priv": _b64d(data["ed_priv"]),
        "ed_pub": _b64d(data["ed_pub"]),
    }


def _b64(data: bytes) -> str:
    import base64
    return base64.b64encode(data).decode("ascii")


def _b64d(s: str) -> bytes:
    import base64
    return base64.b64decode(s)
