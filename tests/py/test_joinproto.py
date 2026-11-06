"""Tests for supermox.joinproto: JOIN_REQ/ACK round trips, replay, skew,
invite path with challenge, signed membership, and no-phrase assertions."""

import base64
import hashlib
import json
import os
import unittest

from supermox import secret
from supermox import identity
from supermox import joinproto


def _b64t(data: bytes) -> str:
    """How a membership entry stores a key: base64 text, as state.py does."""
    return base64.b64encode(data).decode("ascii")

ZERO_PHRASE = "abandon " * 11 + "about"


class JoinProtoTests(unittest.TestCase):
    def setUp(self):
        self.derived = secret.derive(ZERO_PHRASE)
        self.ident_a = identity.new_identity()
        self.ident_b = identity.new_identity()

    # --- Phrase join round trip ---

    def test_join_req_round_trip(self):
        """make_join_req -> open_join_req succeeds."""
        blob = joinproto.make_join_req(
            self.derived, self.ident_a, "node-a", "amd64", ["kvm", "lxc"],
            now=1000000,
        )
        seen = {}
        msg = joinproto.open_join_req(self.derived, blob, now=1000000,
                                      seen_nonces=seen)
        self.assertEqual(msg["v"], 1)
        self.assertEqual(msg["name"], "node-a")
        self.assertEqual(msg["arch"], "amd64")
        self.assertEqual(msg["caps"], ["kvm", "lxc"])

    def test_wg_endpoint_round_trip(self):
        """A WireGuard endpoint travels alongside the join daemon endpoint."""
        blob = joinproto.make_join_req(
            self.derived, self.ident_a, "node-a", "amd64", ["kvm"],
            endpoint="10.99.0.1:8743",
            wg_endpoint="10.99.0.1:51820", now=1000000,
        )
        msg = joinproto.open_join_req(self.derived, blob, now=1000000,
                                      seen_nonces={})
        self.assertEqual(msg["endpoints"], ["10.99.0.1:8743"])
        self.assertEqual(msg["wg_endpoint"], "10.99.0.1:51820")
        # Absent when not supplied.
        blob2 = joinproto.make_join_req(self.derived, self.ident_a, "node-a",
                                        "amd64", ["kvm"], now=1000000)
        msg2 = joinproto.open_join_req(self.derived, blob2, now=1000000,
                                       seen_nonces={})
        self.assertNotIn("wg_endpoint", msg2)

    def test_join_ack_round_trip(self):
        """make_join_ack -> open_join_ack succeeds."""
        membership = [
            {"name": "node-a", "wg_pub": "x", "ed_pub": "y",
             "overlay_addr": "::1", "endpoints": [], "arch": "amd64",
             "caps": [], "role": "core"},
        ]
        blob = joinproto.make_join_ack(
            self.derived, membership, "fd00::1", self.ident_a,
        )
        msg = joinproto.open_join_ack(self.derived, blob)
        self.assertEqual(msg["v"], 1)
        self.assertEqual(msg["membership"], membership)
        self.assertEqual(msg["overlay_addr"], "fd00::1")

    # --- Tampered blob fails ---

    def test_tampered_join_req_fails(self):
        """A corrupted JOIN_REQ blob raises ValueError."""
        blob = joinproto.make_join_req(
            self.derived, self.ident_a, "node-a", "amd64", [],
            now=1000000,
        )
        tampered = bytearray(blob)
        tampered[10] ^= 0xFF
        with self.assertRaises(ValueError):
            joinproto.open_join_req(self.derived, bytes(tampered),
                                    now=1000000, seen_nonces={})

    # --- Replay within 600 s fails ---

    def test_replay_within_window_fails(self):
        """Sending the same JOIN_REQ twice within 600 s raises ValueError."""
        blob = joinproto.make_join_req(
            self.derived, self.ident_a, "node-a", "amd64", [],
            now=1000000,
        )
        seen = {}
        joinproto.open_join_req(self.derived, blob, now=1000000,
                                seen_nonces=seen)
        with self.assertRaises(ValueError) as ctx:
            joinproto.open_join_req(self.derived, blob, now=1000100,
                                    seen_nonces=seen)
        self.assertIn("replayed", str(ctx.exception))

    # --- Clock skew over 300 s fails ---

    def test_clock_skew_fails(self):
        """A JOIN_REQ with time 301 s from now raises ValueError."""
        blob = joinproto.make_join_req(
            self.derived, self.ident_a, "node-a", "amd64", [],
            now=1000000,
        )
        with self.assertRaises(ValueError) as ctx:
            joinproto.open_join_req(self.derived, blob, now=1000301,
                                    seen_nonces={})
        self.assertIn("skew", str(ctx.exception))

    # --- Wrong phrase (different derived keys) cannot open ---

    def test_wrong_phrase_cannot_open(self):
        """A JOIN_REQ encrypted with one cluster's key cannot be opened
        with a different cluster's key."""
        other_phrase = secret.generate()
        other_derived = secret.derive(other_phrase)
        blob = joinproto.make_join_req(
            self.derived, self.ident_a, "node-a", "amd64", [],
            now=1000000,
        )
        with self.assertRaises(ValueError):
            joinproto.open_join_req(other_derived, blob, now=1000000,
                                    seen_nonces={})

    # --- Membership signed by an untrusted key fails ---

    def test_untrusted_signer_fails(self):
        """verify_membership raises ValueError when signer is not trusted."""
        membership = [{"name": "n1", "wg_pub": "a", "ed_pub": "b",
                      "overlay_addr": "::1", "endpoints": [], "arch": "amd64",
                      "caps": [], "role": "core"}]
        signed = joinproto.sign_membership(membership, self.ident_a)
        # Trust only ident_b, not ident_a.
        trusted = [self.ident_b["ed_pub"]]
        with self.assertRaises(ValueError) as ctx:
            joinproto.verify_membership(signed, trusted)
        self.assertIn("not in trusted set", str(ctx.exception))

    def test_trusted_signer_succeeds(self):
        """verify_membership returns the list when signer is trusted."""
        membership = [{"name": "n1", "wg_pub": "a", "ed_pub": "b",
                      "overlay_addr": "::1", "endpoints": [], "arch": "amd64",
                      "caps": [], "role": "core"}]
        signed = joinproto.sign_membership(membership, self.ident_a)
        trusted = [self.ident_a["ed_pub"]]
        result = joinproto.verify_membership(signed, trusted)
        self.assertEqual(result, membership)

    # --- Invite round trip with challenge ---

    def test_invite_round_trip(self):
        """challenge -> answer -> check -> make_invite_req -> open_invite_req."""
        ch = joinproto.challenge()
        sig = joinproto.answer_challenge(self.ident_a, ch)
        fp = identity.fingerprint(self.ident_a["ed_pub"])
        self.assertTrue(joinproto.check_challenge(fp, self.ident_a["ed_pub"],
                                                  ch, sig))

        # Build an invite (from the supermox.invite module).
        from supermox import invite as inv_mod
        inv = inv_mod.create(self.derived, ["http://10.0.0.1:8743"],
                             fp, now=1000000)

        # New node sends invite_req to the member.
        blob = joinproto.make_invite_req(
            self.ident_a["wg_pub"], inv, self.ident_b,
            "node-b", "arm64", ["lxc"],
        )
        # Member decrypts.
        msg = joinproto.open_invite_req(self.ident_a, blob)
        self.assertEqual(msg["v"], 1)
        self.assertEqual(msg["name"], "node-b")
        self.assertEqual(msg["arch"], "arm64")

    def test_invite_ack_round_trip(self):
        """make_invite_ack -> open_invite_ack succeeds."""
        membership = [{"name": "n1", "wg_pub": "a", "ed_pub": "b",
                      "overlay_addr": "::1", "endpoints": [], "arch": "amd64",
                      "caps": [], "role": "core"}]
        blob = joinproto.make_invite_ack(self.derived, membership,
                                         self.ident_a)
        msg = joinproto.open_invite_ack(self.derived, blob)
        self.assertEqual(msg["v"], 1)
        self.assertEqual(msg["membership"], membership)
        self.assertIn("join_key", msg)
        self.assertIn("invite_key", msg)
        self.assertIn("wg_psk", msg)
        self.assertIn("overlay_prefix", msg)

    # --- A challenge answered by a different key fails ---

    def test_wrong_key_challenge_fails(self):
        """check_challenge raises ValueError when sig was made by a different key."""
        ch = joinproto.challenge()
        # Sign with ident_b but check against ident_a.
        sig = joinproto.answer_challenge(self.ident_b, ch)
        fp = identity.fingerprint(self.ident_a["ed_pub"])
        with self.assertRaises(ValueError):
            joinproto.check_challenge(fp, self.ident_a["ed_pub"], ch, sig)

    # --- Invite ack contains no field named phrase/mnemonic and no 12-word string ---

    def test_invite_ack_no_phrase(self):
        """The invite ACK must not contain 'phrase', 'mnemonic', or the 12-word phrase."""
        membership = [{"name": "n1", "wg_pub": "a", "ed_pub": "b",
                      "overlay_addr": "::1", "endpoints": [], "arch": "amd64",
                      "caps": [], "role": "core"}]
        blob = joinproto.make_invite_ack(self.derived, membership,
                                         self.ident_a)
        msg = joinproto.open_invite_ack(self.derived, blob)
        # No field named phrase or mnemonic.
        for key in msg:
            self.assertNotIn("phrase", key.lower())
            self.assertNotIn("mnemonic", key.lower())
        # The 12-word phrase must not appear anywhere in the serialized message.
        serialized = json.dumps(msg)
        self.assertNotIn(ZERO_PHRASE, serialized)
        # Also check individual words don't form the phrase.
        words = ZERO_PHRASE.split()
        # The word "abandon" might appear in other contexts, but the full
        # phrase must not.
        self.assertNotIn(" ".join(words), serialized)

    # --- Identity save/load round trip ---

    def test_identity_save_load(self):
        """save -> load preserves all key material."""
        path = os.path.join("build", "test-identity.json")
        os.makedirs("build", exist_ok=True)
        identity.save(self.ident_a, path)
        loaded = identity.load(path)
        self.assertEqual(loaded["wg_priv"], self.ident_a["wg_priv"])
        self.assertEqual(loaded["wg_pub"], self.ident_a["wg_pub"])
        self.assertEqual(loaded["ed_priv"], self.ident_a["ed_priv"])
        self.assertEqual(loaded["ed_pub"], self.ident_a["ed_pub"])
        # File mode is 0600.
        mode = os.stat(path).st_mode & 0o777
        self.assertEqual(mode, 0o600)
        os.remove(path)

    def test_fingerprint_length(self):
        """fingerprint returns exactly 16 bytes."""
        fp = identity.fingerprint(self.ident_a["ed_pub"])
        self.assertEqual(len(fp), 16)

    def test_fingerprint_deterministic(self):
        """fingerprint is deterministic."""
        fp1 = identity.fingerprint(self.ident_a["ed_pub"])
        fp2 = identity.fingerprint(self.ident_a["ed_pub"])
        self.assertEqual(fp1, fp2)


class CoreReqTests(unittest.TestCase):
    """CORE_REQ: a member asking the core to let it become a core member.

    The signed body is only {v, t, name, nonce, time}: a frame cannot promise
    a config, an address or a key, so every test here is about who is allowed
    to ask and what a replay or a foreign key does.
    """

    def setUp(self):
        self.member = identity.new_identity()
        self.outsider = identity.new_identity()
        self.membership = [{
            "name": "node-b",
            "ed_pub": _b64t(self.member["ed_pub"]),
            "wg_pub": _b64t(self.member["wg_pub"]),
            "overlay_addr": "10.0.0.2:8743",
            "role": "edge",
        }]

    def test_signed_round_trip(self):
        """A member's own CORE_REQ opens and returns its membership entry."""
        frame = joinproto.make_core_req("node-b", self.member, now=1000000)
        entry = joinproto.open_core_req(frame, self.membership, now=1000000,
                                        seen_nonces={})
        self.assertEqual(entry["name"], "node-b")
        # The core needs the entry's address to compare it with where the
        # request arrived from, and its wg_pub to seal the answer.
        self.assertEqual(entry["overlay_addr"], "10.0.0.2:8743")

    def test_name_not_in_membership(self):
        """A name the cluster has never heard of is refused outright."""
        frame = joinproto.make_core_req("node-z", self.member, now=1000000)
        with self.assertRaises(ValueError) as ctx:
            joinproto.open_core_req(frame, self.membership, now=1000000,
                                    seen_nonces={})
        self.assertIn("not a member", str(ctx.exception))

    def test_ed_pub_mismatch_names_the_member(self):
        """A rotated keypair gets a reason, not a bare bad-signature error.

        This is the case where the node's identity file changed between its
        join and its core step: the core must say so, because the operator
        has to be told to re-join rather than to retry.
        """
        frame = joinproto.make_core_req("node-b", self.outsider, now=1000000)
        with self.assertRaises(ValueError) as ctx:
            joinproto.open_core_req(frame, self.membership, now=1000000,
                                    seen_nonces={})
        self.assertIn("node-b did not sign with the key this cluster recorded",
                      str(ctx.exception))

    def test_replay(self):
        """The same CORE_REQ twice inside the window is refused."""
        frame = joinproto.make_core_req("node-b", self.member, now=1000000)
        seen = {}
        joinproto.open_core_req(frame, self.membership, now=1000000,
                               seen_nonces=seen)
        with self.assertRaises(ValueError) as ctx:
            joinproto.open_core_req(frame, self.membership, now=1000001,
                                    seen_nonces=seen)
        self.assertIn("replayed", str(ctx.exception))

    def test_clock_skew(self):
        """A CORE_REQ more than 300 s off this node's clock is refused."""
        frame = joinproto.make_core_req("node-b", self.member, now=1000000)
        with self.assertRaises(ValueError) as ctx:
            joinproto.open_core_req(frame, self.membership, now=1000000 + 301,
                                    seen_nonces={})
        self.assertIn("clock window", str(ctx.exception))

    def test_wrong_type(self):
        """A frame that is not a core_req does not open."""
        frame = joinproto.make_core_req("node-b", self.member, now=1000000)
        frame["t"] = "join_req"
        with self.assertRaises(ValueError):
            joinproto.open_core_req(frame, self.membership, now=1000000,
                                    seen_nonces={})

    def test_membership_ack_still_opens(self):
        """Adding CORE_REQ does not disturb the membership JOIN_ACK path.

        The core step happens after a node is already a member, so both
        frame types cross the same socket; a regression here would break
        every join that follows the first core join.
        """
        derived = secret.derive(ZERO_PHRASE)
        blob = joinproto.make_join_ack(derived, self.membership, "fd00::1",
                                       self.member)
        msg = joinproto.open_join_ack(derived, blob)
        self.assertEqual(msg["membership"], self.membership)


if __name__ == "__main__":
    unittest.main()
