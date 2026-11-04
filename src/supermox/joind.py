"""SuperMox join daemon: the TCP endpoint other nodes join through.

Implements step 4 of docs/node-join-architecture.md:

  * a phrase join (JOIN_REQ / JOIN_ACK) when the joiner already knows the
    cluster words,
  * an invite join (challenge / answer / INVITE_REQ / approval / INVITE_ACK)
    when it only has an invite,
  * the pending approval queue (supermox-join approve / deny),
  * the WireGuard configuration writer (/etc/wireguard/wg0.conf).

Framing
-------
Every message is a 4-byte big-endian length followed by one kind byte and
the payload: kind 1 is JSON, kind 2 is a crypto blob (SecretBox / CurveBox
ciphertext). Frames longer than MAX_FRAME are dropped without being read
further, and nothing about a dropped frame's payload is ever logged.

The daemon never touches the network itself: it writes wg0.conf and asks
``init.d/supermox-wg`` to apply it (``reload`` after a membership change); that
script is what brings the interface up at boot.
"""

import argparse
import asyncio
import base64
import json
import logging
import os
import subprocess
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
READ_TIMEOUT = 30.0               # seconds a connection may idle between frames
MAX_CONNECTIONS = 64              # concurrent connections the daemon will serve
FAILED_WINDOW = 60.0              # seconds a source IP's failures are counted in
MAX_FAILED_ATTEMPTS = 5           # failures from one IP that trigger a lockout
MAX_THROTTLE_IPS = 4096           # bound on the failed-attempt table
# Where this node's WireGuard config lives. wireguard-tools ships an AppArmor
# profile for /usr/bin/wg that lets it read only /etc/wireguard/**, so a
# config written anywhere else can never be brought up: `wg setconf` and
# `wg-quick` both fail with "fopen: Permission denied". SUPERMOX_WG_DIR
# overrides the directory - for the unit tests, and for a host that runs
# several cluster namespaces and so keeps one directory per node under
# /etc/wireguard/ (wg-quick names the interface after the file, so every
# one of them is still called wg0.conf).
WG_DIR_DEFAULT = "/etc/wireguard"
WG_CONF_NAME = "wg0.conf"
WG_DIR_ENV = "SUPERMOX_WG_DIR"
WG_CONF_PATH = "/etc/wireguard/wg0.conf"
# The service script that applies the config: it brings wg0 up at boot and
# re-applies the file when the membership changes. SUPERMOX_WG_INITD overrides
# the path for the unit tests, which stub it with a shell script.
WG_INITD_PATH = "/etc/init.d/supermox-wg"
WG_INITD_ENV = "SUPERMOX_WG_INITD"
WG_INITD_TIMEOUT = 30             # seconds the service script may take

# Set once the first time an older SuperMox's config in the state dir is
# cleared out, so an upgrade explains itself once instead of on every write.
_legacy_conf_logged = False
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


def wg_endpoint_for(endpoint: str) -> str:
    """WireGuard endpoint of a node: its join host, at WG_LISTEN_PORT.

    The join daemon's TCP port (8743) and the WireGuard tunnel port (UDP 51820)
    are different services on the same host; wg0.conf must name the latter.
    """
    host, _ = parse_endpoint(endpoint)
    return "%s:%d" % (host, WG_LISTEN_PORT)

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
        self.peer_ip = None       # source IP, key of the failed-attempt table
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
                 port: int = DEFAULT_PORT, auto_approve: bool = False,
                 wg_conf: str = None):
        self.state = state
        self.host = host
        self.port = port
        self.auto_approve = auto_approve
        # Where this daemon rewrites the overlay when a member changes: None
        # means the default /etc/wireguard/wg0.conf (SUPERMOX_WG_DIR moves the
        # directory, which is how a host running several namespaces keeps them
        # apart). Passed through to write_wg_conf.
        self.wg_conf = wg_conf
        self.seen_nonces = {}
        self.waiting = {}          # request_id -> _Conn
        self.server = None
        self._tasks = set()
        self.active_conns = 0      # connections currently being handled
        self.read_timeout = READ_TIMEOUT
        self.max_connections = MAX_CONNECTIONS
        # Failed-attempt throttle: per source IP, on a monotonic clock the
        # tests can inject. Localhost is not exempt.
        self.fail_window = FAILED_WINDOW
        self.max_failures = MAX_FAILED_ATTEMPTS
        self.max_throttle_ips = MAX_THROTTLE_IPS
        self.fail_times = {}      # ip -> monotonic times of failed attempts
        self.blocked_until = {}   # ip -> time new connections from it resume
        self.clock = time.monotonic

    async def start(self):
        """Start listening. Returns the asyncio server object."""
        self.state.load()
        # Replay protection must survive a daemon restart: the nonce set
        # lives in the state dir (state.seen_nonces), not in this object.
        self.seen_nonces = self.state.seen_nonces
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

    def _peer_ip(self, writer) -> str:
        """Source IP of a connection, as the key of the failed-attempt table."""
        peer = writer.get_extra_info("peername")
        if peer:
            return str(peer[0])
        return "unknown"

    def _throttled(self, ip: str) -> bool:
        """True while new connections from this source IP are locked out."""
        until = self.blocked_until.get(ip)
        return until is not None and self.clock() < until

    def _note_failure(self, conn: _Conn) -> None:
        """Count one failed join/invite attempt against its source IP.

        After MAX_FAILED_ATTEMPTS failures inside fail_window, new connections
        from that IP are refused for fail_window seconds. The table stays
        bounded: entries older than the window are dropped and at most
        max_throttle_ips source IPs are kept.
        """
        now = self.clock()
        cutoff = now - self.fail_window
        times = [t for t in self.fail_times.get(conn.peer_ip, []) if t >= cutoff]
        times.append(now)
        self.fail_times[conn.peer_ip] = times
        if len(times) >= self.max_failures:
            self.blocked_until[conn.peer_ip] = now + self.fail_window
            log.warning("source %s: %d failed attempts in %.0f s, "
                        "refusing new connections for %.0f s",
                        conn.peer_ip, len(times), self.fail_window,
                        self.fail_window)
        # Bound the table: drop stale source IPs, then the oldest ones.
        for ip in list(self.fail_times):
            recent = [t for t in self.fail_times[ip] if t >= cutoff]
            if recent:
                self.fail_times[ip] = recent
            else:
                del self.fail_times[ip]
        for ip in list(self.blocked_until):
            if self.blocked_until[ip] <= now:
                del self.blocked_until[ip]
        if len(self.fail_times) > self.max_throttle_ips:
            oldest = sorted(self.fail_times,
                            key=lambda ip: self.fail_times[ip][0])
            for ip in oldest[:len(self.fail_times) - self.max_throttle_ips]:
                del self.fail_times[ip]

    async def handle(self, reader, writer) -> None:
        conn = _Conn()
        conn.peer_ip = self._peer_ip(writer)
        if self._throttled(conn.peer_ip):
            log.warning("connection refused: source %s is throttled", conn.peer_ip)
            try:
                await write_frame(writer, KIND_JSON, canonical_json(
                    {"t": "error", "error": "too many failed attempts"}))
            except Exception:
                pass
            try:
                writer.close()
            except Exception:
                pass
            return
        if self.active_conns >= self.max_connections:
            log.warning("connection refused: at connection limit (%d)",
                        self.max_connections)
            try:
                await write_frame(writer, KIND_JSON, canonical_json(
                    {"t": "error", "error": "too many connections"}))
            except Exception:
                pass
            try:
                writer.close()
            except Exception:
                pass
            return
        self.active_conns += 1
        try:
            while True:
                try:
                    kind, payload = await asyncio.wait_for(
                        read_frame(reader), timeout=self.read_timeout)
                except asyncio.TimeoutError:
                    log.warning("dropped connection: read timeout")
                    break
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
            self.active_conns -= 1
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
        entry = {
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
        # Optional on the wire (older nodes do not send it): the member's
        # Syncthing device id, used by supermox.sync. Missing means the
        # member's Syncthing is not enrolled yet.
        if msg.get("syncthing_id"):
            entry["syncthing_id"] = msg["syncthing_id"]
        # Also optional on the wire: this member's WireGuard endpoint
        # (host:51820), the address wg0 must send the encrypted packet to.
        # Never the join daemon's port; write_wg_conf falls back to the
        # join host when an older node omits it.
        if msg.get("wg_endpoint"):
            entry["wg_endpoint"] = msg["wg_endpoint"]
        return entry

    async def _join_req(self, conn, blob, writer) -> bool:
        """Phrase path: JOIN_REQ -> add member -> JOIN_ACK."""
        try:
            msg = joinproto.open_join_req(self.state.derived, blob,
                                          seen_nonces=self.seen_nonces)
        except ValueError as exc:
            self._note_failure(conn)
            log.warning("join_req dropped: %s", exc)
            await write_frame(writer, KIND_JSON, canonical_json(
                {"t": "refused", "reason": str(exc)}))
            self.state.save_nonces()
            return False
        # The nonce open_join_req just recorded must reach disk, or a restart
        # of the daemon would forget it and accept the same request again.
        self.state.save_nonces()
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
            if msg["ed_pub"] != conn.answer_ed_pub:
                log.warning("invite_req refused: challenge answer was signed "
                            "by a different key")
                return False
            invite = {
                "invite_id": b64d(msg["invite_id"]),
                "expiry": msg["expiry"],
                "token": b64d(msg["token"]),
                "cluster_id": self.state.derived["cluster_id"],
            }
        except (CryptoError, ValueError, KeyError, TypeError) as exc:
            # A malformed INVITE_REQ (missing field, bad base64, wrong type)
            # must be refused cleanly, not raise out of the connection handler.
            self._note_failure(conn)
            log.warning("invite_req dropped: %s", exc)
            return False
        try:
            invite_mod.verify(self.state.derived, invite,
                              used={b64d(x) for x
                                    in self.state.used_invite_ids()})
        except ValueError as exc:
            self._note_failure(conn)
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
            self._note_failure(conn)
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
        write_wg_conf(self.state, self.wg_conf)
        _apply_wg_conf_logged("reload")
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
        # The WireGuard endpoint travels with the join endpoint: an explicit
        # wg_endpoint in the control message wins, otherwise it follows the
        # first advertised host (same host, port WG_LISTEN_PORT).
        if obj.get("wg_endpoint"):
            entry["wg_endpoint"] = obj["wg_endpoint"]
        elif entry["endpoints"]:
            entry["wg_endpoint"] = wg_endpoint_for(entry["endpoints"][0])
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
                      name: str, arch: str, caps: list,
                      wg_endpoint: str = None) -> dict:
    """Send a JOIN_REQ and return the opened JOIN_ACK.

    *derived* is secret.derive(phrase) plus the entropy bytes; the caller
    keeps the phrase, this function never sees it. *wg_endpoint* is this
    node's own WireGuard endpoint (host:51820), recorded in the membership
    entry so the other members' wg0.conf can point at it.
    """
    async with _Client(endpoint) as c:
        blob = joinproto.make_join_req(derived, identity, name, arch, caps,
                                       wg_endpoint=wg_endpoint)
        await write_frame(c.writer, KIND_BYTES, blob)
        kind, payload = await read_frame(c.reader)
        if kind != KIND_BYTES:
            raise JoinError("daemon refused the phrase join")
        try:
            return joinproto.open_join_ack(derived, payload)
        except ValueError as exc:
            raise JoinError("JOIN_ACK: %s" % exc)


async def join_invite(endpoint: str, invite: dict, identity: dict,
                      name: str, arch: str, caps: list,
                      wg_endpoint: str = None) -> dict:
    """Run the invite handshake and return the opened INVITE_ACK.

    *invite* is the parsed invite (invite_mod.parse_uri). The returned dict
    carries the membership list and the derived keys the new node needs.
    *wg_endpoint* is this node's own WireGuard endpoint (host:51820).
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
                                         identity, name, arch, caps,
                                         wg_endpoint=wg_endpoint)
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


def wg_conf_path() -> str:
    """Path of this node's WireGuard config: /etc/wireguard/wg0.conf."""
    return os.path.join(os.environ.get(WG_DIR_ENV) or WG_DIR_DEFAULT,
                        WG_CONF_NAME)


def wg_initd_path() -> str:
    """Path of the service script that applies this node's wg0.conf."""
    return os.environ.get(WG_INITD_ENV) or WG_INITD_PATH


def apply_wg_conf(action: str = "start") -> tuple:
    """Ask init.d/supermox-wg to apply the config: (ok, one-line message).

    The overlay is a separate service on the same host, so this is the only
    place the daemon reaches the network, and it is a subprocess with a
    timeout, never an exception: a join that succeeded must not be reported
    as failed because the tunnel did not come up. Returns (False, ...) when
    the script is missing, timed out or exited non-zero.
    """
    script = wg_initd_path()
    if not os.path.exists(script):
        return False, "no %s: bring the overlay up by hand" % script
    # Tell the service script which directory this node's config lives in.
    # Without it a node in a nested namespace would make the script read the
    # default /etc/wireguard/wg0.conf - another node's config - and bring up
    # the wrong overlay in this namespace.
    env = dict(os.environ)
    env[WG_DIR_ENV] = os.path.dirname(wg_conf_path())
    try:
        res = subprocess.run([script, action], env=env, timeout=WG_INITD_TIMEOUT,
                             stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT,
                             universal_newlines=True)
    except subprocess.TimeoutExpired:
        return False, "%s %s timed out after %d s" % (script, action,
                                                      WG_INITD_TIMEOUT)
    except OSError as exc:
        return False, "%s %s failed: %s" % (script, action, exc)
    out = [ln for ln in (res.stdout or "").splitlines() if ln.strip()]
    detail = (" " + out[-1]) if out else ""
    if res.returncode != 0:
        return False, "%s %s failed (rc=%d)%s" % (script, action,
                                                  res.returncode, detail)
    return True, "%s %s%s" % (script, action, detail)


def _apply_wg_conf_logged(action: str = "reload") -> None:
    """Apply the config from the daemon, logging the outcome. Never fatal."""
    ok, msg = apply_wg_conf(action)
    if ok:
        log.info(msg)
    else:
        log.warning(msg)


def write_wg_conf(state: node_state.NodeState, path: str = None) -> str:
    """Write the WireGuard config for this node: one [Peer] per other member.

    Every peer carries the cluster PresharedKey, its overlay address as
    AllowedIPs and its WireGuard endpoint (the membership entry's wg_endpoint,
    host:51820) as Endpoint. The join daemon's TCP endpoint (8743) is never
    used here: the kernel sends the encrypted UDP packet to the Endpoint, so
    it must be the port the peer's wg0 listens on. The interface is never
    brought up here.

    The file lands in /etc/wireguard/ (0700) as wg0.conf, mode 0600, because
    that is the only place the wg profile lets /usr/bin/wg read from.
    """
    path = path or wg_conf_path()
    me = state.find_member(state.my_name())
    if me is None or state.identity is None:
        raise JoinError("no membership entry for this node")
    lines = [
        "# SuperMox overlay for cluster %s"
        % b64(state.derived["cluster_id"]),
        "# generated by supermox-join; init.d/supermox-wg brings it up",
        "[Interface]",
        "Address = %s/128" % me["overlay_addr"],
        "PrivateKey = %s" % b64(state.identity["wg_priv"]),
        "ListenPort = %d" % WG_LISTEN_PORT,
        # No PresharedKey here on purpose: wg's parser only accepts it inside
        # a [Peer] block, and an [Interface] one makes the whole config fail
        # to load ("Line unrecognized", "Configuration parsing error").
        "",
    ]
    for m in state.membership:
        if m["name"] == me["name"]:
            continue
        lines.append("# peer %s (%s)" % (m["name"], m["arch"]))
        lines.append("[Peer]")
        wg_ep = m.get("wg_endpoint") or _peer_wg_endpoint(m)
        if wg_ep:
            lines.append("Endpoint = %s" % wg_ep)
        lines.append("PublicKey = %s" % m["wg_pub"])
        lines.append("AllowedIPs = %s/128" % m["overlay_addr"])
        lines.append("PresharedKey = %s" % b64(state.derived["wg_psk"]))
        lines.append("")
    text = "\n".join(lines).rstrip() + "\n"
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    _drop_legacy_conf(state, path)
    return path


def _drop_legacy_conf(state: node_state.NodeState, path: str) -> None:
    """Remove the config an older SuperMox wrote into the node's state dir.

    It used to live at <state dir>/wg0.conf, where the wg profile will not
    let it be read. Two configs on one node means one of them is always
    stale, so the first write to the new location clears the old one; the
    reason is logged once per process, not on every write.
    """
    global _legacy_conf_logged
    old = os.path.join(state.base, WG_CONF_NAME)
    if old == path or not os.path.exists(old):
        return
    first = not _legacy_conf_logged
    _legacy_conf_logged = True
    try:
        os.remove(old)
        if first:
            log.info("removed %s: the WireGuard config is now %s", old, path)
    except OSError as exc:
        if first:
            log.warning("could not remove %s: %s", old, exc)


def _peer_wg_endpoint(m: dict) -> str:
    """WireGuard endpoint of a member whose entry has no wg_endpoint.

    Older nodes only recorded join endpoints: use the first one's host at
    WG_LISTEN_PORT. Empty string when the member advertises nothing, in
    which case the [Peer] block gets no Endpoint and wg would reject it.
    """
    for ep in m.get("endpoints", []):
        return wg_endpoint_for(ep)
    return ""


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
