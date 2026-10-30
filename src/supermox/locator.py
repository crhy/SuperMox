"""SuperMox locator: layer 3 of the discovery section in docs/node-join-architecture.md.

Every node publishes its endpoints to the existing BitTorrent "mainline" DHT
under a mutable item whose key is

    HKDF(E, "dht-locator" + node_id + current UTC day)   -> 20 bytes

where E is the cluster's 16 entropy bytes (``secret.entropy(phrase)``, kept in
node state as ``derived["entropy"]``).  The value is the node's signed gossip
record from ``gossip.make_record``, encrypted with the cluster ``join_key``
(libsodium secretbox).  Outsiders see random keys that change every day and
opaque bytes; members can compute the keys and check the signatures.

Records are refreshed every ``REFRESH_SECONDS`` (30 minutes) and expire after
``EXPIRE_SECONDS`` (2 hours), so ``keys_to_query`` returns yesterday's key as
well as today's: near midnight UTC a record published under the old day's key
is still alive for up to two hours.  Mainline DHT mutable values (BEP44) are
capped at 1000 bytes, so ``seal`` refuses to produce a larger one.

Pure Python, no network and no DHT client yet: talking to the DHT belongs to
the join daemon, not here.
"""

import datetime
import json

from nacl.exceptions import CryptoError
from nacl.secret import SecretBox

from supermox import gossip
from supermox.joinproto import _canonical
from supermox.secret import _hkdf

# Refresh a published record every 30 minutes; a DHT node drops it after 2
# hours, which is the window in which yesterday's key still resolves.
REFRESH_SECONDS = 1800
EXPIRE_SECONDS = 7200

# Mainline DHT key length for mutable items, and BEP44's value cap.
_KEY_BYTES = 20
_MAX_VALUE = 1000


def _utc_day(now) -> datetime.date:
    """UTC calendar day for a POSIX timestamp."""
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    return datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date()


def locator_key(entropy: bytes, node_id: str, day: datetime.date) -> bytes:
    """The 20-byte DHT key for node_id's record on UTC day `day`.

    Same inputs always give the same key; a different node, a different day
    or a different cluster (different entropy) gives a different one.
    """
    if len(entropy) != 16:
        raise ValueError("entropy must be the cluster's 16 entropy bytes")
    if not isinstance(node_id, str) or not node_id:
        raise ValueError("node_id must be a non-empty string")
    info = (b"dht-locator" + node_id.encode("utf-8")
            + day.isoformat().encode("utf-8"))
    return _hkdf(info, _KEY_BYTES, entropy)


def seal(record: dict, join_key: bytes, identity: dict) -> bytes:
    """Encrypt a node's own signed gossip record for publication.

    The record must verify against ``identity``'s own Ed25519 key, so a node
    can only publish records it really signed.  Raises ValueError if the
    encrypted value would not fit a BEP44 mutable value (1000 bytes).
    """
    if not gossip.verify_record(record, identity["ed_pub"]):
        raise ValueError("record is not signed by identity's Ed25519 key")
    blob = bytes(SecretBox(join_key).encrypt(_canonical(record)))
    if len(blob) > _MAX_VALUE:
        raise ValueError(
            "sealed record is %d bytes, over the %d byte DHT value limit"
            % (len(blob), _MAX_VALUE)
        )
    return blob


def open_sealed(blob: bytes, join_key: bytes, members: dict) -> dict:
    """Decrypt a published value and check it against the membership list.

    ``members`` maps node_id -> ed_pub, exactly as in ``gossip.merge``.  Raises
    ValueError on every failure: wrong join_key or tampered bytes, value that
    is not a JSON record, a node that is not a member, or a bad signature.
    """
    try:
        plain = bytes(SecretBox(join_key).decrypt(blob))
    except (CryptoError, ValueError) as exc:
        raise ValueError("cannot decrypt: wrong join_key or corrupt value"
                         ) from exc
    try:
        record = json.loads(plain.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("value is not canonical JSON") from exc
    if not isinstance(record, dict):
        raise ValueError("value is not a JSON object")
    ed_pub = members.get(record.get("node"))
    if ed_pub is None:
        raise ValueError("record's node is not a member of the cluster")
    if not gossip.verify_record(record, ed_pub):
        raise ValueError("record's signature does not verify for its member")
    return record


def keys_to_query(entropy: bytes, node_ids, now=None) -> list:
    """Every key a member's record may still resolve under.

    Today's key and yesterday's key for each node, in that order, so a record
    published shortly before midnight UTC is still found after the day rolls
    over.  Returns two keys per node id.
    """
    today = _utc_day(now)
    yesterday = today - datetime.timedelta(days=1)
    keys = []
    for node_id in node_ids:
        keys.append(locator_key(entropy, node_id, today))
        keys.append(locator_key(entropy, node_id, yesterday))
    return keys
