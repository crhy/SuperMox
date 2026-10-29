"""Tests for supermox.secret (12-word cluster secret and HKDF derivation)."""

import ipaddress
import unittest

from supermox import secret

ZERO_PHRASE = "abandon " * 11 + "about"


class SecretTests(unittest.TestCase):
    def test_zero_vector_entropy(self):
        # BIP39 vector: 11x "abandon" + "about" decodes to 16 zero bytes.
        self.assertEqual(secret.entropy(ZERO_PHRASE), b"\x00" * 16)

    def test_checksum_failure(self):
        # Change one word -> valid words but bad checksum.
        bad = ZERO_PHRASE.replace("about", "abandon")
        with self.assertRaises(ValueError):
            secret.validate(bad)

    def test_wrong_word_count(self):
        with self.assertRaises(ValueError):
            secret.validate("abandon " * 11)  # 11 words

    def test_non_list_word(self):
        bad = ZERO_PHRASE.replace("about", "notarealword")
        with self.assertRaises(ValueError):
            secret.validate(bad)

    def test_generate_unique_and_valid(self):
        a = secret.generate()
        b = secret.generate()
        self.assertNotEqual(a, b)
        secret.validate(a)
        secret.validate(b)

    def test_derive_deterministic_and_distinct(self):
        d1 = secret.derive(ZERO_PHRASE)
        d2 = secret.derive(ZERO_PHRASE)
        self.assertEqual(d1, d2)
        # The five values must differ from each other.
        vals = [d1["cluster_id"], d1["join_key"], d1["invite_key"], d1["wg_psk"]]
        self.assertEqual(len(set(vals)), 4)
        self.assertNotEqual(d1["overlay_prefix"], "fd::/48")

    def test_pinned_zero_vector_keys(self):
        # Pinned so a future change to labels/salt breaks the test.
        d = secret.derive(ZERO_PHRASE)
        self.assertEqual(
            d["cluster_id"].hex(),
            "ca59b9993e64f4d85223e09a99a9501f",
        )
        self.assertEqual(
            d["join_key"].hex(),
            "5bf076b14ff2229f7fc25c1e95f606488f4571ea2ef6c0c7f1f265fd031df936",
        )

    def test_overlay_prefix_starts_with_fd(self):
        d = secret.derive(secret.generate())
        self.assertTrue(d["overlay_prefix"].startswith("fd"))

    def test_node_address_inside_prefix(self):
        d = secret.derive(ZERO_PHRASE)
        addr = secret.node_address(ZERO_PHRASE, bytes(range(32)))
        ip = ipaddress.IPv6Address(addr)
        net = ipaddress.IPv6Network(d["overlay_prefix"])
        self.assertIn(ip, net)
        # Deterministic for the same key.
        self.assertEqual(addr, secret.node_address(ZERO_PHRASE, bytes(range(32))))


if __name__ == "__main__":
    unittest.main()
