"""Tests for supermox.locator: DHT keys and sealed endpoint records.

A key is only computable by someone holding the cluster entropy, a sealed
value is only readable by someone holding the join key, and the signature
inside it is only checkable against the signed membership list.
"""

import datetime
import unittest

from supermox import gossip
from supermox import identity
from supermox import locator
from supermox import secret

BASE = 1700000000                  # 2023-11-14T22:13:20Z
DAY = datetime.date(2023, 11, 14)
ZERO_E = secret.entropy("abandon " * 11 + "about")   # 16 zero bytes
OTHER_E = secret.entropy(secret.generate())


class LocatorTests(unittest.TestCase):
    def setUp(self):
        self.ident = {name: identity.new_identity() for name in "abc"}
        self.members = {name: self.ident[name]["ed_pub"] for name in "abc"}
        self.join_key = secret.derive("abandon " * 11 + "about")["join_key"]

    def record(self, name, endpoints, seq=1, when=BASE):
        return gossip.make_record(self.ident[name], name, endpoints, seq,
                                  now=when)

    # --- keys ----------------------------------------------------

    def test_key_is_deterministic(self):
        """Same entropy, node and day always give the same 20-byte key."""
        key = locator.locator_key(ZERO_E, "node-a", DAY)
        self.assertEqual(len(key), 20)
        self.assertEqual(key, locator.locator_key(ZERO_E, "node-a", DAY))

    def test_key_differs_per_node(self):
        """Two nodes in the same cluster never share a key on the same day."""
        self.assertNotEqual(locator.locator_key(ZERO_E, "node-a", DAY),
                            locator.locator_key(ZERO_E, "node-b", DAY))

    def test_key_differs_per_day(self):
        """The key for a node changes when the UTC day changes."""
        self.assertNotEqual(locator.locator_key(ZERO_E, "node-a", DAY),
                            locator.locator_key(ZERO_E, "node-a",
                                                DAY + datetime.timedelta(days=1)))

    def test_key_differs_between_clusters(self):
        """Two clusters never look up the same key for the same node and day."""
        self.assertNotEqual(locator.locator_key(ZERO_E, "node-a", DAY),
                            locator.locator_key(OTHER_E, "node-a", DAY))

    def test_bad_entropy_rejected(self):
        """A wrong-length entropy is a programming error, not a wrong key."""
        with self.assertRaises(ValueError):
            locator.locator_key(b"\x00" * 8, "node-a", DAY)

    # --- seal / open ----------------------------------------------

    def test_seal_open_round_trip(self):
        """A sealed record opens back to the same record for a member."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        blob = locator.seal(rec, self.join_key, self.ident["a"])
        self.assertLessEqual(len(blob), 1000)
        self.assertNotIn(b"5184", blob)
        self.assertEqual(locator.open_sealed(blob, self.join_key,
                                            self.members), rec)

    def test_wrong_join_key_fails(self):
        """Without the cluster join key the value is unreadable."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        blob = locator.seal(rec, self.join_key, self.ident["a"])
        other_key = secret.derive(secret.generate())["join_key"]
        with self.assertRaises(ValueError):
            locator.open_sealed(blob, other_key, self.members)

    def test_tampered_blob_fails(self):
        """Flipping one byte of the value breaks the secretbox MAC."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        blob = bytearray(locator.seal(rec, self.join_key, self.ident["a"]))
        blob[-1] ^= 0x01
        with self.assertRaises(ValueError):
            locator.open_sealed(bytes(blob), self.join_key, self.members)

    def test_seal_rejects_foreign_signature(self):
        """A node cannot publish a record another member (or a stranger) signed."""
        stranger = identity.new_identity()
        forged = self.record("a", ["10.0.0.1:5184"], 1)
        forged["sig"] = gossip.make_record(stranger, "a", ["10.0.0.1:5184"],
                                          1, now=BASE)["sig"]
        with self.assertRaises(ValueError):
            locator.seal(forged, self.join_key, self.ident["a"])
        with self.assertRaises(ValueError):
            locator.seal(self.record("b", ["10.0.0.2:5184"]),
                         self.join_key, self.ident["a"])

    def test_open_rejects_non_member(self):
        """A validly signed record from a node outside the cluster is refused."""
        stranger = identity.new_identity()
        rec = gossip.make_record(stranger, "stranger", ["1.2.3.4:5184"], 1,
                                 now=BASE)
        blob = locator.seal(rec, self.join_key, stranger)
        with self.assertRaises(ValueError):
            locator.open_sealed(blob, self.join_key, self.members)

    def test_open_rejects_bad_signature(self):
        """A record claiming to be a member's but signed by someone else fails."""
        stranger = identity.new_identity()
        rec = gossip.make_record(stranger, "a", ["10.0.0.1:5184"], 1, now=BASE)
        blob = locator.seal(rec, self.join_key, stranger)
        with self.assertRaises(ValueError):
            locator.open_sealed(blob, self.join_key, self.members)

    def test_oversize_record_raises(self):
        """A record that would not fit a BEP44 mutable value is refused."""
        many = ["10.0.0.%d:5184" % i for i in range(100)]
        rec = self.record("a", many, 1)
        with self.assertRaises(ValueError):
            locator.seal(rec, self.join_key, self.ident["a"])

    # --- querying -----------------------------------------------

    def test_keys_to_query_two_per_node(self):
        """Each node is looked up under today's and yesterday's key."""
        keys = locator.keys_to_query(ZERO_E, ["a", "b", "c"], BASE)
        self.assertEqual(len(keys), 6)
        self.assertEqual(keys[0:2], [locator.locator_key(ZERO_E, "a", DAY),
                                    locator.locator_key(ZERO_E, "a",
                                                       DAY - datetime.timedelta(days=1))])
        self.assertEqual(len(set(keys)), 6)

    def test_yesterday_key_covers_rollover(self):
        """A key published just before midnight UTC is still queried after."""
        midnight = datetime.datetime(2023, 11, 15, 0, 0, 0,
                                     tzinfo=datetime.timezone.utc)
        before = int(midnight.timestamp()) - 1
        after = int(midnight.timestamp()) + 1
        old_key = locator.locator_key(ZERO_E, "a", DAY)
        self.assertIn(old_key, locator.keys_to_query(ZERO_E, ["a"], before))
        self.assertIn(old_key, locator.keys_to_query(ZERO_E, ["a"], after))

    def test_refresh_and_expire_constants(self):
        """Records are refreshed every 30 minutes and expire after 2 hours."""
        self.assertEqual(locator.REFRESH_SECONDS, 1800)
        self.assertEqual(locator.EXPIRE_SECONDS, 7200)
        self.assertLess(locator.REFRESH_SECONDS, locator.EXPIRE_SECONDS)


if __name__ == "__main__":
    unittest.main()
