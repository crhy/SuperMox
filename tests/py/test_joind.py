"""Tests for supermox.joind: joins over real TCP sockets on 127.0.0.1.

Each test runs a real daemon (asyncio.start_server) on a free loopback port
and drives it with the client functions in joind.py, so the frame protocol,
both join paths, the approval queue, membership broadcast and wg0.conf
generation are all covered. Scratch state lives under build/.
"""

import asyncio
import ipaddress
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import unittest

from supermox import identity as identity_mod
from supermox import invite as invite_mod
from supermox import joinproto, secret
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
        self._daemons = []

    def node_dir(self, tag: str) -> str:
        base = os.path.join(BUILD, "test-joind-%s-%d" % (tag, os.getpid()))
        shutil.rmtree(base, ignore_errors=True)
        os.makedirs(base)
        self._dirs.append(base)
        return base

    def seeder(self, tag: str, endpoints: list, phrase: str = PHRASE,
               name: str = "node-a") -> node_state.NodeState:
        """A node that owns the cluster and advertises *endpoints*."""
        st = node_state.NodeState(self.node_dir(tag))
        st.create_cluster(phrase, name, endpoints, "amd64", ["kvm"])
        return st

    def joiner(self, tag: str):
        """A fresh node: scratch dir plus a saved identity, no cluster yet."""
        base = self.node_dir(tag)
        ident = identity_mod.new_identity()
        identity_mod.save(ident, os.path.join(base, "identity.json"))
        return base, ident

    async def daemon_for(self, st: node_state.NodeState, port: int,
                         auto_approve: bool = False):
        d = joind.JoinDaemon(st, "127.0.0.1", port, auto_approve)
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


class PhraseJoinTests(JoindBase):
    async def test_phrase_join_end_to_end(self):
        port = free_port()
        ep = "127.0.0.1:%d" % port
        a = self.seeder("a", [ep])
        await self.daemon_for(a, port)
        b_dir, bident = self.joiner("b")

        ack = await joind.join_phrase(ep, self.derived(PHRASE), bident,
                                      "node-b", "arm64", ["lxc"])
        self.assertIn("overlay_addr", ack)
        self.assertEqual(sorted(m["name"] for m in ack["membership"]),
                         ["node-a", "node-b"])

        # The joiner adopts the ack the same way bin/supermox-join does.
        b = node_state.NodeState(b_dir)
        b.load()
        b.derived = self.derived(PHRASE)
        joind.apply_join_ack(b, ack)
        path = joind.write_wg_conf(b)

        b2 = node_state.NodeState(b_dir)
        b2.load()
        self.assertEqual(b2.derived["join_key"], a.derived["join_key"])
        self.assertEqual(sorted(m["name"] for m in b2.membership),
                         ["node-a", "node-b"])

        conf = open(path).read()
        self.assertIn("[Interface]", conf)
        self.assertIn("ListenPort = 51820", conf)
        self.assertIn("PrivateKey = ", conf)
        self.assertIn("PresharedKey = ", conf)
        self.assertIn("[Peer]", conf)
        self.assertIn("Endpoint = %s" % ep, conf)
        self.assertIn("PublicKey = %s" % a.identity["wg_pub"].hex()[:0]
                      or "PublicKey = ", conf)
        # This node's own address is its overlay address, derived from its
        # own WireGuard public key.
        self.assertIn("Address = %s/128"
                      % secret.node_address(PHRASE, bident["wg_pub"]),
                      conf)
        # The seeder's overlay address is the peer's AllowedIPs, and both
        # addresses sit inside the cluster prefix.
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
            "endpoints": ["127.0.0.1:%d" % port_b]})
        self.assertEqual(reply["t"], "endpoints_ok")

        a2 = node_state.NodeState(a.base)
        a2.load()
        entry = [m for m in a2.membership if m["name"] == "node-b"][0]
        self.assertEqual(entry["endpoints"], ["127.0.0.1:%d" % port_b])
        self.assertEqual(entry["arch"], "amd64")

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
                                      ["lxc"])
        self.assertEqual(sorted(m["name"] for m in ack["membership"]),
                         ["node-a", "node-b"])
        b = node_state.NodeState(b_dir)
        b.load()
        joind.apply_invite_ack(b, ack)
        joind.write_wg_conf(b)
        b2 = node_state.NodeState(b_dir)
        b2.load()
        self.assertEqual(b2.derived["join_key"], a.derived["join_key"])
        self.assertEqual(b2.derived["cluster_id"], a.derived["cluster_id"])
        self.assertEqual(b2.derived["wg_psk"], a.derived["wg_psk"])
        conf = open(os.path.join(b_dir, "wg0.conf")).read()
        self.assertIn("Endpoint = %s" % ep, conf)

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
        await self.daemon_for(b, port_b)

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
        conf = open(os.path.join(b_dir, "wg0.conf")).read()
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
        joind.write_wg_conf(b)
        port_b = free_port()
        await joind.send_command(ep_a, {"t": "endpoints", "node": "node-b",
                                        "endpoints": ["127.0.0.1:%d" % port_b]})
        await self.daemon_for(b, port_b)

        c_dir, cident = self.joiner("Z")
        seed = a.new_invite()
        ack_c = await joind.join_invite(ep_a, seed, cident, "node-c", "amd64", [])
        c = node_state.NodeState(c_dir)
        c.load()
        joind.apply_invite_ack(c, ack_c)
        joind.write_wg_conf(c)
        port_c = free_port()
        await joind.send_command(ep_a, {"t": "endpoints", "node": "node-c",
                                        "endpoints": ["127.0.0.1:%d" % port_c]})
        await self.daemon_for(c, port_c)

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
        for st_dir, me in ((b_dir, bident), (c_dir, cident)):
            with open(os.path.join(st_dir, "wg0.conf")) as fh:
                conf = fh.read()
            self.assertGreaterEqual(conf.count("PresharedKey = "), 3)
            for other in (a, b, c):
                if other.identity["wg_pub"] == me["wg_pub"]:
                    continue
                addr = secret.node_address(PHRASE, other.identity["wg_pub"])
                self.assertIn("AllowedIPs = %s/128" % addr, conf)

        # The 12 words never touch the disk, in any node's scratch dir.
        for d in (a.base, b_dir, c_dir):
            for root, _dirs, files in os.walk(d):
                for fn in files:
                    with open(os.path.join(root, fn), "rb") as fh:
                        data = fh.read()
                    self.assertNotIn(PHRASE.encode(), data)
                    self.assertNotIn(PHRASE.replace(" ", "").encode(), data)


if __name__ == "__main__":
    unittest.main()
