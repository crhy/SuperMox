"""SuperMox node state: the files one node keeps under /etc/supermox.

Implements step 4 (part 1) of docs/node-join-architecture.md. A node's
state is a small set of JSON files under a base directory (default
/etc/supermox, overridable with SUPERMOX_ETC):

  cluster.keys      derived cluster keys as JSON, base64, mode 0600
  identity.json     this node's X25519 + Ed25519 keypairs (identity.save)
  membership.json   the signed membership list (joinproto.sign_membership)
  invites.json      open invites and the ids of invites already used
  pending.json      join requests waiting for a human decision

The 12-word phrase is never written to any of these files. cluster.keys
does carry the 16 entropy bytes: a member must be able to compute a
new node's overlay address (secret.node_address needs them), and the
words themselves are always regenerated from entropy by BIP39, never
stored. See the deviation note in .strata/notes-t48-joind.md.

A membership entry may also carry "syncthing_id": that member's Syncthing
device id, which supermox.sync uses to wire the home folder over the
overlay (docs/shared-home.md). It is optional and backwards compatible:
an entry without one just means that member's Syncthing is not enrolled
yet.
"""

import base64
import json
import os
import platform

from supermox import identity as node_identity
from supermox import invite as invite_mod
from supermox import joinproto, secret

DEFAULT_BASE = "/etc/supermox"

# Files making up a node's state.
_FILES = {
    "keys": "cluster.keys",
    "identity": "identity.json",
    "membership": "membership.json",
    "invites": "invites.json",
    "pending": "pending.json",
}

_BYTES_KEYS = ("cluster_id", "join_key", "invite_key", "wg_psk", "entropy")


def base_dir() -> str:
    """Base directory for node state: $SUPERMOX_ETC or /etc/supermox."""
    return os.environ.get("SUPERMOX_ETC") or DEFAULT_BASE


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _b64d(s: str) -> bytes:
    return base64.b64decode(s)


def _write_json(path: str, obj, mode: int = 0o600) -> None:
    """Write JSON atomically with restrictive permissions."""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, json.dumps(obj, indent=2, sort_keys=True).encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, mode)


def _read_json(path: str):
    """Return the parsed JSON object at path, or None if the file is absent."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


class NodeState:
    """One node's state: derived keys, identity, membership, invites, pending."""

    def __init__(self, base=None):
        self.base = str(base) if base else base_dir()
        self.derived = None
        self.identity = None
        self.membership = []
        self.signer_ed_pub = None
        self.open_invites = {}
        self.used_invites = set()
        self.pending = {}

    def path(self, name: str) -> str:
        """Full path of one of the state files."""
        return os.path.join(self.base, _FILES[name])

    # --- creation -------------------------------------------------

    def create_cluster(self, phrase: str, name: str, endpoints: list,
                      arch: str = None, caps: list = None) -> dict:
        """Create the cluster: this node becomes the only member.

        Returns this node's membership entry.
        """
        secret.validate(phrase)
        self.derived = secret.derive(phrase)
        self.derived["entropy"] = secret.entropy(phrase)
        self.identity = node_identity.new_identity()
        if arch is None:
            arch = _local_arch()
        if caps is None:
            caps = []
        member = {
            "name": name,
            "wg_pub": _b64(self.identity["wg_pub"]),
            "ed_pub": _b64(self.identity["ed_pub"]),
            "overlay_addr": secret.node_address(phrase, self.identity["wg_pub"]),
            "endpoints": list(endpoints),
            "arch": arch,
            "caps": list(caps),
            "role": "core",
        }
        self.membership = [member]
        self.save()
        return member

    # --- persistence ----------------------------------------------

    def load(self) -> bool:
        """Load every state file that exists. True if the cluster exists."""
        os.makedirs(self.base, mode=0o755, exist_ok=True)
        keys = _read_json(self.path("keys"))
        if keys is not None:
            self.derived = _load_keys(keys)
        ident = _read_json(self.path("identity"))
        if ident is not None:
            self.identity = node_identity.load(self.path("identity"))
        signed = _read_json(self.path("membership"))
        if signed is not None:
            self.membership = list(signed["list"])
            self.signer_ed_pub = _b64d(signed["signer"])
        invites = _read_json(self.path("invites"))
        if invites is not None:
            self.open_invites = {
                e["invite_id"]: _load_invite(e)
                for e in invites.get("open", [])
            }
            self.used_invites = set(invites.get("used", []))
        pending = _read_json(self.path("pending"))
        if pending is not None:
            self.pending = dict(pending.get("pending", {}))
        return self.derived is not None

    def save(self) -> None:
        """Write every state file. Keys and identity are mode 0600."""
        os.makedirs(self.base, mode=0o755, exist_ok=True)
        if self.derived is not None:
            _write_json(self.path("keys"), _dump_keys(self.derived))
        if self.identity is not None:
            node_identity.save(self.identity, self.path("identity"))
        if self.membership:
            signed = joinproto.sign_membership(self.membership, self.identity)
            _write_json(self.path("membership"), signed)
            self.signer_ed_pub = _b64d(signed["signer"])
        _write_json(self.path("invites"), {
            "open": [_dump_invite(i) for i in self.open_invites.values()],
            "used": sorted(self.used_invites),
        })
        _write_json(self.path("pending"), {"pending": self.pending})

    # --- membership -----------------------------------------------

    def find_member(self, name: str):
        """Return the membership entry with this name, or None."""
        for m in self.membership:
            if m["name"] == name:
                return m
        return None

    def add_member(self, entry: dict) -> list:
        """Append a member and re-sign the list with this node's Ed25519 key."""
        if self.find_member(entry["name"]) is not None:
            raise ValueError("member %r already in the cluster" % entry["name"])
        self.membership = self.membership + [entry]
        self.save()
        return list(self.membership)

    def remove_member(self, name: str) -> list:
        """Drop a member and re-sign the list with this node's Ed25519 key."""
        self.membership = [m for m in self.membership if m["name"] != name]
        self.save()
        return list(self.membership)

    def set_syncthing_id(self, name: str, syncthing_id: str) -> list:
        """Record a member's Syncthing device id and re-sign the list.

        Each node runs this for its own entry once Syncthing has generated
        a device id (supermox-sync reconcile does it), then the new list
        is broadcast, so members learn each other's ids without a human
        accepting a host in the Syncthing GUI.
        """
        found = False
        for m in self.membership:
            if m["name"] == name:
                m["syncthing_id"] = syncthing_id
                found = True
        if not found:
            raise ValueError("%r is not a member of this cluster" % name)
        self.save()
        return list(self.membership)

    def trusted_ed_pubs(self) -> list:
        """Ed25519 public keys of every current member (raw bytes)."""
        return [_b64d(m["ed_pub"]) for m in self.membership]

    def accept_membership(self, signed: dict) -> list:
        """Verify a signed membership change against current members, adopt it."""
        lst = joinproto.verify_membership(signed, self.trusted_ed_pubs())
        self.membership = lst
        self.save()
        return lst

    # --- invites -------------------------------------------------

    def my_endpoints(self) -> list:
        """Endpoints this node advertises (from its own membership entry)."""
        me = self.find_member(self.my_name())
        return list(me["endpoints"]) if me else []

    def new_invite(self, ttl: int = 900) -> dict:
        """Create a single-use invite signed by this node's Ed25519 fingerprint."""
        inv = invite_mod.create(
            self.derived,
            self.my_endpoints(),
            node_identity.fingerprint(self.identity["ed_pub"]),
            ttl=ttl,
        )
        self.open_invites[_b64(inv["invite_id"])] = inv
        self.save()
        return inv

    def used_invite_ids(self) -> set:
        """Base64 invite ids this node has already consumed."""
        return set(self.used_invites)

    def mark_invite_used(self, invite_id: bytes) -> None:
        """Record an invite as consumed and drop it from the open set."""
        key = _b64(invite_id)
        self.used_invites.add(key)
        self.open_invites.pop(key, None)
        self.save()

    def my_name(self):
        """This node's own name in the membership list."""
        if not self.membership:
            return None
        for m in self.membership:
            if m["ed_pub"] == _b64(self.identity["ed_pub"]):
                return m["name"]
        return self.membership[0]["name"]

    # --- approval queue ------------------------------------------

    def add_pending(self, record: dict) -> str:
        """Queue a join request for a human decision; return its id."""
        request_id = _b64(os.urandom(8))
        self.pending[request_id] = record
        self.save()
        return request_id

    def take_pending(self, request_id: str) -> dict:
        """Remove and return a pending request, or None if it is not queued."""
        record = self.pending.pop(request_id, None)
        self.save()
        return record


def _local_arch() -> str:
    """Best-effort local architecture name (uname -m)."""
    return platform.machine()


def _dump_keys(derived: dict) -> dict:
    """Serialize derived keys for cluster.keys (base64, never the phrase)."""
    out = {"v": 1, "overlay_prefix": derived["overlay_prefix"]}
    for name in _BYTES_KEYS:
        out[name] = _b64(derived[name])
    return out


def _load_keys(data: dict) -> dict:
    """Inverse of _dump_keys."""
    derived = {"overlay_prefix": data["overlay_prefix"]}
    for name in _BYTES_KEYS:
        derived[name] = _b64d(data[name])
    return derived


def _dump_invite(inv: dict) -> dict:
    """Serialize an invite (public parts only, never the _keys assertion list)."""
    return {
        "invite_id": _b64(inv["invite_id"]),
        "expiry": inv["expiry"],
        "token": _b64(inv["token"]),
        "cluster_id": _b64(inv["cluster_id"]),
        "signer_fingerprint": _b64(inv["signer_fingerprint"]),
        "endpoints": list(inv["endpoints"]),
    }


def _load_invite(data: dict) -> dict:
    """Inverse of _dump_invite."""
    return {
        "invite_id": _b64d(data["invite_id"]),
        "expiry": data["expiry"],
        "token": _b64d(data["token"]),
        "cluster_id": _b64d(data["cluster_id"]),
        "signer_fingerprint": _b64d(data["signer_fingerprint"]),
        "endpoints": list(data["endpoints"]),
    }
