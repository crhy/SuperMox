"""Tests for supermox.invite (QR invite creation, encoding, parsing, verification)."""

import hashlib
import os
import unittest

from supermox import secret
from supermox import invite

ZERO_PHRASE = "abandon " * 11 + "about"


class InviteTests(unittest.TestCase):
    def setUp(self):
        self.derived = secret.derive(ZERO_PHRASE)
        self.endpoints = ["http://192.168.1.1:8743", "https://example.com/join"]
        self.fingerprint = b"\xab" * 32

    def test_round_trip(self):
        """create -> to_uri -> parse_uri -> verify succeeds."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000)
        uri = invite.to_uri(inv)
        parsed = invite.parse_uri(uri)
        self.assertEqual(parsed["invite_id"], inv["invite_id"])
        self.assertEqual(parsed["expiry"], inv["expiry"])
        self.assertEqual(parsed["token"], inv["token"])
        self.assertEqual(parsed["cluster_id"], inv["cluster_id"])
        self.assertEqual(parsed["signer_fingerprint"], inv["fingerprint"]
                         if "fingerprint" in parsed else inv["signer_fingerprint"])
        self.assertEqual(parsed["endpoints"], self.endpoints)
        # verify needs the parsed dict (no _keys)
        self.assertTrue(invite.verify(self.derived, parsed, now=1000100))

    def test_tampered_token_fails(self):
        """A modified token causes verify to raise ValueError."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000)
        uri = invite.to_uri(inv)
        parsed = invite.parse_uri(uri)
        parsed["token"] = b"\x00" * 16
        with self.assertRaises(ValueError) as ctx:
            invite.verify(self.derived, parsed, now=1000100)
        self.assertIn("token", str(ctx.exception))

    def test_expired_fails(self):
        """An invite past its expiry raises ValueError."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000, ttl=10)
        parsed = invite.parse_uri(invite.to_uri(inv))
        with self.assertRaises(ValueError) as ctx:
            invite.verify(self.derived, parsed, now=1000011)
        self.assertIn("expired", str(ctx.exception))

    def test_reused_invite_id_fails(self):
        """A second verify with the same invite_id in 'used' raises ValueError."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000)
        parsed = invite.parse_uri(invite.to_uri(inv))
        used = {parsed["invite_id"]}
        with self.assertRaises(ValueError) as ctx:
            invite.verify(self.derived, parsed, now=1000100, used=used)
        self.assertIn("already used", str(ctx.exception))

    def test_wrong_cluster_fails(self):
        """An invite from a different cluster raises ValueError."""
        other_phrase = "abandon " * 11 + "about"
        # Use a different phrase to get different cluster_id.
        other_phrase = secret.generate()
        other_derived = secret.derive(other_phrase)
        inv = invite.create(other_derived, self.endpoints, self.fingerprint,
                            now=1000000)
        parsed = invite.parse_uri(invite.to_uri(inv))
        with self.assertRaises(ValueError) as ctx:
            invite.verify(self.derived, parsed, now=1000100)
        self.assertIn("wrong cluster", str(ctx.exception))

    def test_uri_contains_no_key_material(self):
        """The URI must not contain hex or base32 of any 32-byte key."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000)
        uri = invite.to_uri(inv)
        for key_name in ("join_key", "invite_key", "wg_psk"):
            key = self.derived[key_name]
            self.assertNotIn(key.hex(), uri)
            self.assertNotIn(invite._b32(key), uri)

    def test_render_text_nonempty(self):
        """render_text returns non-empty lines."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000)
        uri = invite.to_uri(inv)
        text = invite.render_text(uri)
        lines = text.splitlines()
        self.assertGreater(len(lines), 0)
        # At least some lines have content.
        self.assertTrue(any(len(l) > 0 for l in lines))

    def test_render_png_writes_png(self):
        """render_png writes a file with the PNG signature."""
        inv = invite.create(self.derived, self.endpoints, self.fingerprint,
                            now=1000000)
        uri = invite.to_uri(inv)
        path = os.path.join("build", "test-invite.png")
        os.makedirs("build", exist_ok=True)
        invite.render_png(uri, path)
        with open(path, "rb") as f:
            sig = f.read(8)
        self.assertEqual(sig, b"\x89PNG\r\n\x1a\n")
        os.remove(path)

    def test_parse_uri_unknown_scheme(self):
        """parse_uri raises ValueError for unknown scheme."""
        with self.assertRaises(ValueError):
            invite.parse_uri("http://join?v=1&c=a&i=b&x=1&t=c&f=d")

    def test_parse_uri_missing_field(self):
        """parse_uri raises ValueError when a required field is missing."""
        with self.assertRaises(ValueError):
            invite.parse_uri("supermox://join?v=1&c=aaaa&i=bbbb&x=100")

    def test_parse_uri_unknown_version(self):
        """parse_uri raises ValueError for unknown version."""
        with self.assertRaises(ValueError):
            invite.parse_uri("supermox://join?v=99&c=aaaa&i=bbbb&x=100&t=cccc&f=dddd")


if __name__ == "__main__":
    unittest.main()
