"""SuperMox gossip: signed endpoint records and their merge rules.

Implements layer 1 of the discovery section in docs/node-join-architecture.md.
Every member keeps the last known endpoints of every other member as signed
records of the form::

    {"node": ..., "endpoints": [...], "seq": ..., "time": ..., "sig": ...}

and exchanges them with every peer it can reach.  Reaching one member is
enough to learn where all the others are: the records travel over the
overlay, and only members can sign them, so nobody outside the cluster can
forge them.

A node signs with its own Ed25519 key (``identity["ed_priv"]``) and a
receiver checks with the matching public key taken from the signed
membership list, so membership is the root of trust for gossip.  ``seq``
is a per-node counter the node bumps whenever its endpoints change; it,
not wall-clock time, decides which record wins.  ``time`` is only used to
reject records claiming to be from the future.

Pure Python, no network: the transport (which peer to ask, when) belongs
to the join daemon, not here.
"""

import base64
import time

from nacl.signing import SigningKey, VerifyKey
from nacl.exceptions import BadSignatureError

from supermox.joinproto import _canonical

# A record whose time is more than this many seconds in the future is
# rejected: it is either a clock error or a hostile record.
FUTURE_SKEW = 600


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _b64d(s: str) -> bytes:
    return base64.b64decode(s)


def make_record(identity: dict, node_id: str, endpoints: list,
                seq: int, now=None) -> dict:
    """Sign one endpoint record for node_id with identity's Ed25519 key.

    The signature covers the canonical JSON of every field except "sig"
    itself, so tampering with any of them breaks verification.
    """
    record = {
        "node": node_id,
        "endpoints": list(endpoints),
        "seq": int(seq),
        "time": int(now) if now is not None else int(time.time()),
    }
    key = SigningKey(identity["ed_priv"])
    record["sig"] = _b64(key.sign(_canonical(record)).signature)
    return record


def verify_record(record: dict, ed_pub: bytes) -> bool:
    """True if record's signature is a valid Ed25519 signature by ed_pub."""
    if "sig" not in record:
        return False
    payload = {k: v for k, v in record.items() if k != "sig"}
    try:
        VerifyKey(ed_pub).verify(_canonical(payload), _b64d(record["sig"]))
    except (BadSignatureError, ValueError, TypeError):
        return False
    return True


def _wellformed(record: dict) -> bool:
    """True if a record carries every field with a sane type.

    A member could still sign a malformed record, so shape is checked here
    rather than trusting the fields to be there.
    """
    if not isinstance(record.get("node"), str):
        return False
    if not isinstance(record.get("endpoints"), list):
        return False
    seq, stamp = record.get("seq"), record.get("time")
    if not isinstance(seq, int) or isinstance(seq, bool):
        return False
    if not isinstance(stamp, int) or isinstance(stamp, bool):
        return False
    return isinstance(record.get("sig"), str)


def merge(known: dict, incoming: list, members: dict, now=None) -> list:
    """Merge incoming records into this node's view of the cluster.

    ``known`` maps node_id -> the newest record we hold for it and is
    updated in place.  ``members`` maps node_id -> ed_pub taken from the
    signed membership list, and is the only reason a record is trusted.

    A record is accepted only if all of these hold:

    * its node is a member of the cluster;
    * it verifies against that member's Ed25519 public key;
    * its time is not more than FUTURE_SKEW seconds in the future;
    * its seq is higher than the seq we already hold for that node
      (an equal seq keeps the old record, so ties never flip-flop).

    Returns the node_ids that changed, in the order they first changed.
    """
    if now is None:
        now = time.time()
    changed = []
    for record in incoming:
        if not _wellformed(record):
            continue
        node = record.get("node")
        ed_pub = members.get(node)
        if ed_pub is None:
            continue
        if not verify_record(record, ed_pub):
            continue
        if record["time"] > int(now) + FUTURE_SKEW:
            continue
        current = known.get(node)
        if current is not None and record["seq"] <= current["seq"]:
            continue
        known[node] = record
        if node not in changed:
            changed.append(node)
    return changed


def digest(known: dict) -> dict:
    """Summarise our view as node_id -> seq, cheap enough to send to a peer."""
    return {node: int(record["seq"]) for node, record in known.items()}


def wanted(known: dict, peer_digest: dict) -> list:
    """Records to send a peer: the ones it lacks, or has at an older seq.

    Two nodes exchange only differences, so steady-state gossip traffic is
    just the two digests.
    """
    out = []
    for record in known.values():
        if int(peer_digest.get(record["node"], -1)) < int(record["seq"]):
            out.append(record)
    return out
