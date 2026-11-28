#!/usr/bin/env python3
"""Unit tests for the Tor onion service layer (src/supermox/onion.py).

Nothing here talks to Tor: the snippet is checked as text, and the address
reader is checked against hostname files written under a temp directory, the
same way Tor writes <HiddenServiceDir>/hostname. The last test covers the
optional "onion" field of a membership entry (state.py).
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))

from supermox import onion
from supermox import state as node_state

PHRASE = "abandon " * 11 + "about"

# A real-shaped v3 address: 56 base32 chars + ".onion".
V3 = "x" * 24 + "abcdefghijklmnopqrstuvwxyz234567" + ".onion"


def _write_hostname(dir_path: str, content: str) -> None:
    with open(os.path.join(dir_path, "hostname"), "w", encoding="ascii") as fh:
        fh.write(content)


class Snippet(unittest.TestCase):
    def test_default_snippet(self):
        self.assertEqual(
            onion.torrc_snippet(),
            "HiddenServiceDir /var/lib/tor/supermox-joind\n"
            "HiddenServicePort 8743 127.0.0.1:8743\n",
        )

    def test_custom_dir_and_port(self):
        self.assertEqual(
            onion.torrc_snippet("/var/lib/tor/join", 9000),
            "HiddenServiceDir /var/lib/tor/join\n"
            "HiddenServicePort 9000 127.0.0.1:9000\n",
        )

    def test_join_port_matches_the_daemon(self):
        # The forward target and the daemon's default port must stay equal.
        self.assertEqual(onion.JOIN_PORT, 8743)
        self.assertIn("HiddenServicePort 8743 127.0.0.1:8743",
                      onion.torrc_snippet())


class AddressFile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.hs = self.dir.name

    def test_valid_address(self):
        _write_hostname(self.hs, V3 + "\n")
        self.assertEqual(onion.read_onion_address(self.hs), V3)

    def test_missing_file_is_none(self):
        self.assertIsNone(onion.read_onion_address(self.hs))

    def test_missing_dir_is_none(self):
        self.assertIsNone(onion.read_onion_address(
            os.path.join(self.hs, "no-such-dir")))

    def test_v2_address_is_rejected(self):
        # Retired RSA v2 address: 16 base32 chars.
        _write_hostname(self.hs, "abcdefghijklmnop.onion\n")
        self.assertIsNone(onion.read_onion_address(self.hs))

    def test_wrong_length_is_rejected(self):
        _write_hostname(self.hs, "x" * 55 + ".onion\n")
        self.assertIsNone(onion.read_onion_address(self.hs))

    def test_non_base32_is_rejected(self):
        # '0', '1', '8', '9' are not in the base32 alphabet.
        _write_hostname(self.hs, "0" * 56 + ".onion\n")
        self.assertIsNone(onion.read_onion_address(self.hs))

    def test_other_suffix_is_rejected(self):
        _write_hostname(self.hs, "x" * 56 + ".onion.example\n")
        self.assertIsNone(onion.read_onion_address(self.hs))

    def test_empty_file_is_rejected(self):
        _write_hostname(self.hs, "\n")
        self.assertIsNone(onion.read_onion_address(self.hs))

    def test_trailing_newline_is_tolerated(self):
        _write_hostname(self.hs, V3 + "\n\n")
        self.assertEqual(onion.read_onion_address(self.hs), V3)


class MembershipOnion(unittest.TestCase):
    """The optional "onion" field of a membership entry, next to wg_endpoint."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.st = node_state.NodeState(self.dir.name)

    def test_create_cluster_stores_onion(self):
        entry = self.st.create_cluster(PHRASE, "node-a", ["10.0.0.1:8743"],
                                       wg_endpoint="10.0.0.1:51820",
                                       onion=V3)
        self.assertEqual(entry["onion"], V3)
        self.assertEqual(entry["wg_endpoint"], "10.0.0.1:51820")

    def test_onion_round_trips_through_disk(self):
        self.st.create_cluster(PHRASE, "node-a", ["10.0.0.1:8743"], onion=V3)
        other = node_state.NodeState(self.dir.name)
        self.assertTrue(other.load())
        self.assertEqual(other.find_member("node-a")["onion"], V3)

    def test_no_onion_stays_backwards_compatible(self):
        entry = self.st.create_cluster(PHRASE, "node-a", ["10.0.0.1:8743"])
        self.assertNotIn("onion", entry)


def main():
    unittest.main()


if __name__ == "__main__":
    main()
