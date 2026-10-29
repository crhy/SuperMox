"""SuperMox cluster secret: 12-word BIP39 phrase and HKDF key derivation.

Implements step 1 of docs/node-join-architecture.md. The phrase is 128
uniformly random bits (16 bytes) encoded as a 12-word BIP39 English mnemonic.
Every derived key comes from HKDF-SHA256 with a fixed salt and info label.
Nothing here ever logs, prints or writes the phrase or the derived keys.
"""

import ipaddress
import os

from mnemonic import Mnemonic
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# Protocol constants. These labels and the salt version are part of the
# protocol and must never change; a new scheme gets a new salt version.
_SALT = b"supermox-cluster-v1"
_WORD_COUNT = 12
_ENTROPY_BYTES = 16

_LABELS = {
    "cluster_id": (b"cluster-id", 16),
    "join_key": (b"join-key", 32),
    "invite_key": (b"invite-key", 32),
    "wg_psk": (b"wireguard-psk", 32),
    "overlay_prefix": (b"overlay-prefix", 5),
}

_MNEMONIC = Mnemonic("english")


def generate() -> str:
    """Return a fresh 12-word BIP39 phrase from 16 bytes of os.urandom."""
    return _MNEMONIC.to_mnemonic(os.urandom(_ENTROPY_BYTES))


def normalize(phrase: str) -> str:
    """Lowercase, collapse whitespace to single spaces, strip."""
    return " ".join(phrase.split())


def validate(phrase: str) -> None:
    """Raise ValueError unless phrase is 12 valid BIP39 words with a good checksum."""
    words = normalize(phrase).split(" ")
    if len(words) != _WORD_COUNT:
        raise ValueError(
            "phrase must be exactly %d words, got %d" % (_WORD_COUNT, len(words))
        )
    wordlist = _MNEMONIC.wordlist
    for word in words:
        if word not in wordlist:
            raise ValueError("word %r is not in the BIP39 English word list" % word)
    if not _MNEMONIC.check(" ".join(words)):
        raise ValueError("phrase has an invalid BIP39 checksum (typo?)")


def entropy(phrase: str) -> bytes:
    """Return the 16 entropy bytes for a validated phrase."""
    validate(phrase)
    return _MNEMONIC.to_entropy(normalize(phrase))


def _hkdf(info: bytes, length: int, e: bytes) -> bytes:
    return HKDF(
        algorithm=hashes.SHA256(),
        length=length,
        salt=_SALT,
        info=info,
    ).derive(e)


def derive(phrase: str) -> dict:
    """Derive the five cluster values from a validated phrase."""
    e = entropy(phrase)
    out = {}
    for name, (info, length) in _LABELS.items():
        out[name] = _hkdf(info, length, e)
    # overlay_prefix is a ULA IPv6 /48: "fd" + the 5 derived bytes as hex.
    prefix = out["overlay_prefix"]
    hexpart = (b"\xfd" + prefix).hex()
    out["overlay_prefix"] = "%s:%s:%s::/48" % (
        hexpart[0:4],
        hexpart[4:8],
        hexpart[8:12],
    )
    return out


def _prefix_bytes(derived: dict) -> bytes:
    """Recover the 6 fixed prefix bytes from a derived overlay_prefix string."""
    text = derived["overlay_prefix"]
    head = text.split("::")[0]
    return bytes.fromhex(head.replace(":", ""))


def node_address(phrase_or_derived, wg_pub: bytes) -> str:
    """Full IPv6 address inside the cluster /48 for a node's WireGuard public key."""
    if isinstance(phrase_or_derived, dict):
        derived = phrase_or_derived
        if "entropy" not in derived:
            raise ValueError(
                "derived dict must carry 'entropy' bytes to compute node_address"
            )
        e = derived["entropy"]
        prefix = _prefix_bytes(derived)
    else:
        e = entropy(phrase_or_derived)
        prefix = _hkdf(_LABELS["overlay_prefix"][0], 5, e)
        prefix = b"\xfd" + prefix
    tail = _hkdf(b"node-addr" + wg_pub, 8, e)
    # 6 prefix bytes + 8 node bytes + 2 zero bytes = 16-byte IPv6 address.
    raw = prefix + tail + b"\x00\x00"
    return str(ipaddress.IPv6Address(raw))
