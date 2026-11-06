"""Tests for supermox.joind: joins over real TCP sockets on 127.0.0.1.

Each test runs a real daemon (asyncio.start_server) on a free loopback port
and drives it with the client functions in joind.py, so the frame protocol,
both join paths, the approval queue, membership broadcast and wg0.conf
generation are all covered. Scratch state lives under build/.
"""

import asyncio
import base64
import ipaddress
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import unittest

from supermox import identity as identity_mod
from supermox import invite as invite_mod
from supermox import joinproto, secret
from supermox import corosync_cluster
from supermox import state as node_state
from supermox import joind

REPO = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
BUILD = os.path.join(REPO, "build")

# Valid BIP39 phrases: the zero-entropy test vector, plus a second valid
# phrase (generated once and pinned) used for the "wrong secret" tests.
PHRASE = "abandon " * 11 + "about"
OTHER = ("fine biology lemon call present broken dwarf sand "
         "giggle flag mixture canoe")


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class JoindBase(unittest.IsolatedAsyncioTestCase):
    """Helpers: scratch node directories and in-process daemons."""

    def setUp(self):
        self._dirs = []
        self._wg_dirs = {}
        self._daemons = []
        # write_wg_conf's default path is /etc/wireguard/wg0.conf, which a
        # test process cannot write, so point the override at scratch.
        self._wg_env = os.environ.get(joind.WG_DIR_ENV)
        self._wg_dir = os.path.join(BUILD, "test-joind-wg-%d" % os.getpid())
        shutil.rmtree(self._wg_dir, ignore_errors=True)
        os.makedirs(self._wg_dir)
        os.environ[joind.WG_DIR_ENV] = self._wg_dir
        self._dirs.append(self._wg_dir)
        # The notice about the legacy config is logged once per process; a
        # test that asserts on it has to start from a fresh latch, otherwise
        # whichever test got there first swallows the message.
        joind._legacy_conf_logged = False

    def wg_dir(self, tag: str) -> str:
        """A scratch overlay directory standing in for /etc/wireguard.

        One per node, created once per tag: a host running several network
        namespaces points each node's daemon at its own directory, and two
        daemons in one test process must not overwrite each other's file.
        Asking for the same tag twice must not wipe what the daemon wrote.
        """
        cached = self._wg_dirs.get(tag)
        if cached:
            return cached
        base = os.path.join(BUILD, "test-joind-wg-%s-%d" % (tag, os.getpid()))
        shutil.rmtree(base, ignore_errors=True)
        os.makedirs(base)
        self._dirs.append(base)
        self._wg_dirs[tag] = base
        return base

    def wg_conf(self, tag: str) -> str:
        """The overlay path a daemon in this test rewrites (wg0.conf inside
        its own wg_dir)."""
        return os.path.join(self.wg_dir(tag), joind.WG_CONF_NAME)

    def node_dir(self, tag: str) -> str:
        base = os.path.join(BUILD, "test-joind-%s-%d" % (tag, os.getpid()))
        shutil.rmtree(base, ignore_errors=True)
        os.makedirs(base)
        self._dirs.append(base)
        return base

    def seeder(self, tag: str, endpoints: list, phrase: str = PHRASE,
               name: str = "node-a", wg_endpoint: str = None) -> node_state.NodeState:
        """A node that owns the cluster and advertises *endpoints*."""
        st = node_state.NodeState(self.node_dir(tag))
        st.create_cluster(phrase, name, endpoints, "amd64", ["kvm"],
                          wg_endpoint)
        return st

    def joiner(self, tag: str):
        """A fresh node: scratch dir plus a saved identity, no cluster yet."""
        base = self.node_dir(tag)
        ident = identity_mod.new_identity()
        identity_mod.save(ident, os.path.join(base, "identity.json"))
        return base, ident

    async def daemon_for(self, st: node_state.NodeState, port: int,
                         auto_approve: bool = False, wg_conf: str = None):
        d = joind.JoinDaemon(st, "127.0.0.1", port, auto_approve,
                             wg_conf=wg_conf)
        await d.start()
        self._daemons.append(d)
        return d

    def pending_id(self, daemon: joind.JoinDaemon) -> str:
        """The request id the daemon is holding in its approval queue."""
        return next(iter(daemon.waiting))

    def derived(self, phrase: str) -> dict:
        d = secret.derive(phrase)
        d["entropy"] = secret.entropy(phrase)
        return d

    async def asyncTearDown(self):
        for d in self._daemons:
            await d.stop()
        for path in self._dirs:
            shutil.rmtree(path, ignore_errors=True)
        if self._wg_env is None:
            os.environ.pop(joind.WG_DIR_ENV, None)
        else:
            os.environ[joind.WG_DIR_ENV] = self._wg_env


class PhraseJoinTests(JoindBase):
    async def test_accepting_member_adds_the_joiner_to_its_own_wg0(self):
        # The member that accepts a join gets no membership broadcast back,
        # so it must rewrite its own wg0.conf; before the fix the joiner's
        # handshakes were dropped and nothing crossed the overlay.
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("wga", [ep])
        conf = self.wg_conf("WGA")
        await self.daemon_for(a, port, wg_conf=conf)
        b_dir, bident = self.joiner("wgb")
        await joind.join_phrase(ep, self.derived(PHRASE), bident,
                                "node-b", "amd64", [])
        with open(conf) as fh:
            text = fh.read()
        self.assertIn("# peer node-b", text)
        self.assertIn("PublicKey = %s" % base64.b64encode(
            bident["wg_pub"]).decode(), text)

    async def test_phrase_join_end_to_end(self):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("a", [ep])
        await self.daemon_for(a, port)
        b_dir, bident = self.joiner("b")

        ack = await joind.join_phrase(ep, self.derived(PHRASE), bident,
                                      "node-b", "arm64", ["lxc"],
                                      wg_endpoint="10.99.0.2:%d"
                                      % joind.WG_LISTEN_PORT)
        self.assertIn("overlay_addr", ack)
        self.assertEqual(sorted(m["name"] for m in ack["membership"]),
                         ["node-a", "node-b"])

        # The joiner adopts the ack the same way bin/supermox-join does.
        b = node_state.NodeState(b_dir)
        b.load()
        b.derived = self.derived(PHRASE)
        joind.apply_join_ack(b, ack)
        path = joind.write_wg_conf(b, os.path.join(b_dir, "wg0.conf"))

        b2 = node_state.NodeState(b_dir)
        b2.load()
        self.assertEqual(b2.derived["join_key"], a.derived["join_key"])
        self.assertEqual(sorted(m["name"] for m in b2.membership),
                         ["node-a", "node-b"])

        with open(path) as fh:
            conf = fh.read()
        self.assertIn("[Interface]", conf)
        self.assertIn("ListenPort = 51820", conf)
        self.assertIn("PrivateKey = ", conf)
        self.assertIn("[Peer]", conf)
        # wg only accepts PresharedKey inside [Peer]: exactly one per peer.
        self.assertEqual(conf.count("PresharedKey = "), 1)
        # The [Peer] Endpoint is the peer's WireGuard endpoint (UDP 51820),
        # never the join daemon's TCP port. node-a never advertised a WireGuard
        # endpoint, so it is derived from the host of its join endpoint.
        self.assertIn("Endpoint = 127.0.0.1:%d" % joind.WG_LISTEN_PORT, conf)
        self.assertNotIn("Endpoint = %s" % ep, conf)
        self.assertIn("PublicKey = ", conf)
        # This node's own address is its overlay address, derived from its
        # own WireGuard public key.
        self.assertIn("Address = %s/128"
                      % secret.node_address(PHRASE, bident["wg_pub"]),
                      conf)
        # The seeder's overlay address is the peer's AllowedIPs, and both
        # addresses sit inside the cluster prefix.
        # node-b's WireGuard endpoint reached node-a over the wire and is
        # kept in the membership entry for the reverse tunnel.
        a2 = node_state.NodeState(a.base)
        a2.load()
        bentry = [m for m in a2.membership if m["name"] == "node-b"][0]
        self.assertEqual(bentry["wg_endpoint"],
                         "10.99.0.2:%d" % joind.WG_LISTEN_PORT)

        net = ipaddress.IPv6Network(self.derived(PHRASE)["overlay_prefix"])
        peer_addr = secret.node_address(PHRASE, a.identity["wg_pub"])
        self.assertIn("AllowedIPs = %s/128" % peer_addr, conf)
        self.assertIn(ipaddress.IPv6Address(peer_addr), net)
        self.assertIn(ipaddress.IPv6Address(
            secret.node_address(PHRASE, bident["wg_pub"])), net)

    async def test_endpoints_command_recorded(self):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("a2", [])
        await self.daemon_for(a, port)
        b_dir, bident = self.joiner("b2")
        await joind.join_phrase(ep, self.derived(PHRASE), bident,
                                "node-b", "amd64", [])
        port_b = free_port()
        reply = await joind.send_command(ep, {
            "t": "endpoints", "node": "node-b",
            "endpoints": ["127.0.0.1:%d" % port_b],
            "wg_endpoint": "10.99.0.2:%d" % joind.WG_LISTEN_PORT})
        self.assertEqual(reply["t"], "endpoints_ok")

        a2 = node_state.NodeState(a.base)
        a2.load()
        entry = [m for m in a2.membership if m["name"] == "node-b"][0]
        self.assertEqual(entry["endpoints"], ["127.0.0.1:%d" % port_b])
        self.assertEqual(entry["arch"], "amd64")
        self.assertEqual(entry["wg_endpoint"],
                         "10.99.0.2:%d" % joind.WG_LISTEN_PORT)

        # A later refresh without wg_endpoint follows the first endpoint's
        # host, so the tunnel keeps pointing at the node, not a stale address.
        reply = await joind.send_command(ep, {
            "t": "endpoints", "node": "node-b",
            "endpoints": ["10.0.0.3:%d" % port_b]})
        self.assertEqual(reply["t"], "endpoints_ok")
        a2 = node_state.NodeState(a.base)
        a2.load()
        entry = [m for m in a2.membership if m["name"] == "node-b"][0]
        self.assertEqual(entry["wg_endpoint"],
                         "10.0.0.3:%d" % joind.WG_LISTEN_PORT)

    async def test_wrong_phrase_rejected(self):
        port = free_port()
        a = self.seeder("a3", [])
        await self.daemon_for(a, port)
        b_dir, bident = self.joiner("b3")
        with self.assertRaises(joind.JoinError):
            await joind.join_phrase("127.0.0.1:%d" % port,
                                    self.derived(OTHER), bident,
                                    "node-x", "amd64", [])
        # Nothing was added to the cluster.
        a2 = node_state.NodeState(a.base)
        a2.load()
        self.assertEqual([m["name"] for m in a2.membership], ["node-a"])

    async def test_replay_rejected(self):
        port = free_port()
        a = self.seeder("a4", [])
        await self.daemon_for(a, port)
        ident = self.joiner("b4")[1]
        blob = joinproto.make_join_req(self.derived(PHRASE), ident,
                                       "node-b", "amd64", [])
        async with joind._Client("127.0.0.1:%d" % port) as c:
            await joind.write_frame(c.writer, joind.KIND_BYTES, blob)
            kind, _ = await joind.read_frame(c.reader)
            self.assertEqual(kind, joind.KIND_BYTES)  # the JOIN_ACK
            await joind.write_frame(c.writer, joind.KIND_BYTES, blob)
            kind, payload = await joind.read_frame(c.reader)
            self.assertEqual(kind, joind.KIND_JSON)
            self.assertIn("replay", json.loads(payload.decode())["reason"])

    async def test_frame_too_large(self):
        port = free_port()
        a = self.seeder("a5", [])
        await self.daemon_for(a, port)
        async with joind._Client("127.0.0.1:%d" % port) as c:
            c.writer.write(struct.pack(">I", joind.MAX_FRAME + 10)
                           + bytes((joind.KIND_JSON,)) + b"x" * 10)
            await c.writer.drain()
            kind, payload = await joind.read_frame(c.reader)
            self.assertEqual(kind, joind.KIND_JSON)
            self.assertEqual(json.loads(payload.decode())["error"],
                             "frame too large")


class FailedAttemptThrottleTests(JoindBase):
    """A source IP that keeps failing authentication is locked out; its
    neighbours on the network are not (f04)."""

    async def test_five_bad_attempts_refuse_the_next_connection(self):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("th1", [])
        d = await self.daemon_for(a, port)
        t = [1000.0]
        d.clock = lambda: t[0]
        ident = self.joiner("th1b")[1]
        with self.assertLogs(joind.log, "WARNING") as logged:
            for i in range(5):
                with self.assertRaises(joind.JoinError):
                    await joind.join_phrase(ep, self.derived(OTHER), ident,
                                            "node-x%d" % i, "amd64", [])
        # The lockout is logged as a complete, formatted line.
        self.assertTrue(any("5 failed attempts in 60 s, refusing new "
                            "connections for 60 s" in m for m in logged.output),
                        logged.output)
        self.assertEqual(len(d.fail_times["127.0.0.1"]), 5)
        # The 6th connection from the same source IP is refused outright:
        # it never reaches the protocol, and gets one error frame.
        async with joind._Client(ep) as c:
            kind, payload = await joind.read_frame(c.reader)
            self.assertEqual(kind, joind.KIND_JSON)
            self.assertEqual(json.loads(payload.decode()),
                             {"t": "error",
                              "error": "too many failed attempts"})

    async def test_lockout_expires_after_the_window(self):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("th2", [])
        d = await self.daemon_for(a, port)
        t = [1000.0]
        d.clock = lambda: t[0]
        ident = self.joiner("th2b")[1]
        for i in range(5):
            with self.assertRaises(joind.JoinError):
                await joind.join_phrase(ep, self.derived(OTHER), ident,
                                        "node-x%d" % i, "amd64", [])
        # Past the window the source IP is served again.
        t[0] += d.fail_window + 1
        ack = await joind.join_phrase(ep, self.derived(PHRASE), ident,
                                      "node-b", "amd64", [])
        self.assertIn("overlay_addr", ack)

    async def test_other_source_ip_is_unaffected(self):
        # The daemon listens on both loopback families so the test can drive
        # it from two different source IPs.
        port = free_port()
        a = self.seeder("th3", [])
        d = joind.JoinDaemon(a, ["127.0.0.1", "::1"], port)
        await d.start()
        self._daemons.append(d)
        ident = self.joiner("th3b")[1]
        for i in range(5):
            with self.assertRaises(joind.JoinError):
                await joind.join_phrase("127.0.0.1:%d" % port,
                                        self.derived(OTHER), ident,
                                        "node-x%d" % i, "amd64", [])
        self.assertTrue(d._throttled("127.0.0.1"))
        self.assertFalse(d._throttled("::1"))
        ack = await joind.join_phrase("::1:%d" % port, self.derived(PHRASE),
                                      ident, "node-b", "amd64", [])
        self.assertIn("overlay_addr", ack)

    async def test_throttle_table_stays_bounded(self):
        d = await self.daemon_for(self.seeder("th4", []), free_port())
        t = [1000.0]
        d.clock = lambda: t[0]
        d.max_throttle_ips = 3
        for i in range(5):
            conn = joind._Conn()
            conn.peer_ip = "10.0.0.%d" % i
            d._note_failure(conn)
        self.assertLessEqual(len(d.fail_times), 3)
        self.assertFalse(d._throttled("10.0.0.9"))
        # Once the window passes, source IPs that stopped misbehaving are
        # dropped from the table entirely.
        t[0] += d.fail_window + 1
        conn = joind._Conn()
        conn.peer_ip = "10.0.0.9"
        d._note_failure(conn)
        self.assertEqual(list(d.fail_times), ["10.0.0.9"])


class NoncePersistenceTests(JoindBase):
    """Replay protection has to survive a restart of the daemon (f04)."""

    async def test_replay_still_blocked_after_daemon_restart(self):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("np", [])
        d = await self.daemon_for(a, port)
        ident = self.joiner("np2")[1]
        blob = joinproto.make_join_req(self.derived(PHRASE), ident,
                                       "node-b", "amd64", [])
        async with joind._Client(ep) as c:
            await joind.write_frame(c.writer, joind.KIND_BYTES, blob)
            kind, _ = await joind.read_frame(c.reader)
            self.assertEqual(kind, joind.KIND_BYTES)   # accepted
        # The nonce reached the state dir, at mode 0600 like the other
        # secret state files.
        path = os.path.join(a.base, "nonces.json")
        self.assertTrue(os.path.exists(path))
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        # A daemon object recreated from the same state dir refuses the
        # identical request as a replay.
        await d.stop()
        d2 = joind.JoinDaemon(node_state.NodeState(a.base), "127.0.0.1", port)
        await d2.start()
        self._daemons.append(d2)
        async with joind._Client(ep) as c:
            await joind.write_frame(c.writer, joind.KIND_BYTES, blob)
            kind, payload = await joind.read_frame(c.reader)
            self.assertEqual(kind, joind.KIND_JSON)
            self.assertIn("replay", json.loads(payload.decode())["reason"])

    async def test_nonces_are_pruned_to_the_replay_window(self):
        a = self.seeder("np2", [])
        now = int(time.time())
        window = joinproto.NONCE_WINDOW
        a.seen_nonces = {b"fresh": now - 10, b"stale": now - window - 10}
        a.save_nonces()
        with open(os.path.join(a.base, "nonces.json")) as f:
            self.assertEqual(json.load(f)["nonces"],
                             {base64.b64encode(b"fresh").decode(): now - 10})
        b = node_state.NodeState(a.base)
        b.load()
        self.assertEqual(b.seen_nonces, {b"fresh": now - 10})


class InviteJoinTests(JoindBase):
    async def seeder_daemon(self, tag: str, auto_approve: bool):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder(tag, [ep])
        d = await self.daemon_for(a, port, auto_approve)
        return a, port, ep, d

    async def test_invite_auto_approve(self):
        a, _, ep, _ = await self.seeder_daemon("seed1", True)
        seed = a.new_invite()
        b_dir, bident = self.joiner("join1")
        ack = await joind.join_invite(ep, seed, bident, "node-b", "arm64",
                                      ["lxc"],
                                      wg_endpoint="10.99.1.2:%d"
                                      % joind.WG_LISTEN_PORT)
        self.assertEqual(sorted(m["name"] for m in ack["membership"]),
                         ["node-a", "node-b"])
        b = node_state.NodeState(b_dir)
        b.load()
        joind.apply_invite_ack(b, ack)
        joind.write_wg_conf(b, os.path.join(b_dir, "wg0.conf"))
        b2 = node_state.NodeState(b_dir)
        b2.load()
        self.assertEqual(b2.derived["join_key"], a.derived["join_key"])
        self.assertEqual(b2.derived["cluster_id"], a.derived["cluster_id"])
        self.assertEqual(b2.derived["wg_psk"], a.derived["wg_psk"])
        with open(os.path.join(b_dir, "wg0.conf")) as fh:
            conf = fh.read()
        self.assertIn("Endpoint = 127.0.0.1:%d" % joind.WG_LISTEN_PORT, conf)
        self.assertNotIn("Endpoint = %s" % ep, conf)

        # node-b's WireGuard endpoint is stored on node-a for the reverse
        # tunnel (node-a -> node-b).
        a2 = node_state.NodeState(a.base)
        a2.load()
        bentry = [m for m in a2.membership if m["name"] == "node-b"][0]
        self.assertEqual(bentry["wg_endpoint"],
                         "10.99.1.2:%d" % joind.WG_LISTEN_PORT)

        # The invite is single-use: a second node holding the same QR fails.
        c_dir, cident = self.joiner("join1b")
        with self.assertRaises(joind.JoinError):
            await joind.join_invite(ep, seed, cident, "node-c", "amd64", [])

    async def test_invite_signed_by_someone_else_rejected(self):
        a, _, ep, _ = await self.seeder_daemon("seed2", True)
        other = identity_mod.new_identity()
        bad = invite_mod.create(a.derived, [ep],
                                identity_mod.fingerprint(other["ed_pub"]),
                                ttl=900)
        c_dir, cident = self.joiner("join2")
        with self.assertRaises(joind.JoinError):
            await joind.join_invite(ep, bad, cident, "node-x", "amd64", [])
        # The cluster is unchanged.
        a2 = node_state.NodeState(a.base)
        a2.load()
        self.assertEqual([m["name"] for m in a2.membership], ["node-a"])

    async def test_pending_then_approve(self):
        a, _, ep, d = await self.seeder_daemon("seed3", False)
        seed = a.new_invite()
        b_dir, bident = self.joiner("join3")
        task = asyncio.ensure_future(joind.join_invite(
            ep, seed, bident, "node-b", "amd64", ["kvm"]))
        record = None
        for _ in range(100):
            await asyncio.sleep(0.05)
            if d.waiting:
                record = list(d.waiting.values())[0]
                break
        self.assertIsNotNone(record)
        self.assertEqual(record.name, "node-b")
        self.assertEqual(record.arch, "amd64")
        self.assertEqual(record.caps, ["kvm"])
        self.assertEqual(record.fingerprint,
                         joind.b64(identity_mod.fingerprint(bident["ed_pub"])))
        rid = self.pending_id(d)

        reply = await joind.send_command(ep, {"t": "approve",
                                              "request_id": rid})
        self.assertEqual(reply["t"], "resolved")
        self.assertEqual(reply["decision"], "allow")
        self.assertTrue(await task)

        # The joiner adopts the ack the same way bin/supermox-join does.
        ack = await task
        b = node_state.NodeState(b_dir)
        b.load()
        joind.apply_invite_ack(b, ack)
        self.assertEqual(b.derived["join_key"], a.derived["join_key"])
        self.assertEqual(sorted(m["name"] for m in b.membership),
                         ["node-a", "node-b"])
        # The queue drained and the pending record was written then removed.
        a.load()
        self.assertEqual(a.pending, {})
        self.assertEqual([m["name"] for m in a.membership],
                         ["node-a", "node-b"])

    async def test_pending_then_deny(self):
        a, _, ep, d = await self.seeder_daemon("seed4", False)
        seed = a.new_invite()
        b_dir, bident = self.joiner("join4")
        task = asyncio.ensure_future(joind.join_invite(
            ep, seed, bident, "node-b", "amd64", []))
        rid = None
        for _ in range(100):
            await asyncio.sleep(0.05)
            if d.waiting:
                rid = self.pending_id(d)
                break
        self.assertIsNotNone(rid)
        reply = await joind.send_command(ep, {"t": "deny",
                                              "request_id": rid})
        self.assertEqual(reply["t"], "resolved")
        self.assertEqual(reply["decision"], "deny")
        with self.assertRaises(joind.JoinError):
            await task
        a.load()
        self.assertEqual(a.pending, {})
        self.assertEqual([m["name"] for m in a.membership], ["node-a"])
        self.assertFalse(os.path.exists(os.path.join(b_dir, "wg0.conf")))


class MembershipBroadcastTests(JoindBase):
    async def test_membership_broadcast_updates_peers(self):
        port_a = free_port()
        ep_a = "127.0.0.1:%d" % port_a
        a = self.seeder("A", [ep_a])
        await self.daemon_for(a, port_a)

        b_dir, bident = self.joiner("B")
        ack = await joind.join_phrase(ep_a, self.derived(PHRASE), bident,
                                      "node-b", "amd64", [])
        b = node_state.NodeState(b_dir)
        b.load()
        b.derived = self.derived(PHRASE)
        joind.apply_join_ack(b, ack)
        port_b = free_port()
        await joind.send_command(ep_a, {"t": "endpoints", "node": "node-b",
                                        "endpoints": ["127.0.0.1:%d" % port_b]})
        await self.daemon_for(b, port_b, wg_conf=self.wg_conf("B"))

        # A third node joins through A's daemon; A broadcasts the new
        # membership to B's daemon, which must adopt it and rewrite wg0.conf.
        cident = identity_mod.new_identity()
        await joind.join_phrase(ep_a, self.derived(PHRASE), cident,
                                "node-c", "amd64", [])
        for _ in range(40):
            await asyncio.sleep(0.05)
            if "node-c" in [m["name"] for m in b.membership]:
                break
        self.assertIn("node-c", [m["name"] for m in b.membership])
        # Read what B's daemon wrote: nothing in this test calls write_wg_conf
        # by hand, so this is the daemon's own rewrite of its own config.
        with open(self.wg_conf("B")) as fh:
            conf = fh.read()
        self.assertIn("AllowedIPs = %s/128"
                      % secret.node_address(PHRASE, cident["wg_pub"]), conf)

    async def test_three_nodes_signed_and_phrase_never_on_disk(self):
        # A seeds; B joins by phrase; C joins by invite (auto-approve).
        port_a = free_port()
        ep_a = "127.0.0.1:%d" % port_a
        a = self.seeder("X", [ep_a])
        await self.daemon_for(a, port_a, True)

        b_dir, bident = self.joiner("Y")
        ack_b = await joind.join_phrase(ep_a, self.derived(PHRASE), bident,
                                        "node-b", "amd64", [])
        b = node_state.NodeState(b_dir)
        b.load()
        b.derived = self.derived(PHRASE)
        joind.apply_join_ack(b, ack_b)
        port_b = free_port()
        await self.daemon_for(b, port_b, wg_conf=self.wg_conf("Y"))
        await joind.send_command(ep_a, {"t": "endpoints", "node": "node-b",
                                        "endpoints": ["127.0.0.1:%d" % port_b]})

        c_dir, cident = self.joiner("Z")
        seed = a.new_invite()
        ack_c = await joind.join_invite(ep_a, seed, cident, "node-c", "amd64", [])
        c = node_state.NodeState(c_dir)
        c.load()
        joind.apply_invite_ack(c, ack_c)
        port_c = free_port()
        await self.daemon_for(c, port_c, wg_conf=self.wg_conf("Z"))
        await joind.send_command(ep_a, {"t": "endpoints", "node": "node-c",
                                        "endpoints": ["127.0.0.1:%d" % port_c]})
        # One more refresh, now that both daemons are listening: an endpoint
        # update is broadcast cluster-wide, so this carries node-c to B's
        # daemon and node-b to C's, and each of them rewrites its own wg0.conf
        # when that membership change arrives.
        await joind.send_command(ep_a, {"t": "endpoints", "node": "node-b",
                                        "endpoints": ["127.0.0.1:%d" % port_b]})

        # All three nodes agree on the membership, and it is signed.
        for st in (a, b, c):
            st.load()
            self.assertEqual(sorted(m["name"] for m in st.membership),
                             ["node-a", "node-b", "node-c"])
            signed = joinproto.sign_membership(st.membership, st.identity)
            adopted = joinproto.verify_membership(signed, st.trusted_ed_pubs())
            self.assertEqual(sorted(m["name"] for m in adopted),
                             ["node-a", "node-b", "node-c"])

        # B's and C's wg0.conf list the other two peers, each with the PSK.
        # Nothing here writes a config by hand: these are the files each
        # node's own daemon produced, so wait on the file rather than on the
        # in-memory membership, which updates a moment before the write.
        for me, wg in ((bident, self.wg_conf("Y")), (cident, self.wg_conf("Z"))):
            conf = ""
            for _ in range(40):
                await asyncio.sleep(0.05)
                try:
                    with open(wg) as fh:
                        conf = fh.read()
                except FileNotFoundError:
                    continue
                if conf.count("PresharedKey = ") == 2:
                    break
            self.assertEqual(conf.count("PresharedKey = "), 2, "%s:\n%s" % (wg, conf))
            for other in (a, b, c):
                if other.identity["wg_pub"] == me["wg_pub"]:
                    continue
                addr = secret.node_address(PHRASE, other.identity["wg_pub"])
                self.assertIn("AllowedIPs = %s/128" % addr, conf)
            # Every [Peer] Endpoint is a WireGuard endpoint (UDP 51820);
            # a join daemon's TCP port must never appear there.
            endpoints = [ln.split(" = ", 1)[1]
                         for ln in conf.splitlines()
                         if ln.startswith("Endpoint = ")]
            self.assertEqual(len(endpoints), 2)
            for e in endpoints:
                self.assertTrue(e.endswith(":%d" % joind.WG_LISTEN_PORT))
                self.assertNotIn(":%d" % port_a, e)
                self.assertNotIn(":%d" % port_b, e)
                self.assertNotIn(":%d" % port_c, e)

        # The 12 words never touch the disk, in any node's scratch dir.
        for d in (a.base, b_dir, c_dir):
            for root, _dirs, files in os.walk(d):
                for fn in files:
                    with open(os.path.join(root, fn), "rb") as fh:
                        data = fh.read()
                    self.assertNotIn(PHRASE.encode(), data)
                    self.assertNotIn(PHRASE.replace(" ", "").encode(), data)


class WgConfLocationTests(JoindBase):
    """Where wg0.conf lives: /etc/wireguard/, because the wg profile says so."""

    async def test_default_path_is_etc_wireguard(self):
        # The constant the docs and the init script quote, and the value the
        # code falls back to when nothing overrides it.
        saved = os.environ.pop(joind.WG_DIR_ENV, None)
        try:
            self.assertEqual(joind.wg_conf_path(), "/etc/wireguard/wg0.conf")
            self.assertEqual(joind.WG_CONF_PATH, "/etc/wireguard/wg0.conf")
        finally:
            if saved is not None:
                os.environ[joind.WG_DIR_ENV] = saved

    async def test_conf_written_0600_in_a_0700_dir(self):
        st = self.seeder("loc1", ["127.0.0.1:1"])
        wg = os.path.join(self._wg_dir, "sub")
        os.makedirs(wg, mode=0o755)
        os.environ[joind.WG_DIR_ENV] = wg
        path = joind.write_wg_conf(st)
        self.assertEqual(path, os.path.join(wg, "wg0.conf"))
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")
        # The directory is created 0700 even when it already existed looser:
        # the file holds this node's WireGuard private key.
        self.assertEqual(oct(os.stat(wg).st_mode & 0o777), "0o700")
        with open(path) as fh:
            self.assertIn("[Interface]", fh.read())

    async def test_old_config_in_the_state_dir_is_removed(self):
        st = self.seeder("loc2", ["127.0.0.1:1"])
        old = os.path.join(st.base, "wg0.conf")
        with open(old, "w") as fh:
            fh.write("# left by an older SuperMox\n")
        with self.assertLogs("supermox-joind", level="INFO") as logs:
            joind.write_wg_conf(st)
            joind.write_wg_conf(st)
        self.assertFalse(os.path.exists(old))
        self.assertEqual(len(logs.output), 1)
        self.assertIn(old, logs.output[0])


class ApplyWgConfTests(JoindBase):
    """init.d/supermox-wg is the only thing that touches the network, and a
    join must not be reported as failed because the overlay did not come up.
    The stubs below stand in for the service script; tests/test-init-wg.sh
    covers the script itself."""

    def stub(self, tag: str, body: str) -> str:
        """An executable stand-in for the service script, in scratch."""
        d = os.path.join(BUILD, "test-joind-initd-%s-%d"
                         % (tag, os.getpid()))
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        path = os.path.join(d, "supermox-wg")
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n%s\n" % body)
        os.chmod(path, 0o755)
        return path

    def with_script(self, path: str, action: str = "start"):
        saved = os.environ.get(joind.WG_INITD_ENV)
        os.environ[joind.WG_INITD_ENV] = path
        try:
            return joind.apply_wg_conf(action)
        finally:
            if saved is None:
                os.environ.pop(joind.WG_INITD_ENV, None)
            else:
                os.environ[joind.WG_INITD_ENV] = saved

    def test_stub_reports_success(self):
        ok, msg = self.with_script(self.stub("ok", 'echo "wg0 up"'))
        self.assertTrue(ok)
        self.assertIn("start", msg)
        self.assertIn("wg0 up", msg)

    def test_missing_script_is_not_fatal(self):
        ok, msg = self.with_script("/nonexistent/supermox-wg")
        self.assertFalse(ok)
        self.assertIn("bring the overlay up by hand", msg)

    def test_failing_script_is_reported_not_raised(self):
        ok, msg = self.with_script(self.stub("fail", "exit 1"))
        self.assertFalse(ok)
        self.assertIn("rc=1", msg)

    def test_hanging_script_hits_the_timeout(self):
        saved = joind.WG_INITD_TIMEOUT
        joind.WG_INITD_TIMEOUT = 1
        try:
            ok, msg = self.with_script(self.stub("hang", "sleep 30"))
        finally:
            joind.WG_INITD_TIMEOUT = saved
        self.assertFalse(ok)
        self.assertIn("timed out", msg)

    def test_the_node_own_config_dir_is_passed_to_the_script(self):
        # wg-quick resolves an interface name to /etc/wireguard/<name>.conf,
        # so a node whose config sits in its own directory below it must say
        # so, or the script brings up another node's overlay in this namespace
        # and the real config can never be applied ("address already assigned").
        nested = os.path.join(self._wg_dir, "smb")
        os.makedirs(nested)
        saved = os.environ.get(joind.WG_DIR_ENV)
        os.environ[joind.WG_DIR_ENV] = nested
        try:
            ok, msg = self.with_script(self.stub(
                "env", 'echo "dir=$SUPERMOX_WG_DIR"'))
        finally:
            if saved is None:
                os.environ.pop(joind.WG_DIR_ENV, None)
            else:
                os.environ[joind.WG_DIR_ENV] = saved
        self.assertTrue(ok)
        self.assertIn("dir=%s" % nested, msg)


class NetworkHardeningTests(JoindBase):
    """A network-exposed daemon must survive idle peers, many peers, and
    malformed frames without exhausting itself or dumping a traceback."""

    async def test_read_timeout_drops_idle_connection(self):
        port = free_port()
        a = self.seeder("rt", [])
        d = await self.daemon_for(a, port)
        d.read_timeout = 0.2
        async with joind._Client("127.0.0.1:%d" % port) as c:
            # A peer that opens a connection and sends nothing must not
            # hold the handler open forever: the daemon times out and closes
            # it, so the client's read hits EOF.
            with self.assertRaises(asyncio.IncompleteReadError):
                await joind.read_frame(c.reader)

    async def test_connection_limit_refuses_extra_peers(self):
        port = free_port()
        a = self.seeder("cl", [])
        d = await self.daemon_for(a, port)
        d.max_connections = 1
        r1, w1 = await joind.connect("127.0.0.1:%d" % port)
        for _ in range(50):
            await asyncio.sleep(0.02)
            if d.active_conns >= 1:
                break
        self.assertEqual(d.active_conns, 1)
        # A second peer over the limit is refused with a clean error frame.
        async with joind._Client("127.0.0.1:%d" % port) as c2:
            kind, payload = await joind.read_frame(c2.reader)
            obj = json.loads(payload.decode())
            self.assertEqual(obj["t"], "error")
            self.assertEqual(obj["error"], "too many connections")
        w1.close()

    async def test_malformed_invite_req_no_unhandled_error(self):
        a, _, ep, d = await self.seeder_daemon_mi("mi", True)
        loop = asyncio.get_running_loop()
        errors = []
        loop.set_exception_handler(lambda l, ctx: errors.append(ctx))
        ident = identity_mod.new_identity()
        async with joind._Client(ep) as c:
            # Prove the daemon, then answer the challenge with our own key
            # so answer_ed_pub is set (this is what any attacker can do: the
            # challenge signature is verified against whatever ed_pub we send).
            await joind.write_frame(c.writer, joind.KIND_JSON,
                                    joind.canonical_json({"t": "challenge"}))
            kind, payload = await joind.read_frame(c.reader)
            chal = json.loads(payload.decode())
            await joind.write_frame(c.writer, joind.KIND_JSON,
                                    joind.canonical_json({
                                        "t": "answer",
                                        "ed_pub": chal["ed_pub"],
                                        "sig": joind.b64(joinproto.answer_challenge(
                                            a.identity, joind.b64d(chal["ch"])))}))
            kind, payload = await joind.read_frame(c.reader)
            self.assertEqual(json.loads(payload.decode())["t"], "answer_ok")
            # An INVITE_REQ sealed to the (public) wg_pub whose decrypted
            # payload is a JSON object missing the required fields.
            eph = joinproto.X25519Private.generate()
            bad = {"v": 1}
            blob = (bytes(eph.public_key)
                    + joinproto.CurveBox(
                        eph, joinproto.PublicKey(joind.b64d(chal["wg_pub"])))
                    .encrypt(joind.canonical_json(bad)))
            await joind.write_frame(c.writer, joind.KIND_BYTES, blob)
            # The daemon must refuse cleanly (close the connection), not
            # raise out of the handler.
            with self.assertRaises(asyncio.IncompleteReadError):
                await joind.read_frame(c.reader)
        self.assertEqual(errors, [])
        # The daemon is still alive and serving.
        reply = await joind.send_command(ep, {"t": "endpoints",
                                              "node": "node-a",
                                              "endpoints": []})
        self.assertEqual(reply["t"], "endpoints_ok")

    async def seeder_daemon_mi(self, tag, auto_approve):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder(tag, [ep])
        await self.daemon_for(a, port, auto_approve)
        return a, port, ep, None


class CoreJoinTests(JoindBase):
    """CORE_REQ -> CORE_ACK: a member asks this node to make it a core member.

    The PVE calls the daemon makes (corosync-quorumtool, pvesh addnode) are
    injected: this test box has no corosync cluster and no pvesh, and what
    is under test is the decision to answer, not PVE's output. The monotonic
    clock is injected for the same reason - the round-trip gate is a timing
    decision, and a test that slept instead would be measuring the scheduler.
    """

    CONF = "global\n\tnum_nodes = 2\n\nnode\n\n\thostname = node-a\n"
    AUTHKEY = bytes(range(64))

    def run_ok(self, argv):
        """Quorum present, and an addnode reply carrying a config and a key."""
        if argv[0] == "corosync-quorumtool":
            return 0, "Quorum OK"
        return 0, json.dumps({"corosync_conf": self.CONF,
                              "corosync_authkey": joind.b64(self.AUTHKEY)})

    def run_no_quorum(self, argv):
        if argv[0] == "corosync-quorumtool":
            return 1, "not running"
        return self.run_ok(argv)

    def run_addnode_fails(self, argv):
        if argv[0] == "corosync-quorumtool":
            return 0, "Quorum OK"
        return 2, "cluster is not running"

    async def pair(self, tag: str, run) -> tuple:
        """Two members and one daemon: the state a core join starts from.

        The second node joins by phrase, so its membership entry - name,
        wg_pub, overlay_addr - is the one the real join path produced, which
        is what the core compares the arriving request against.
        """
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder(tag, [ep])
        d = joind.JoinDaemon(a, "127.0.0.1", port, wg_conf=self.wg_conf(tag),
                             run=run)
        await d.start()
        self._daemons.append(d)
        b_dir, bident = self.joiner("%s-b" % tag)
        await joind.join_phrase(ep, self.derived(PHRASE), bident, "node-b",
                                "amd64", ["kvm"],
                                wg_endpoint="127.0.0.1:%d" % joind.WG_LISTEN_PORT)
        # A CORE_REQ reaches the daemon through the WireGuard overlay, so the
        # peer address it sees is the requester's overlay address. This box
        # has no overlay: the loopback address the test client connects from
        # stands in for it, and the check under test is unchanged.
        for m in a.membership:
            if m["name"] == "node-b":
                m["overlay_addr"] = "127.0.0.1"
        return a, bident, ep, port

    async def raw_core(self, ep: str, frame: dict) -> tuple:
        """Send one CORE_REQ over a fresh socket and read the reply.

        Echoing every ``echo`` frame is what makes the measurement real: a
        client that ignored them would be timing an empty buffer, and the
        RTT gate would pass for the wrong reason.
        """
        host, port = joind.parse_endpoint(ep)
        reader, writer = await asyncio.open_connection(host, port)
        try:
            await joind.write_frame(writer, joind.KIND_JSON,
                                    joind.canonical_json(frame))
            while True:
                kind, payload = await joind.read_frame(reader)
                if kind == joind.KIND_BYTES:
                    return kind, payload
                obj = json.loads(payload.decode("utf-8"))
                if obj.get("t") != "echo":
                    return kind, obj
                await joind.write_frame(writer, joind.KIND_JSON,
                                        joind.canonical_json(obj))
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_core_ack_end_to_end(self):
        """A member's CORE_REQ comes back as a config, a key and a name."""
        a, bident, ep, _ = await self.pair("ack", self.run_ok)
        # The member's WireGuard public key travels as base64 in the membership
        # entry, which is where the CLI reads it from.
        member = [m for m in a.membership if m["name"] == a.my_name()][0]
        ack = await joind.core_join(ep, bident, "node-b", member["wg_pub"])
        self.assertEqual(ack["corosync_conf"], self.CONF)
        self.assertEqual(ack["corosync_authkey"], self.AUTHKEY)
        # The cluster name is what stops a node of one cluster being handed
        # another cluster's key: the CLI compares it with its own.
        self.assertEqual(ack["cluster_name"],
                         corosync_cluster.cluster_name(a))

    async def test_core_ack_while_a_join_waits(self):
        """A pending join request does not stop a member answering a CORE_REQ.

        The queue holds requests from nodes that are not members yet; the
        answer only ever goes to a node already in the membership list, so
        the pending request changes nothing about the key being handed over.
        The old refusal made a cluster unable to grow its core while any
        request sat in the queue.
        """
        a, bident, ep, _ = await self.pair("pending", self.run_ok)
        a.pending["req-c"] = {"name": "node-c"}
        frame = joinproto.make_core_req("node-b", bident)
        kind, payload = await self.raw_core(ep, frame)
        self.assertEqual(kind, joind.KIND_BYTES)
        member = [m for m in a.membership if m["name"] == a.my_name()][0]
        ack = joind.open_core_ack(bident, base64.b64decode(member["wg_pub"]), payload)
        self.assertEqual(ack["corosync_conf"], self.CONF)
        self.assertEqual(ack["corosync_authkey"], self.AUTHKEY)

    async def test_core_refused_from_the_wrong_address(self):
        """The request must arrive from the address this cluster recorded.

        Otherwise a node that has been moved, or an attacker sitting on a
        loopback of the core's host, gets the shared key.
        """
        a, bident, ep, port = await self.pair("addr", self.run_ok)
        for m in a.membership:
            if m["name"] == "node-b":
                m["overlay_addr"] = "10.0.0.9"
        frame = joinproto.make_core_req("node-b", bident)
        kind, obj = await self.raw_core(ep, frame)
        self.assertEqual(obj["t"], "core_refused")
        self.assertIn("not from", obj["reason"])

    async def test_core_refused_from_a_stranger(self):
        """A name that is not in the membership list gets no answer."""
        a, bident, ep, _ = await self.pair("stranger", self.run_ok)
        frame = joinproto.make_core_req("node-z", bident)
        kind, obj = await self.raw_core(ep, frame)
        self.assertEqual(obj["t"], "core_refused")
        self.assertIn("node-z", obj["reason"])

    async def test_core_refused_when_rtt_is_too_slow(self):
        """A link that cannot echo 5 frames inside 5 ms cannot hold quorum."""
        calls = []

        def run(argv):
            calls.append(argv[0])
            return self.run_ok(argv)

        a, bident, ep, _ = await self.pair("rtt", run)
        d = self._daemons[-1]
        tick = [0.0]

        def fake_clock():
            tick[0] += 0.010
            return tick[0]

        d.clock = fake_clock
        frame = joinproto.make_core_req("node-b", bident)
        kind, obj = await self.raw_core(ep, frame)
        self.assertEqual(obj["t"], "core_refused")
        self.assertIn("rtt", obj["reason"])
        # PVE was never asked: a node that fails the link test must not
        # already be in this cluster's nodelist.
        self.assertEqual(calls, ["corosync-quorumtool"])

    async def test_core_refused_without_a_corosync_cluster(self):
        """No quorum here means cluster-init has not run, so no answer."""
        a, bident, ep, _ = await self.pair("quorum", self.run_no_quorum)
        frame = joinproto.make_core_req("node-b", bident)
        kind, obj = await self.raw_core(ep, frame)
        self.assertEqual(obj["t"], "core_refused")
        self.assertIn("corosync cluster", obj["reason"])

    async def test_core_refused_when_addnode_fails(self):
        """A failed pvesh addnode is a reason, not a silent no-reply."""
        a, bident, ep, _ = await self.pair("addnode", self.run_addnode_fails)
        frame = joinproto.make_core_req("node-b", bident)
        kind, obj = await self.raw_core(ep, frame)
        self.assertEqual(obj["t"], "core_refused")
        self.assertIn("addnode", obj["reason"])

    async def test_core_req_replay(self):
        """The same CORE_REQ twice is refused the second time."""
        a, bident, ep, _ = await self.pair("replay", self.run_ok)
        frame = joinproto.make_core_req("node-b", bident)
        kind, _payload = await self.raw_core(ep, frame)
        self.assertEqual(kind, joind.KIND_BYTES)
        kind, obj = await self.raw_core(ep, frame)
        self.assertEqual(obj["t"], "core_refused")
        self.assertIn("replayed", obj["reason"])


class OverlayEndpointTests(JoindBase):
    """Core requests travel over the IPv6 WireGuard overlay."""

    OVERLAY = "fd5f:845b:23ce:6ef1:b235:de3f:6f33:0"

    def test_bare_overlay_address_is_bracketed(self):
        ep = joind.endpoint_for_addr(self.OVERLAY)
        self.assertEqual(ep, "[%s]:%d" % (self.OVERLAY, joind.DEFAULT_PORT))
        self.assertEqual(joind.parse_endpoint(ep),
                         (self.OVERLAY, joind.DEFAULT_PORT))

    def test_bracketed_endpoints_parse(self):
        self.assertEqual(joind.parse_endpoint("[::1]:4567"), ("::1", 4567))
        self.assertEqual(joind.parse_endpoint("[::1]"),
                         ("::1", joind.DEFAULT_PORT))
        for bad in ("[::1", "[]:1", "[::1]x", "[::1]:port"):
            with self.assertRaises(joind.JoinError):
                joind.parse_endpoint(bad)

    def test_ipv4_endpoints_are_unchanged(self):
        self.assertEqual(joind.endpoint_for_addr("10.0.0.9"),
                         "10.0.0.9:%d" % joind.DEFAULT_PORT)
        self.assertEqual(joind.parse_endpoint("10.0.0.9:8743"),
                         ("10.0.0.9", 8743))

    def test_wireguard_endpoint_brackets_ipv6(self):
        self.assertEqual(joind.wg_endpoint_for("[%s]:8743" % self.OVERLAY),
                         "[%s]:%d" % (self.OVERLAY, joind.WG_LISTEN_PORT))
        self.assertEqual(joind.wg_endpoint_for("10.0.0.9:8743"),
                         "10.0.0.9:%d" % joind.WG_LISTEN_PORT)

    async def test_default_bind_accepts_ipv4_and_ipv6(self):
        # 0.0.0.0 never sees a request sent to an IPv6 overlay address.
        port = free_port()
        d = joind.JoinDaemon(self.seeder("ds1", []), "*", port)
        await d.start()
        self._daemons.append(d)
        for host in ("127.0.0.1", "::1"):
            reader, writer = await asyncio.open_connection(host, port)
            writer.close()
            await writer.wait_closed()

    def test_main_defaults_to_every_address(self):
        import inspect
        self.assertIn('default="*"', inspect.getsource(joind.main))



class AddnodeAuthkeyTests(unittest.TestCase):
    """addnode's authkey is raw bytes inside JSON (each byte one char)."""

    KEY = bytes(range(256))

    def test_raw_bytes_as_latin1_characters(self):
        value = json.loads(json.dumps({"k": self.KEY.decode("latin-1")}))["k"]
        self.assertEqual(joind.authkey_from_pvesh(value), self.KEY)

    def test_base64_still_accepted(self):
        self.assertEqual(joind.authkey_from_pvesh(joind.b64(self.KEY)), self.KEY)

    def test_unusable_values(self):
        for bad in (None, "", 7, "\u20ac" * 10):
            self.assertEqual(joind.authkey_from_pvesh(bad), b"")


class UndoAddnodeTests(unittest.TestCase):
    """A failed core join must not leave the requester in the nodelist."""

    def daemon(self, results):
        calls = []

        def run(argv):
            calls.append(argv)
            return results.pop(0) if results else (0, "")
        d = joind.JoinDaemon.__new__(joind.JoinDaemon)
        d.run = run
        return d, calls

    def test_plain_delete(self):
        d, calls = self.daemon([(0, "")])
        note = d._undo_addnode("smx-b", 1)
        self.assertEqual(calls, [["pvesh", "delete", "/cluster/config/nodes/smx-b"]])
        self.assertIn("removed", note)

    def test_restores_expected_votes_when_the_delete_is_refused(self):
        d, calls = self.daemon([(13, "read-only"), (0, ""), (0, "")])
        note = d._undo_addnode("smx-b", 1)
        self.assertEqual(calls[1], ["pvecm", "expected", "1"])
        self.assertEqual(calls[2], ["pvesh", "delete", "/cluster/config/nodes/smx-b"])
        self.assertIn("removed", note)

    def test_reports_a_failed_undo(self):
        d, calls = self.daemon([(13, ""), (0, ""), (13, "")])
        self.assertIn("FAILED", d._undo_addnode("smx-b", 1))

class DeadOverlayTests(JoindBase):
    """A member that does not answer gives one plain line, not a traceback."""

    async def test_closed_port_is_a_join_error(self):
        port = free_port()
        ep = joind.endpoint_for_addr("::1", port)
        with self.assertRaises(joind.JoinError) as ctx:
            await joind.core_join(ep, self.joiner("dead")[1], "node-b",
                                  joind.b64(b"\x01" * 32))
        self.assertIn("did not answer over the overlay", str(ctx.exception))

class RunnerOutputTests(unittest.TestCase):
    """pvesh JSON must not be mixed with Perl's locale warnings on stderr."""

    CMD = ["sh", "-c", "echo '[]'; echo 'perl: warning: Setting locale failed.' >&2; exit %d"]

    def test_success_returns_stdout_only(self):
        rc, out = joind.default_run([self.CMD[0], self.CMD[1], self.CMD[2] % 0])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), [])

    def test_failure_keeps_stderr(self):
        rc, out = joind.default_run([self.CMD[0], self.CMD[1], self.CMD[2] % 3])
        self.assertEqual(rc, 3)
        self.assertIn("Setting locale failed", out)

if __name__ == "__main__":
    unittest.main()
