"""SuperMox QR invite: create, encode, parse, verify and render join invites.

Implements step 2 of docs/node-join-architecture.md.  The invite URI
carries no key material: the HMAC token proves the invite was created by
a node that holds the cluster secret, and the QR never contains the
12-word phrase or any derived key.
"""

import base64
import hashlib
import hmac
import io
import os
import time
from urllib.parse import quote, unquote, urlparse, parse_qs

import qrcode

_VERSION = 1
_DEFAULT_TTL = 900  # 15 minutes


def _b32(data: bytes) -> str:
    """RFC 2638 base32, lowercase, no padding."""
    return base64.b32encode(data).decode("ascii").lower().rstrip("=")


def _b32_decode(s: str) -> bytes:
    """Decode base32 (lowercase, no padding) back to bytes."""
    pad = "=" * ((8 - len(s) % 8) % 8)
    return base64.b32decode(s.upper() + pad)


def create(derived: dict, endpoints: list, signer_fingerprint: bytes,
           now=None, ttl=_DEFAULT_TTL) -> dict:
    """Create a single-use invite valid for *ttl* seconds.

    Returns a dict with invite_id, expiry, token, cluster_id,
    signer_fingerprint, endpoints, and the 32-byte keys (for the
    to_uri assertion).
    """
    if now is None:
        now = int(time.time())
    invite_id = os.urandom(16)
    expiry = now + ttl
    cluster_id = derived["cluster_id"]
    invite_key = derived["invite_key"]
    # token = HMAC-SHA256(invite_key, cluster_id || invite_id || expiry_be64)[:16]
    msg = cluster_id + invite_id + expiry.to_bytes(8, "big")
    token = hmac.new(invite_key, msg, hashlib.sha256).digest()[:16]
    return {
        "invite_id": invite_id,
        "expiry": expiry,
        "token": token,
        "cluster_id": cluster_id,
        "signer_fingerprint": signer_fingerprint,
        "endpoints": list(endpoints),
        "_keys": [derived["join_key"], derived["invite_key"], derived["wg_psk"]],
    }


def to_uri(invite: dict) -> str:
    """Encode an invite as a supermox://join URI.

    Asserts that none of the 32-byte derived keys leak into the URI.
    """
    # Assertion: no 32-byte key material may appear in the URI.
    uri = _build_uri(invite)
    for key in invite["_keys"]:
        assert _b32(key) not in uri, "key material leaked into URI"
        assert key.hex() not in uri, "key material leaked into URI (hex)"
    return uri


def _build_uri(invite: dict) -> str:
    """Build the supermox://join URI from an invite dict."""
    parts = [
        "v=1",
        "c=" + _b32(invite["cluster_id"]),
        "i=" + _b32(invite["invite_id"]),
        "x=" + str(invite["expiry"]),
        "t=" + _b32(invite["token"]),
        "f=" + _b32(invite["signer_fingerprint"]),
    ]
    for ep in invite["endpoints"]:
        parts.append("e=" + quote(ep, safe=""))
    return "supermox://join?" + "&".join(parts)


def parse_uri(uri: str) -> dict:
    """Parse a supermox://join URI strictly.

    Raises ValueError on unknown scheme, unknown version, or missing fields.
    """
    parsed = urlparse(uri)
    if parsed.scheme != "supermox":
        raise ValueError("unknown scheme: %r" % parsed.scheme)
    if parsed.netloc != "join":
        raise ValueError("unknown path: %r" % parsed.netloc)
    qs = parse_qs(parsed.query, keep_blank_values=True)

    # Check version.
    v = qs.get("v")
    if v is None:
        raise ValueError("missing version field 'v'")
    if v[0] != "1":
        raise ValueError("unknown version: %r" % v[0])

    # Required fields.
    for field in ("c", "i", "x", "t", "f"):
        if field not in qs:
            raise ValueError("missing required field %r" % field)

    cluster_id = _b32_decode(qs["c"][0])
    invite_id = _b32_decode(qs["i"][0])
    expiry = int(qs["x"][0])
    token = _b32_decode(qs["t"][0])
    signer_fingerprint = _b32_decode(qs["f"][0])
    endpoints = [unquote(e) for e in qs.get("e", [])]

    return {
        "invite_id": invite_id,
        "expiry": expiry,
        "token": token,
        "cluster_id": cluster_id,
        "signer_fingerprint": signer_fingerprint,
        "endpoints": endpoints,
    }


def verify(derived: dict, invite: dict, now=None, used=None) -> bool:
    """Verify an invite against the cluster's derived keys.

    Raises ValueError naming the reason on failure:
    wrong cluster, bad token, expired, already used.
    """
    if used is None:
        used = set()
    if now is None:
        now = int(time.time())

    # Check cluster.
    if invite["cluster_id"] != derived["cluster_id"]:
        raise ValueError("wrong cluster")

    # Check expiry.
    if now >= invite["expiry"]:
        raise ValueError("expired")

    # Recompute token.
    invite_key = derived["invite_key"]
    msg = (invite["cluster_id"] + invite["invite_id"]
           + invite["expiry"].to_bytes(8, "big"))
    expected = hmac.new(invite_key, msg, hashlib.sha256).digest()[:16]
    if not hmac.compare_digest(invite["token"], expected):
        raise ValueError("bad token")

    # Check single use.
    if invite["invite_id"] in used:
        raise ValueError("already used")

    return True


def render_png(uri: str, path: str) -> None:
    """Render a QR code for the invite URI as a PNG file."""
    qr = qrcode.QRCode()
    qr.add_data(uri)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    img.save(path)


def render_text(uri: str) -> str:
    """Render a QR code for the invite URI as terminal text (ASCII blocks)."""
    qr = qrcode.QRCode()
    qr.add_data(uri)
    qr.make(fit=True)
    buf = io.StringIO()
    qr.print_ascii(out=buf)
    return buf.getvalue()
