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
import binascii
import json
import logging
import os
import re
import statistics
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
from supermox import corosync_cluster

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

CORE_RTT_SAMPLES = 5              # echo frames M sends to measure the link
CORE_RTT_MAX_MS = 5.0             # median RTT under this makes a core member
CORE_CMD_TIMEOUT = 120            # seconds a PVE call may take on M's side
CORE_HANDSHAKE_TIMEOUT = 30       # seconds a CORE_ACK may take to arrive
CORE_DONE_TIMEOUT = 180           # seconds M waits for CORE_DONE after the ACK
CORE_DONE_POLL = 0.05             # seconds between checks of that wait

log = logging.getLogger("supermox-joind")


class JoinError(Exception):
    """A join, invite or protocol failure, reported to the user by the CLI."""


class FrameTooLarge(Exception):
    """Raised when a peer sends a frame bigger than MAX_FRAME."""


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


def b64d(text: str) -> bytes:
    return base64.b64decode(text)


def default_run(argv):
    """Run a command for the daemon's PVE calls; tests inject their own."""
    try:
        proc = subprocess.run(argv, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True,
                              timeout=CORE_CMD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return 1, "command timed out after %d s" % CORE_CMD_TIMEOUT
    except OSError as exc:
        return 1, "cannot run %s: %s" % (argv[0], exc)
    # stdout alone on success: callers parse it (pvesh --output-format json),
    # and Perl prints locale warnings on stderr whenever ssh forwarded an LC_*
    # the node has not generated, which used to land in front of the JSON.
    # On failure stderr is appended so the error still reaches the caller.
    if proc.returncode == 0:
        return 0, proc.stdout
    return proc.returncode, proc.stdout + proc.stderr


def authkey_from_pvesh(value) -> bytes:
    """corosync's authkey as raw bytes, from addnode's JSON answer.

    PVE's addnode returns the key file's contents unencoded, and Perl's JSON
    writer turns every byte into the character U+0000..U+00FF, so the bytes
    come back by encoding the string as Latin-1 (measured: a 256-byte key).
    A base64 string is accepted too. Returns b"" when neither fits.
    """
    if not isinstance(value, str) or not value:
        return b""
    b64_chars = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                    "0123456789+/=\n")
    if set(value) <= b64_chars:
        try:
            return base64.b64decode(value, validate=False)
        except (binascii.Error, ValueError):
            return b""
    try:
        return value.encode("latin-1")
    except UnicodeEncodeError:
        return b""


def canonical_json(obj: dict) -> bytes:
    """The bytes both sides put in a JSON frame (sorted keys, no spaces)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def parse_endpoint(text: str) -> tuple:
    """Split "host:port", "[ipv6]:port" or a bare host into (host, port).

    An unbracketed IPv6 address is ambiguous ("::1:4567" is itself an
    address), so it is read as host:port; callers holding a bare IPv6
    address, such as an overlay address, must pass it as "[addr]:port"
    (see endpoint_for_addr).
    """
    if text.startswith("["):
        host, sep, rest = text[1:].partition("]")
        if not sep or not host:
            raise JoinError("bad endpoint: %r" % text)
        if not rest:
            return host, DEFAULT_PORT
        if not rest.startswith(":"):
            raise JoinError("bad endpoint: %r" % text)
        try:
            return host, int(rest[1:])
        except ValueError:
            raise JoinError("bad endpoint: %r" % text)
    host, sep, port = text.rpartition(":")
    if not sep:
        return text, DEFAULT_PORT
    try:
        return host, int(port)
    except ValueError:
        raise JoinError("bad endpoint: %r" % text)


def endpoint_for_addr(addr: str, port: int = None) -> str:
    """A join endpoint for a bare address: IPv6 (the overlay) gets brackets."""
    port = DEFAULT_PORT if port is None else port
    if ":" in addr:
        return "[%s]:%d" % (addr, port)
    return "%s:%d" % (addr, port)


def wg_endpoint_for(endpoint: str) -> str:
    """WireGuard endpoint of a node: its join host, at WG_LISTEN_PORT.

    The join daemon's TCP port (8743) and the WireGuard tunnel port (UDP 51820)
    are different services on the same host; wg0.conf must name the latter.
    """
    host, _ = parse_endpoint(endpoint)
    if ":" in host:
        return "[%s]:%d" % (host, WG_LISTEN_PORT)
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


def seal_core_ack(member_identity: dict, joiner_wg_pub: bytes,
                  conf_text: str, authkey: bytes, cluster_name: str) -> bytes:
    """Seal the corosync config and key for one member's curve (CORE_ACK).

    Same construction as the key frame of an invite join: only the joiner
    can open it, and the MAC the joiner checks under join_key authenticates
    the member that sent it. The authkey is corosync's shared secret, so
    this frame is the only copy of it that ever crosses the wire.
    """
    return seal_for_joiner(member_identity, joiner_wg_pub, {
        "v": joinproto.VERSION,
        "t": joinproto.CORE_ACK_T,
        "corosync_conf": conf_text,
        "corosync_authkey": b64(authkey),
        "cluster_name": cluster_name,
    })


def open_core_ack(identity: dict, member_wg_pub: bytes, blob: bytes) -> dict:
    """Open a CORE_ACK with this node's own curve.

    `member_wg_pub` comes from this node's membership entry for the member
    that answered, so a CORE_ACK from a node this cluster does not know
    fails the curve check like any other forged frame. Raises ValueError
    with a reason the CLI can print.
    """
    try:
        box = CurveBox(PrivateKey(identity["wg_priv"]),
                       PublicKey(member_wg_pub))
        msg = json.loads(box.decrypt(blob).decode("utf-8"))
    except CryptoError as exc:
        raise ValueError("core_ack: %s" % exc)
    if msg.get("v") != joinproto.VERSION or msg.get("t") != joinproto.CORE_ACK_T:
        raise ValueError("not a core_ack")
    conf = msg.get("corosync_conf")
    key = msg.get("corosync_authkey")
    name = msg.get("cluster_name")
    if not isinstance(conf, str) or not conf.strip():
        raise ValueError("core_ack carries no corosync.conf")
    if not isinstance(key, str):
        raise ValueError("core_ack authkey is not base64")
    try:
        authkey = b64d(key)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("core_ack authkey is not base64 (%s)" % exc)
    if not authkey:
        raise ValueError("core_ack carries no authkey")
    if not isinstance(name, str) or not name:
        raise ValueError("core_ack carries no cluster name")
    return {"corosync_conf": conf, "corosync_authkey": authkey,
            "cluster_name": name}


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
                 wg_conf: str = None, run=None):
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
        # PVE calls (pvesh, corosync-quorumtool) go through this runner;
        # offline tests inject one that returns canned JSON.
        self.run = run or default_run
        self.rtt_samples = CORE_RTT_SAMPLES
        self.rtt_max_ms = CORE_RTT_MAX_MS

    async def start(self):
        """Start listening. Returns the asyncio server object."""
        self.state.load()
        # Replay protection must survive a daemon restart: the nonce set
        # lives in the state dir (state.seen_nonces), not in this object.
        self.seen_nonces = self.state.seen_nonces
        # "*" (or "") listens on every IPv4 AND IPv6 address: core requests
        # arrive over the IPv6 WireGuard overlay, so an IPv4-only bind such as
        # 0.0.0.0 could never receive them.
        host = None if self.host in ("", "*") else self.host
        self.server = await asyncio.start_server(
            self.handle, host, self.port, reuse_address=True)
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
                    if not await self._json_message(conn, payload, writer,
                                                    reader):
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
            self._overlay_changed()
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
            self._overlay_changed()
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

    async def _json_message(self, conn, payload, writer, reader) -> bool:
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
        if kind == joinproto.CORE_REQ_T:
            return await self._core_request(conn, obj, writer, reader)
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

    def _overlay_changed(self) -> None:
        """Rewrite and reload this node's wg0 after a member was added here.

        _adopt does this for membership changes broadcast by other members,
        but the member that accepts a join changes the list itself and gets
        no broadcast back: without this its wg0 never learned the new peer,
        so the joiner's handshakes were dropped and nothing crossed the
        overlay (measured on the two-VM LAN pair, 2026-11-06).
        """
        write_wg_conf(self.state, self.wg_conf)
        _apply_wg_conf_logged("reload")

    async def _adopt(self, conn, obj, writer) -> bool:
        """Accept a signed membership change broadcast by another member."""
        try:
            membership = self.state.accept_membership(obj["signed"])
        except (KeyError, ValueError) as exc:
            log.warning("membership change refused: %s", exc)
            await write_frame(writer, KIND_JSON, canonical_json({
                "t": "refused", "reason": str(exc)}))
            return False
        self._overlay_changed()
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

    async def _core_request(self, conn, obj, writer, reader) -> bool:
        """CORE_REQ: a member asks this node to make it a corosync core member.

        Every refusal is a `core_refused` JSON frame carrying the reason: a
        node that cannot go core stays an edge node, which is a normal
        outcome and not an error. The order is forced - verify, then measure
        the link, then ask PVE - because a node that fails the RTT test
        must not already have been added to this cluster's nodelist.
        """
        try:
            entry = joinproto.open_core_req(obj, self.state.membership,
                                            seen_nonces=self.seen_nonces)
        except ValueError as exc:
            self.state.save_nonces()
            log.warning("core_req refused: %s", exc)
            await self._refuse_core(writer, str(exc))
            return False
        self.state.save_nonces()
        ok, reason = await self._core_check(conn, entry, reader, writer)
        if not ok:
            await self._refuse_core(writer, reason)
            log.warning("core_req from %s refused: %s", entry["name"], reason)
            return False
        conf, authkey, reason = await self._core_addnode(entry["name"],
                                                        entry["overlay_addr"])
        if conf is None:
            await self._refuse_core(writer, reason)
            log.warning("core_req from %s refused: %s", entry["name"], reason)
            return False
        ack = seal_core_ack(self.state.identity, b64d(entry["wg_pub"]),
                            conf, authkey,
                            corosync_cluster.cluster_name(self.state))
        await write_frame(writer, KIND_BYTES, ack)
        # The authkey is corosync's shared secret: log its length, never it.
        log.info("core_ack to %s: %d byte config, %d byte authkey",
                 entry["name"], len(conf), len(authkey))
        return True

    async def _refuse_core(self, writer, reason: str) -> None:
        await write_frame(writer, KIND_JSON, canonical_json(
            {"t": "core_refused", "reason": reason}))

    async def _core_check(self, conn, entry: dict, reader, writer):
        """Whether this node may answer a CORE_REQ, and why not.

        A pending join request is none of this business: the queue holds
        requests from nodes that are not members yet and hold no key, and a
        CORE_REQ is only ever answered for a node already in the membership
        list. What gates the answer is membership, the address the request
        arrives from, a live corosync cluster and the measured round trip.
        """
        if self.state.derived is None or not self.state.membership:
            return False, "this node is not a member of a cluster"
        # The connection arrives through the WireGuard overlay, so the peer
        # address this daemon sees is N's overlay address, recorded in the
        # membership entry it produced at join time.
        if entry.get("overlay_addr") != conn.peer_ip:
            return False, ("request arrived from %s, not from %s recorded "
                           "for %s" % (conn.peer_ip,
                                       entry.get("overlay_addr") or "nothing",
                                       entry["name"]))
        rc, out = self.run(["corosync-quorumtool", "-s"])
        if rc != 0:
            return False, ("this node has no corosync cluster yet "
                           "(supermox-join cluster-init has not run): %s"
                           % (out.strip()[:120] or "no output"))
        ms = await self._measure_rtt(reader, writer)
        if ms is None:
            return False, "rtt measurement failed"
        if ms >= self.rtt_max_ms:
            return False, "rtt %.2f ms" % ms
        return True, ""

    async def _measure_rtt(self, reader, writer):
        """Median round trip of self.rtt_samples echo frames, in milliseconds.

        corosync's token budget decides whether a member can hold quorum,
        and a link that cannot echo 5 frames inside a 5 ms median cannot
        hold that either (docs/cluster-core-join.md: corosync already
        reports "Token has not been received in 2250 ms" on a 2 GB amd64
        KVM VM). self.clock is the injectable monotonic clock, so a test
        decides the outcome without sleeping; the joiner's client echoes
        each frame straight back, which is what makes the number real.
        """
        samples = []
        for index in range(self.rtt_samples):
            start = self.clock()
            await write_frame(writer, KIND_JSON, canonical_json(
                {"t": "echo", "n": index}))
            try:
                kind, payload = await asyncio.wait_for(
                    read_frame(reader), timeout=self.read_timeout)
                obj = json.loads(payload.decode("utf-8"))
            except (asyncio.TimeoutError, asyncio.IncompleteReadError,
                    ConnectionError, UnicodeDecodeError,
                    json.JSONDecodeError):
                return None
            if kind != KIND_JSON or obj.get("t") != "echo" \
                    or obj.get("n") != index:
                return None
            samples.append((self.clock() - start) * 1000.0)
        return statistics.median(samples)

    async def _core_addnode(self, name: str, link: str):
        """Ask PVE to add the requester to this cluster's nodelist.

        pvesh's addnode is the call upstream's `pvecm add` makes (docs
        section 2 step 6): the existing cluster decides the config, and
        its reply carries both the new corosync.conf and the authkey. Returns
        (conf, authkey, None) or (None, None, reason).
        """
        if not corosync_cluster.NODE_NAME_RE.match(name):
            return None, None, "member name %r is not a usable node name" % name
        nodes_before = corosync_cluster.count_nodes(
            corosync_cluster.PVE_COROSYNC_CONF)
        argv = ["pvesh", "create", "/cluster/config/nodes/%s" % name,
                "--link0", link, "--output-format", "json"]
        rc, out = await asyncio.to_thread(self.run, argv)
        if rc != 0:
            return None, None, ("pvesh addnode failed (rc=%d): %s"
                                % (rc, out.strip()[:200] or "no output"))
        conf, authkey, reason = self._parse_addnode(out)
        if reason is not None:
            # addnode already put the requester into the nodelist and raised
            # the expected votes; left there, this cluster waits for a vote
            # that never comes and /etc/pve goes read-only (measured on the
            # LAN pair). Take it out again before refusing.
            note = await asyncio.to_thread(self._undo_addnode, name,
                                           nodes_before)
            return None, None, "%s; %s" % (reason, note)
        return conf, authkey, None

    def _undo_addnode(self, name: str, nodes_before: int) -> str:
        """Remove a node addnode just added; restore quorum first if needed."""
        path = "/cluster/config/nodes/%s" % name
        rc, _ = self.run(["pvesh", "delete", path])
        if rc != 0 and nodes_before > 0:
            # Without quorum /etc/pve is read-only and the delete fails:
            # expect only the votes that existed before, then retry.
            self.run(["pvecm", "expected", str(nodes_before)])
            rc, _ = self.run(["pvesh", "delete", path])
        if rc != 0:
            log.error("could not remove %s from the nodelist again; run "
                      "`pvecm expected %d` and `pvesh delete %s` by hand",
                      name, max(nodes_before, 1), path)
            return "removing %s from the nodelist again FAILED" % name
        return "%s was removed from the nodelist again" % name

    @staticmethod
    def _parse_addnode(out: str):
        """(conf, authkey, None) from addnode's JSON, or (None, None, reason)."""
        try:
            data = json.loads(out)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            return None, None, "pvesh output is not JSON (%s)" % exc
        if not isinstance(data, dict):
            return None, None, "pvesh output is not a JSON object"
        conf = data.get("corosync_conf")
        if not isinstance(conf, str) or not conf.strip():
            return None, None, "pvesh returned no corosync_conf"
        authkey = authkey_from_pvesh(data.get("corosync_authkey"))
        if not authkey:
            return None, None, "pvesh returned an unusable authkey"
        return conf, authkey, None

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
    """One client connection: frames in, frames out.

    Every connect, write and read goes through _OverlayError, so a member
    whose address does not answer produces one plain line instead of an
    asyncio traceback (measured on the LAN pair, commit 8fa669b).
    """

    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self.reader = None
        self.writer = None

    async def __aenter__(self):
        with _OverlayError(self.endpoint):
            self.reader, self.writer = await connect(self.endpoint)
        return self

    async def __aexit__(self, *exc):
        try:
            self.writer.close()
        except Exception:
            pass
        return False

    async def write(self, kind: int, payload: bytes) -> None:
        with _OverlayError(self.endpoint):
            await write_frame(self.writer, kind, payload)

    async def read(self, timeout: float = None) -> tuple:
        """One frame; *timeout* seconds before "no reply from ..."."""
        with _OverlayError(self.endpoint):
            if timeout is None:
                return await read_frame(self.reader)
            try:
                return await asyncio.wait_for(read_frame(self.reader),
                                              timeout=timeout)
            except asyncio.TimeoutError:
                raise JoinError("no reply from %s within %d s"
                                % (self.endpoint, int(timeout)))


async def connect(endpoint: str):
    """Open a connection to a join daemon at host or host:port."""
    host, port = parse_endpoint(endpoint)
    return await asyncio.open_connection(host, port)


class _OverlayError:
    """Context manager turning a dead overlay into one plain line.

    Measured on the LAN pair (commit 8fa669b): when the member's address did
    not answer, `supermox-join core` died with a raw asyncio traceback. Every
    connect and read a client does goes through this, so the user gets
    "(fd..:8743) did not answer over the overlay: is wg0 up on both nodes?"
    and the CLI adds the member's name in front of it.
    """

    def __init__(self, endpoint: str):
        self.endpoint = endpoint

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, tb):
        if exc_value is None:
            return False
        if isinstance(exc_value, JoinError):
            return False
        if isinstance(exc_value, (OSError, asyncio.IncompleteReadError,
                                  asyncio.TimeoutError)):
            raise JoinError(
                "(%s) did not answer over the overlay: is wg0 up on both "
                "nodes?" % self.endpoint)
        return False


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


async def core_join(endpoint: str, identity: dict, name: str,
                    member_wg_pub: str) -> dict:
    """Send CORE_REQ to a member's daemon and return its opened CORE_ACK.

    The handshake is a loop because the member measures the link before it
    answers: every ``echo`` frame it sends must be sent straight back for
    the round-trip measurement to mean anything, and the answer arrives as
    one CurveBox frame only this node's curve can open. A ``core_refused``
    frame carries the reason that member gave, and the caller in the CLI
    tries the next member with it.
    """
    async with _Client(endpoint) as c:
        await write_frame(c.writer, KIND_JSON,
                          canonical_json(joinproto.make_core_req(name, identity)))
        while True:
            try:
                kind, payload = await asyncio.wait_for(
                    read_frame(c.reader), timeout=CORE_HANDSHAKE_TIMEOUT)
            except asyncio.TimeoutError:
                raise JoinError("no reply from %s within %d s"
                                % (endpoint, CORE_HANDSHAKE_TIMEOUT))
            if kind == KIND_BYTES:
                try:
                    return open_core_ack(identity, b64d(member_wg_pub),
                                         payload)
                except ValueError as exc:
                    raise JoinError("CORE_ACK: %s" % exc)
            if kind != KIND_JSON:
                raise JoinError("member sent frame kind %d" % kind)
            try:
                obj = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise JoinError("member sent a frame that is not JSON")
            t = obj.get("t")
            if t == "echo":
                await write_frame(c.writer, KIND_JSON, canonical_json(obj))
                continue
            if t == "core_refused":
                raise JoinError(obj.get("reason") or "refused")
            raise JoinError("member sent %r instead of a core_ack" % t)


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
    ap.add_argument("--host", default="*",
                    help='bind address; "*" = every IPv4 and IPv6 address')
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
