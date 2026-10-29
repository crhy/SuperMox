"""SuperMox join protocol: JOIN_REQ, JOIN_ACK, invite messages, signed membership.

Implements step 3 of docs/node-join-architecture.md.  Pure functions, no
sockets.  All messages are JSON dicts with a "v": 1 version field.
"""

import hashlib
import json
import os
import time

from nacl.public import Box as CurveBox, PrivateKey as X25519Private, PublicKey
from nacl.secret import SecretBox
from nacl.signing import SigningKey, VerifyKey
from nacl.exceptions import BadSignatureError, CryptoError

_VERSION = 1
_MAX_SKEW = 300       # seconds; reject |now - time| > 300
_NONCE_WINDOW = 600   # seconds; reject a nonce seen in the last 600 s


def _canonical(obj) -> bytes:
    """Canonical JSON encoding used for signing."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


# --- JOIN_REQ (phrase path) ---


def make_join_req(derived: dict, identity: dict, name: str, arch: str,
                  caps: list, now=None) -> bytes:
    """Encrypt a JOIN_REQ message with the cluster join_key (SecretBox)."""
    if now is None:
        now = int(time.time())
    msg = {
        "v": _VERSION,
        "cluster_id": _b64s(derived["cluster_id"]),
        "name": name,
        "wg_pub": _b64s(identity["wg_pub"]),
        "ed_pub": _b64s(identity["ed_pub"]),
        "arch": arch,
        "caps": caps,
        "time": now,
        "nonce": _b64s(os.urandom(16)),
    }
    box = SecretBox(derived["join_key"])
    return box.encrypt(_canonical(msg))


def open_join_req(derived: dict, blob: bytes, now=None,
                  seen_nonces: dict = None) -> dict:
    """Decrypt and validate a JOIN_REQ.

    Raises ValueError on: bad MAC, wrong cluster_id, clock skew > 300 s,
    or a replayed nonce (seen in the last 600 s).
    Prunes entries older than 600 s from seen_nonces.
    """
    if now is None:
        now = int(time.time())
    if seen_nonces is None:
        seen_nonces = {}

    box = SecretBox(derived["join_key"])
    try:
        plaintext = box.decrypt(blob)
    except CryptoError:
        raise ValueError("bad MAC (wrong key or corrupted blob)")

    msg = json.loads(plaintext.decode("utf-8"))

    # Check version.
    if msg.get("v") != _VERSION:
        raise ValueError("unknown version")

    # Check cluster.
    if _b64d(msg["cluster_id"]) != derived["cluster_id"]:
        raise ValueError("wrong cluster_id")

    # Check clock skew.
    msg_time = msg["time"]
    if abs(now - msg_time) > _MAX_SKEW:
        raise ValueError("clock skew exceeds %d s" % _MAX_SKEW)

    # Check nonce replay.
    nonce_bytes = _b64d(msg["nonce"])
    # Prune old entries.
    cutoff = now - _NONCE_WINDOW
    expired = [k for k, t in seen_nonces.items() if t < cutoff]
    for k in expired:
        del seen_nonces[k]
    if nonce_bytes in seen_nonces:
        raise ValueError("replayed nonce")
    seen_nonces[nonce_bytes] = now

    return msg


# --- JOIN_ACK (phrase path) ---


def make_join_ack(derived: dict, membership: list, overlay_addr: str,
                  signer_identity: dict) -> bytes:
    """Encrypt a JOIN_ACK with the cluster join_key.

    The membership list is signed by signer_identity.
    """
    signed = sign_membership(membership, signer_identity)
    msg = {
        "v": _VERSION,
        "membership": signed["list"],
        "signature": signed["signature"],
        "signer": _b64s(signer_identity["ed_pub"]),
        "overlay_addr": overlay_addr,
    }
    box = SecretBox(derived["join_key"])
    return box.encrypt(_canonical(msg))


def open_join_ack(derived: dict, blob: bytes) -> dict:
    """Decrypt a JOIN_ACK and return the message dict."""
    box = SecretBox(derived["join_key"])
    try:
        plaintext = box.decrypt(blob)
    except CryptoError:
        raise ValueError("bad MAC (wrong key or corrupted blob)")
    msg = json.loads(plaintext.decode("utf-8"))
    if msg.get("v") != _VERSION:
        raise ValueError("unknown version")
    return msg


# --- Signed membership ---


def sign_membership(membership: list, identity: dict) -> dict:
    """Sign a membership list with the node's Ed25519 key.

    Returns {"list": membership, "signature": base64 sig, "signer": base64 ed_pub}.
    """
    sk = SigningKey(identity["ed_priv"])
    sig = sk.sign(_canonical(membership)).signature
    return {
        "list": membership,
        "signature": _b64s(sig),
        "signer": _b64s(identity["ed_pub"]),
    }


def verify_membership(signed: dict, trusted_ed_pubs: list) -> list:
    """Verify a signed membership change against trusted Ed25519 public keys.

    Raises ValueError if no trusted key matches.  Returns the membership list.
    """
    sig_bytes = _b64d(signed["signature"])
    signer_pub = _b64d(signed["signer"])
    payload = _canonical(signed["list"])

    # The signer must be in the trusted set.
    if signer_pub not in trusted_ed_pubs:
        raise ValueError("signer not in trusted set")

    # Verify the signature.
    try:
        vk = VerifyKey(signer_pub)
        vk.verify(payload, sig_bytes)
    except BadSignatureError:
        raise ValueError("bad signature")

    return signed["list"]


# --- Invite path: challenge-response ---


def challenge() -> bytes:
    """Generate a 32-byte random challenge for the invite handshake."""
    return os.urandom(32)


def answer_challenge(identity: dict, ch: bytes) -> bytes:
    """Sign a challenge with the node's Ed25519 private key."""
    sk = SigningKey(identity["ed_priv"])
    return sk.sign(ch).signature


def check_challenge(fp: bytes, ed_pub: bytes, ch: bytes, sig: bytes) -> bool:
    """Verify that ed_pub matches fingerprint fp and that sig is a valid
    signature of ch by ed_pub.  Returns True on success, raises ValueError
    on failure."""
    # Check fingerprint matches.
    if hashlib.sha256(ed_pub).digest()[:16] != fp:
        raise ValueError("ed_pub does not match fingerprint")
    # Verify signature.
    try:
        vk = VerifyKey(ed_pub)
        vk.verify(ch, sig)
    except BadSignatureError:
        raise ValueError("bad challenge signature")
    return True


# --- Invite REQ (asymmetric Box) ---


def make_invite_req(member_curve_pub: bytes, invite: dict,
                    new_identity: dict, name: str, arch: str,
                    caps: list) -> bytes:
    """Encrypt an invite request using a fresh ephemeral X25519 key.

    The ephemeral public key is prepended to the ciphertext so the
    member can decrypt with their own private key.
    """
    eph_priv = X25519Private.generate()
    eph_pub = eph_priv.public_key

    msg = {
        "v": _VERSION,
        "invite_id": _b64s(invite["invite_id"]),
        "expiry": invite["expiry"],
        "token": _b64s(invite["token"]),
        "name": name,
        "wg_pub": _b64s(new_identity["wg_pub"]),
        "ed_pub": _b64s(new_identity["ed_pub"]),
        "arch": arch,
        "caps": caps,
    }

    box = CurveBox(eph_priv, PublicKey(member_curve_pub))
    ct = box.encrypt(_canonical(msg))
    # Prepend ephemeral public key (32 bytes).
    return bytes(eph_pub) + ct


def open_invite_req(member_identity: dict, blob: bytes) -> dict:
    """Decrypt an invite request using the member's X25519 private key."""
    eph_pub = blob[:32]
    ct = blob[32:]
    box = CurveBox(X25519Private(member_identity["wg_priv"]), PublicKey(eph_pub))
    plaintext = box.decrypt(ct)
    msg = json.loads(plaintext.decode("utf-8"))
    if msg.get("v") != _VERSION:
        raise ValueError("unknown version")
    return msg


# --- Invite ACK ---


def make_invite_ack(derived: dict, membership: list,
                    signer_identity: dict) -> bytes:
    """Encrypt an invite ACK carrying membership + derived keys (NOT the phrase).

    The membership is signed by signer_identity.
    """
    signed = sign_membership(membership, signer_identity)
    msg = {
        "v": _VERSION,
        "membership": signed["list"],
        "signature": signed["signature"],
        "signer": _b64s(signer_identity["ed_pub"]),
        "join_key": _b64s(derived["join_key"]),
        "invite_key": _b64s(derived["invite_key"]),
        "wg_psk": _b64s(derived["wg_psk"]),
        "overlay_prefix": derived["overlay_prefix"],
    }
    box = SecretBox(derived["join_key"])
    return box.encrypt(_canonical(msg))


def open_invite_ack(derived: dict, blob: bytes) -> dict:
    """Decrypt an invite ACK and return the message dict."""
    box = SecretBox(derived["join_key"])
    try:
        plaintext = box.decrypt(blob)
    except CryptoError:
        raise ValueError("bad MAC (wrong key or corrupted blob)")
    msg = json.loads(plaintext.decode("utf-8"))
    if msg.get("v") != _VERSION:
        raise ValueError("unknown version")
    return msg


# --- base64 helpers ---


def _b64s(data: bytes) -> str:
    import base64
    return base64.b64encode(data).decode("ascii")


def _b64d(s: str) -> bytes:
    import base64
    return base64.b64decode(s)
