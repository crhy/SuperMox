"""SuperMox join daemon: the TCP endpoint other nodes join through.

Implements step 4 of docs/node-join-architecture.md:

  * a phrase join (JOIN_REQ / JOIN_ACK) when the joiner already knows the
    cluster words,
  * an invite join (challenge / answer / INVITE_REQ / approval / INVITE_ACK)
    when it only has an invite,
  * the pending approval queue (supermox-join approve / deny),
  * the WireGuard configuration writer (/etc/supermox/wg0.conf).

Framing
-------
Every message is a 4-byte big-endian length followed by one kind byte and
the payload: kind 1 is JSON, kind 2 is a crypto blob (SecretBox / CurveBox
ciphertext). Frames longer than MAX_FRAME are dropped without being read
further, and nothing about a dropped frame's payload is ever logged.

The daemon never brings the overlay up: it writes wg0.conf and leaves
``wg-quick up`` to the operator.
"""

import argparse
import asyncio
import base64
import json
import logging
import os
import sys
import time

from nacl.exceptions import CryptoError
from nacl.encoding import Base64Encoder
from nacl.public import Box as CurveBox
from nacl.public import PrivateKey, PublicKey

from supermox import identity as identity_mod
from supermox import invite as invite_mod
from supermox import joinproto
from supermox import secret
from supermox import state as node_state

DEFAULT_PORT = 8743
MAX_FRAME = 65536                 # 64 KiB
KIND_JSON = 1
KIND_BYTES = 2
APPROVAL_TIMEOUT = 300.0          # seconds a pending invite waits for a decision
WG_CONF_PATH = "/etc/supermox/wg0.conf"
WG_LISTEN_PORT = 51820            # WireGuard tunnel port (UDP), same on every node

log = logging.getLogger("supermox-joind")


class JoinError(Exception):
    """A join, invite or protocol failure, reported to the user by the CLI."""


class FrameTooLarge(Exception):
    """Raised when a peer sends a frame bigger than MAX_FRAME."""


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def b64d(text: str) -> bytes:
    return base64.b64decode(text)


def canonical_json(obj: dict) -> bytes:
    """The bytes both sides put in a JSON frame (sorted keys, no spaces)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def parse_endpoint(text: str) -> tuple:
    """Split "host:port" (or bare "host") into (host, port)."""
    host, sep, port = text.rpartition(":")
    if not sep:
        return text, DEFAULT_PORT
    try:
        return host, int(port)
    except ValueError:
        raise JoinError("bad endpoint: %r" % text)


async def write_frame(writer, kind: int, payload: bytes) -> None:
    body = bytes((kind,)) + payload
    if len(body) > MAX_FRAME + 1:
        raise JoinError("frame too large: %d bytes" % len(body))
    writer.write(len(body).to_bytes(4, "big") + body)
    await writer.drain()


async def read_frame(reader):
    head = await reader.readexactly(4)
    size = int.from_bytes(head, "big")
    if size < 1 or size > MAX_FRAME + 1:
        raise FrameTooLarge("frame size %d exceeds %d" % (size, MAX_FRAME))
    body = await reader.readexactly(size)
    return body[0], body[1:]


def seal_for_joiner(member_identity: dict, joiner_wg_pub: bytes, obj: dict) -> bytes:
    """Encrypt a JSON object for one specific joining node.

    The joining node does not hold join_key yet, so the keys that let it
    open its INVITE_ACK travel over the asymmetric channel instead: the
    member's wg_priv against the joiner's wg_pub (which the member learned
    from the INVITE_REQ). The joiner opens it with its own wg_priv and the
    member's wg_pub (which it learned from the challenge), so only it can
    read it and only the member could have written it.
    """
    box = CurveBox(PrivateKey(member_identity["wg_priv"]),
                   PublicKey(joiner_wg_pub))
    return box.encrypt(canonical_json(obj))


def open_from_member(new_identity: dict, member_wg_pub: bytes, blob: bytes) -> dict:
    """Open a blob sealed by a member for this node (inverse of seal_for_joiner).

    The member's WireGuard public key comes from the challenge this node
    received. Raises CryptoError when the member's keypair was not the sender's.
    """
    box = CurveBox(PrivateKey(new_identity["wg_priv"]),
                   PublicKey(member_wg_pub))
    return json.loads(box.decrypt(blob).decode("utf-8"))


class _Conn:
    """Per-connection state inside the daemon."""

    def __init__(self):
        self.challenge = None     # 32 bytes handed out by challenge()
        self.answer_ed_pub = None  # ed_pub the joiner signed the challenge with
        self.pending_id = None     # pending request this connection waits on
        self.decision = None       # "allow" or "deny"
        self.record = None         # pending record shown to the operator
        self.event = None          # set when a decision arrives


class JoinDaemon:
    """The join daemon.

    One daemon serves one node's state. It accepts phrase joins and invite
    joins, queues invite joins for approval, and broadcasts signed membership
    changes to the other members' daemons.
    """

    def __init__(self, state: node_state.NodeState, host: str = "127.0.0.1",
                 port: int = DEFAULT_PORT, auto_approve: bool = False):
        self.state = state
        self.host = host
        self.port = port
        self.auto_approve = auto_approve
        self.seen_nonces = {}
        self.waiting = {}          # request_id -> _Conn
        self.server = None
        self._tasks = set()

    async def start(self):
        """Start listening. Returns the asyncio server object."""
        self.state.load()
        self.server = await asyncio.start_server(
            self.handle, self.host, self.port, reuse_address=True)
        return self.server

    async def serve(self) -> None:
        """Start listening and serve forever (used by init.d/supermox-joind)."""
        await self.start()
        async with self.server:
            await self.server.serve_forever()

    async def stop(self) -> None:
        """Close the listener and wait briefly for in-flight handlers.

        A handler parked on a pending approval (waiting for an operator who
        never arrives) is cancelled rather than held for the full timeout.
        """
        if self.server is not None:
            self.server.close()
        if self._tasks:
            done, pending = await asyncio.wait(list(self._tasks), timeout=2.0)
            for task in pending:
                task.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
        if self.server is not None:
            # Now that handlers are gone, the listener can finish closing.
            try:
                await asyncio.wait_for(self.server.wait_closed(), timeout=2.0)
            except asyncio.TimeoutError:
                pass

    async def handle(self, reader, writer) -> None:
        conn = _Conn()
        try:
            while True:
                try:
                    kind, payload = await read_frame(reader)
                except asyncio.IncompleteReadError:
                    break
                except FrameTooLarge as exc:
                    log.warning("dropped frame: %s", exc)
                    await write_frame(writer, KIND_JSON, canonical_json(
                        {"t": "error", "error": "frame too large"}))
                    break
                if kind == KIND_BYTES:
                    if not await self._bytes_message(conn, payload, writer):
                        break
                elif kind == KIND_JSON:
                    if not await self._json_message(conn, payload, writer):
                        break
                else:
                    log.warning("dropped frame: unknown kind %d", kind)
                    break
        except (ConnectionError, asyncio.LimitOverrunError):
            pass
        finally:
            if conn.pending_id is not None:
                self.waiting.pop(conn.pending_id, None)
            try:
                writer.close()
            except Exception:
                pass

    # --- bytes frames (crypto messages) --------------------------------

    async def _bytes_message(self, conn, blob, writer) -> bool:
        """Dispatch a SecretBox/CurveBox frame to the right path."""
        if conn.answer_ed_pub is not None:
            return await self._invite_req(conn, blob, writer)
        return await self._join_req(conn, blob, writer)

    def _entry_from(self, msg: dict) -> dict:
        """Membership entry built from a JOIN_REQ or INVITE_REQ."""
        return {
            "name": msg["name"],
            "wg_pub": msg["wg_pub"],
            "ed_pub": msg["ed_pub"],
            "overlay_addr": secret.node_address(self.state.derived,
                                                b64d(msg["wg_pub"])),
            "endpoints": [],
            "arch": msg["arch"],
            "caps": list(msg.get("caps") or []),
            "role": "core",
        }

    async def _join_req(self, conn, blob, writer) -> bool:
        """Phrase path: JOIN_REQ -> add member -> JOIN_ACK."""
        try:
            msg = joinproto.open_join_req(self.state.derived, blob,
                                          seen_nonces=self.seen_nonces)
        except ValueError as exc:
            log.warning("join_req dropped: %s", exc)
            await write_frame(writer, KIND_JSON, canonical_json(
                {"t": "refused", "reason": str(exc)}))
            return False
        entry = self._entry_from(msg)
        if self.state.find_member(entry["name"]) is None:
            membership = self.state.add_member(entry)
        else:
            membership = list(self.state.membership)
        ack = joinproto.make_join_ack(self.state.derived, membership,
                                      entry["overlay_addr"], self.state.identity)
        await write_frame(writer, KIND_BYTES, ack)
        await self._broadcast(membership)
        return True

    async def _invite_req(self, conn, blob, writer) -> bool:
        """Invite path: INVITE_REQ -> approval -> keys, INVITE_ACK."""
        try:
            msg = joinproto.open_invite_req(self.state.identity, blob)
        except (CryptoError, ValueError) as exc:
            log.warning("invite_req dropped: %s", exc)
            return False
        if msg["ed_pub"] != conn.answer_ed_pub:
            log.warning("invite_req refused: challenge answer was signed by "
                        "a different key")
            return False
        invite = {
            "invite_id": b64d(msg["invite_id"]),
            "expiry": msg["expiry"],
            "token": b64d(msg["token"]),
            "cluster_id": self.state.derived["cluster_id"],
        }
        try:
            invite_mod.verify(self.state.derived, invite,
                              used={b64d(x) for x
                                    in self.state.used_invite_ids()})
        except ValueError as exc:
            log.warning("invite refused: %s", exc)
            await write_frame(writer, KIND_JSON, canonical_json(
                {"t": "refused", "reason": str(exc)}))
            return False
        if not await self._approve(conn, invite["invite_id"], msg, writer):
            await write_frame(writer, KIND_JSON, canonical_json(
                {"t": "deny"}))
            return False
        entry = self._entry_from(msg)
        if self.state.find_member(entry["name"]) is None:
            membership = self.state.add_member(entry)
        else:
            membership = list(self.state.membership)
        self.state.mark_invite_used(invite["invite_id"])
        keys = seal_for_joiner(self.state.identity, b64d(entry["wg_pub"]), {
            "v": 1,
            "join_key": b64(self.state.derived["join_key"]),
            "cluster_id": b64(self.state.derived["cluster_id"]),
            "entropy": b64(self.state.derived["entropy"]),
        })
        await write_frame(writer, KIND_BYTES, keys)
        ack = joinproto.make_invite_ack(self.state.derived, membership,
                                        self.state.identity)
        await write_frame(writer, KIND_BYTES, ack)
        await self._broadcast(membership)
        return True

    async def _approve(self, conn, invite_id: bytes, msg: dict, writer) -> bool:
        """Wait for the human decision that lets an invite join."""
        if self.auto_approve:
            return True
        record = {
            "name": msg["name"],
            "arch": msg["arch"],
            "caps": list(msg.get("caps") or []),
            "invite_id": b64(invite_id),
            "wg_pub": msg["wg_pub"],
            "ed_pub": msg["ed_pub"],
            "fingerprint": b64(identity_mod.fingerprint(b64d(msg["ed_pub"]))),
            "time": int(time.time()),
        }
        rid = self.state.add_pending(record)
        conn.pending_id = rid
        conn.record = record
        conn.name = msg["name"]
        conn.arch = msg["arch"]
        conn.caps = msg["caps"]
        conn.fingerprint = record["fingerprint"]
        conn.event = asyncio.Event()
        self.waiting[rid] = conn
        await write_frame(writer, KIND_JSON, canonical_json({
            "t": "pending", "request_id": rid, "name": msg["name"],
            "arch": msg["arch"]}))
        log.info("join request %s (%s, %s) awaiting approval",
                 rid, msg["name"], msg["arch"])
        try:
            await asyncio.wait_for(conn.event.wait(), timeout=APPROVAL_TIMEOUT)
        except asyncio.TimeoutError:
            log.warning("join request %s timed out unapproved", rid)
            self.state.take_pending(rid)
            self.waiting.pop(rid, None)
            return False
        return conn.decision == "allow"
    # --- JSON frames (control messages) ------------------------------

    async def _json_message(self, conn, payload, writer) -> bool:
        """Dispatch a control message: challenge, answer, approve, deny, ..."""
        try:
            obj = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            log.warning("dropped frame: JSON frame is not valid JSON")
            return False
        if not isinstance(obj, dict):
            log.warning("dropped frame: JSON frame is not an object")
            return False
        kind = obj.get("t")
        if kind == "challenge":
            return await self._send_challenge(conn, writer)
        if kind == "answer":
            return await self._check_answer(conn, obj, writer)
        if kind in ("approve", "deny"):
            return await self._decide(conn, obj, kind, writer)
        if kind == "membership":
            return await self._adopt(conn, obj, writer)
        if kind == "endpoints":
            return await self._set_endpoints(conn, obj, writer)
        log.warning("dropped frame: unknown message type %r", kind)
        return False

    async def _send_challenge(self, conn, writer) -> bool:
        """Invite path step 1: hand out a challenge and prove this node.

        The signature is made with this node's Ed25519 key, so the joiner
        can check it against the fingerprint in the QR before it sends
        anything secret. wg_pub is the curve the INVITE_REQ must be sealed
        to.
        """
        ch = joinproto.challenge()
        conn.challenge = ch
        sig = joinproto.answer_challenge(self.state.identity, ch)
        await write_frame(writer, KIND_JSON, canonical_json({
            "t": "challenge",
            "ch": b64(ch),
            "sig": b64(sig),
            "wg_pub": b64(self.state.identity["wg_pub"]),
            "ed_pub": b64(self.state.identity["ed_pub"]),
        }))
        return True

    async def _check_answer(self, conn, obj, writer) -> bool:
        """Invite path step 2: check the joiner's answer to our challenge."""
        from nacl.signing import VerifyKey
        from nacl.exceptions import BadSignatureError
        if conn.challenge is None:
            log.warning("answer refused: no challenge outstanding")
            return False
        try:
            sig = b64d(obj["sig"])
            ed_pub = obj["ed_pub"]
            VerifyKey(b64d(ed_pub)).verify(conn.challenge, sig)
        except (KeyError, CryptoError, BadSignatureError, ValueError) as exc:
            log.warning("answer refused: %s", exc)
            return False
        conn.answer_ed_pub = ed_pub
        await write_frame(writer, KIND_JSON, canonical_json(
            {"t": "answer_ok"}))
        return True

    async def _decide(self, conn, obj, decision: str, writer) -> bool:
        """approve / deny: resolve a pending join request."""
        rid = obj.get("request_id")
        waiting = self.waiting.get(rid)
        if waiting is None:
            self.state.take_pending(rid)
            await write_frame(writer, KIND_JSON, canonical_json({
                "t": "stale", "request_id": rid}))
            log.warning("%s: request %s is not waiting", decision, rid)
            return True
        waiting.decision = "allow" if decision == "approve" else "deny"
        record = self.state.take_pending(rid)
        name = record["name"] if record else "?"
        await write_frame(writer, KIND_JSON, canonical_json({
            "t": "resolved", "request_id": rid,
            "decision": waiting.decision}))
        waiting.event.set()
        log.info("join request %s (%s) %s by operator", rid, name, decision)
        return True

    async def _adopt(self, conn, obj, writer) -> bool:
        """Accept a signed membership change broadcast by another member."""
        try:
            membership = self.state.accept_membership(obj["signed"])
        except (KeyError, ValueError) as exc:
            log.warning("membership change refused: %s", exc)
            await write_frame(writer, KIND_JSON, canonical_json({
                "t": "refused", "reason": str(exc)}))
            return False
        write_wg_conf(self.state)
        await write_frame(writer, KIND_JSON, canonical_json(
            {"t": "membership_ok", "members": len(membership)}))
        return True

    async def _set_endpoints(self, conn, obj, writer) -> bool:
        """Record the endpoints a member advertises for its own join daemon."""
        name = obj.get("node")
        entry = self.state.find_member(name)
        if entry is None:
            log.warning("endpoints refused: %r is not a member", name)
            return False
        entry["endpoints"] = list(obj.get("endpoints") or [])
        self.state.save()
        membership = list(self.state.membership)
        await write_frame(writer, KIND_JSON, canonical_json(
            {"t": "endpoints_ok"}))
        await self._broadcast(membership)
        return True

    async def _broadcast(self, membership: list) -> None:
        """Send the signed membership change to every other member's daemon."""
        signed = joinproto.sign_membership(membership, self.state.identity)
        me = self.state.my_name()
        loop = asyncio.get_running_loop()
        for m in self.state.membership:
            if m["name"] == me:
                continue
            for ep in m.get("endpoints", []):
                task = loop.create_task(
                    self._send_membership(ep, signed))
                self._tasks.add(task)
                task.add_done_callback(self._tasks.discard)
        if self._tasks:
            await asyncio.gather(*list(self._tasks))

    async def _send_membership(self, endpoint: str, signed: dict) -> None:
        try:
            host, port = parse_endpoint(endpoint)
            reader, writer = await asyncio.open_connection(host, port)
        except OSError as exc:
            log.warning("broadcast to %s failed: %s", endpoint, exc)
            return
        try:
            await write_frame(writer, KIND_JSON,
                              canonical_json({"t": "membership",
                                              "signed": signed}))
            await read_frame(reader)
        except (OSError, asyncio.IncompleteReadError, FrameTooLarge):
            log.warning("broadcast to %s failed", endpoint)
        finally:
            try:
                writer.close()
            except Exception:
                pass


# --- client side: used by bin/supermox-join ------------------------------


class _Client:
    """One client connection: frames in, frames out."""

    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self.reader = None
        self.writer = None

    async def __aenter__(self):
        self.reader, self.writer = await connect(self.endpoint)
        return self

    async def __aexit__(self, *exc):
        try:
            self.writer.close()
        except Exception:
            pass
        return False


async def connect(endpoint: str):
    """Open a connection to a join daemon at host or host:port."""
    host, port = parse_endpoint(endpoint)
    return await asyncio.open_connection(host, port)


async def join_phrase(endpoint: str, derived: dict, identity: dict,
                      name: str, arch: str, caps: list) -> dict:
    """Send a JOIN_REQ and return the opened JOIN_ACK.

    *derived* is secret.derive(phrase) plus the entropy bytes; the caller
    keeps the phrase, this function never sees it.
    """
    async with _Client(endpoint) as c:
        blob = joinproto.make_join_req(derived, identity, name, arch, caps)
        await write_frame(c.writer, KIND_BYTES, blob)
        kind, payload = await read_frame(c.reader)
        if kind != KIND_BYTES:
            raise JoinError("daemon refused the phrase join")
        try:
            return joinproto.open_join_ack(derived, payload)
        except ValueError as exc:
            raise JoinError("JOIN_ACK: %s" % exc)


async def join_invite(endpoint: str, invite: dict, identity: dict,
                      name: str, arch: str, caps: list) -> dict:
    """Run the invite handshake and return the opened INVITE_ACK.

    *invite* is the parsed invite (invite_mod.parse_uri). The returned dict
    carries the membership list and the derived keys the new node needs.
    """
    async with _Client(endpoint) as c:
        await write_frame(c.writer, KIND_JSON, canonical_json(
            {"t": "challenge"}))
        kind, payload = await read_frame(c.reader)
        if kind != KIND_JSON:
            raise JoinError("daemon sent no challenge")
        chal = json.loads(payload.decode("utf-8"))
        if chal.get("t") != "challenge":
            raise JoinError("daemon refused the invite: %s"
                            % chal.get("reason", "unknown"))
        # Prove the daemon is the node the invite came from before sending
        # anything secret.
        try:
            joinproto.check_challenge(invite["signer_fingerprint"],
                                      b64d(chal["ed_pub"]),
                                      b64d(chal["ch"]), b64d(chal["sig"]))
        except ValueError as exc:
            raise JoinError("daemon is not the invite issuer: %s" % exc)
        await write_frame(c.writer, KIND_JSON, canonical_json({
            "t": "answer",
            "ed_pub": b64(identity["ed_pub"]),
            "sig": b64(joinproto.answer_challenge(identity,
                                                  b64d(chal["ch"])))}))
        kind, payload = await read_frame(c.reader)
        if kind != KIND_JSON:
            raise JoinError("challenge answer refused")
        if json.loads(payload.decode("utf-8")).get("t") != "answer_ok":
            raise JoinError("challenge answer refused")
        blob = joinproto.make_invite_req(b64d(chal["wg_pub"]), invite,
                                         identity, name, arch, caps)
        await write_frame(c.writer, KIND_BYTES, blob)
        kind, payload = await read_frame(c.reader)
        if kind == KIND_JSON:
            obj = json.loads(payload.decode("utf-8"))
            if obj.get("t") == "pending":
                print("awaiting approval as %s (%s); run "
                      "supermox-join approve %s"
                      % (obj["name"], obj["arch"], obj["request_id"]))
                kind, payload = await read_frame(c.reader)
                if kind == KIND_JSON:
                    obj = json.loads(payload.decode("utf-8"))
                    if obj.get("t") == "deny":
                        raise JoinError("join denied by the seeder")
                    raise JoinError("daemon sent %r instead of a key"
                                    % obj.get("t"))
            else:
                raise JoinError("invite refused: %s"
                                % obj.get("reason", "unknown"))
        if kind != KIND_BYTES:
            raise JoinError("no key frame from the daemon")
        try:
            keys = open_from_member(identity, b64d(chal["wg_pub"]), payload)
        except CryptoError as exc:
            raise JoinError("key frame: %s" % exc)
        derived = {"join_key": b64d(keys["join_key"])}
        kind, payload = await read_frame(c.reader)
        if kind != KIND_BYTES:
            raise JoinError("no INVITE_ACK from the daemon")
        try:
            ack = joinproto.open_invite_ack(derived, payload)
        except ValueError as exc:
            raise JoinError("INVITE_ACK: %s" % exc)
        ack["join_key"] = keys["join_key"]
        ack["cluster_id"] = keys["cluster_id"]
        ack["entropy"] = keys["entropy"]
        return ack


async def send_command(endpoint: str, obj: dict) -> dict:
    """Send one control message (approve, deny, endpoints, ping) and read the reply."""
    async with _Client(endpoint) as c:
        await write_frame(c.writer, KIND_JSON, canonical_json(obj))
        kind, payload = await read_frame(c.reader)
        if kind != KIND_JSON:
            raise JoinError("daemon sent no reply")
        return json.loads(payload.decode("utf-8"))


def apply_join_ack(state: node_state.NodeState, ack: dict) -> list:
    """Adopt the membership list from a JOIN_ACK.

    The JOIN_ACK MAC under join_key already authenticated the sender, so
    the signer is added to the trusted set before the signature is checked.
    """
    signed = {"list": ack["membership"], "signature": ack["signature"],
              "signer": ack["signer"]}
    trusted = state.trusted_ed_pubs() + [b64d(signed["signer"])]
    state.membership = joinproto.verify_membership(signed, trusted)
    state.save()
    return list(state.membership)


def apply_invite_ack(state: node_state.NodeState, ack: dict) -> list:
    """Adopt the membership list and derived keys from an INVITE_ACK."""
    signed = {"list": ack["membership"], "signature": ack["signature"],
              "signer": ack["signer"]}
    trusted = state.trusted_ed_pubs() + [b64d(signed["signer"])]
    state.membership = joinproto.verify_membership(signed, trusted)
    if state.derived is None:
        state.derived = {
            "cluster_id": b64d(ack["cluster_id"]),
            "join_key": b64d(ack["join_key"]),
            "invite_key": b64d(ack["invite_key"]),
            "wg_psk": b64d(ack["wg_psk"]),
            "overlay_prefix": ack["overlay_prefix"],
            "entropy": b64d(ack["entropy"]),
        }
    state.save()
    return list(state.membership)


def write_wg_conf(state: node_state.NodeState, path: str = None) -> str:
    """Write the WireGuard config for this node: one [Peer] per other member.

    Every peer carries the cluster PresharedKey, its overlay address as
    AllowedIPs and, when known, its join endpoint as Endpoint. The interface
    is never brought up here.
    """
    path = path or os.path.join(state.base, "wg0.conf")
    me = state.find_member(state.my_name())
    if me is None or state.identity is None:
        raise JoinError("no membership entry for this node")
    lines = [
        "# SuperMox overlay for cluster %s"
        % b64(state.derived["cluster_id"]),
        "# generated by supermox-join; bring up with wg-quick up wg0",
        "[Interface]",
        "Address = %s/128" % me["overlay_addr"],
        "PrivateKey = %s" % b64(state.identity["wg_priv"]),
        "ListenPort = %d" % WG_LISTEN_PORT,
        "PresharedKey = %s" % b64(state.derived["wg_psk"]),
        "",
    ]
    for m in state.membership:
        if m["name"] == me["name"]:
            continue
        lines.append("# peer %s (%s)" % (m["name"], m["arch"]))
        lines.append("[Peer]")
        for ep in m.get("endpoints", []):
            lines.append("Endpoint = %s" % ep)
        lines.append("PublicKey = %s" % m["wg_pub"])
        lines.append("AllowedIPs = %s/128" % m["overlay_addr"])
        lines.append("PresharedKey = %s" % b64(state.derived["wg_psk"]))
        lines.append("")
    text = "\n".join(lines).rstrip() + "\n"
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    return path


def main(argv=None) -> int:
    """Run the join daemon (used by init.d/supermox-joind and by hand)."""
    ap = argparse.ArgumentParser(prog="supermox-joind")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--auto-approve", action="store_true",
                    help="approve invite joins without asking (tests only)")
    ap.add_argument("--log-level", default="info")
    args = ap.parse_args(argv)
    logging.basicConfig(level=getattr(logging, args.log_level.upper(),
                                      logging.INFO))
    st = node_state.NodeState()
    if not st.load():
        print("supermox-joind: no cluster here; run supermox-join create",
              file=sys.stderr)
        return 1
    daemon = JoinDaemon(st, args.host, args.port, args.auto_approve)
    log.info("join daemon listening on %s:%d", args.host, args.port)
    try:
        asyncio.run(daemon.serve())
    except KeyboardInterrupt:
        return 0
    return 0
