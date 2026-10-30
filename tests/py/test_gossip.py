"""Tests for supermox.gossip: signed endpoint records, merge rules, and a
three-node exchange that converges over the overlay with no server."""

import time
import unittest

from supermox import gossip
from supermox import identity

BASE = 1700000000


class GossipTests(unittest.TestCase):
    def setUp(self):
        self.ident = {name: identity.new_identity() for name in "abc"}
        self.members = {name: self.ident[name]["ed_pub"] for name in "abc"}

    def record(self, name, endpoints, seq, when=BASE):
        return gossip.make_record(self.ident[name], name, endpoints, seq,
                                  now=when)

    # --- signing -------------------------------------------------

    def test_record_round_trip(self):
        """A record we made verifies against its own public key."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        self.assertEqual(rec["node"], "a")
        self.assertEqual(rec["endpoints"], ["10.0.0.1:5184"])
        self.assertEqual(rec["seq"], 1)
        self.assertEqual(rec["time"], BASE)
        self.assertTrue(gossip.verify_record(rec, self.members["a"]))

    def test_tampered_endpoints_fail(self):
        """Changing endpoints after signing breaks the signature."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        rec["endpoints"] = ["10.0.0.99:5184"]
        self.assertFalse(gossip.verify_record(rec, self.members["a"]))

    def test_wrong_key_fails(self):
        """A record does not verify against another member's key."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        self.assertFalse(gossip.verify_record(rec, self.members["b"]))

    def test_missing_sig_fails(self):
        """A record with no signature is rejected, not an exception."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        del rec["sig"]
        self.assertFalse(gossip.verify_record(rec, self.members["a"]))

    # --- merge rules ---------------------------------------------

    def test_non_member_rejected(self):
        """A record from a node not in the membership is never merged."""
        stranger = identity.new_identity()
        rec = gossip.make_record(stranger, "stranger", ["1.2.3.4:5184"], 1,
                                 now=BASE)
        known = {}
        self.assertEqual(gossip.merge(known, [rec], self.members, now=BASE),
                         [])
        self.assertEqual(known, {})

    def test_lower_and_equal_seq_ignored(self):
        """Older, and equally numbered, records never replace what we hold."""
        known = {"a": self.record("a", ["10.0.0.1:5184"], 5)}
        incoming = [self.record("a", ["10.0.0.2:5184"], 4),
                    self.record("a", ["10.0.0.3:5184"], 5)]
        self.assertEqual(gossip.merge(known, incoming, self.members,
                                      now=BASE), [])
        self.assertEqual(known["a"]["endpoints"], ["10.0.0.1:5184"])

    def test_higher_seq_replaces(self):
        """A higher seq means the node moved; the new endpoints win."""
        known = {"a": self.record("a", ["10.0.0.1:5184"], 5)}
        rec = self.record("a", ["192.168.4.20:5184"], 6)
        self.assertEqual(gossip.merge(known, [rec], self.members, now=BASE),
                         ["a"])
        self.assertEqual(known["a"], rec)

    def test_future_time_rejected(self):
        """A record stamped more than 10 minutes ahead is refused."""
        known = {}
        rec = self.record("a", ["10.0.0.1:5184"], 1, when=BASE + 3600)
        self.assertEqual(gossip.merge(known, [rec], self.members, now=BASE),
                         [])
        self.assertEqual(known, {})

    def test_bad_clock_still_merges(self):
        """Up to 10 minutes of clock skew is tolerated."""
        known = {}
        rec = self.record("a", ["10.0.0.1:5184"], 1,
                          when=int(time.time()) + 300)
        self.assertEqual(gossip.merge(known, [rec], self.members), ["a"])

    def test_malformed_record_rejected(self):
        """A signed record missing a field never reaches known."""
        for drop in ("seq", "endpoints", "time", "sig"):
            rec = self.record("a", ["10.0.0.1:5184"], 1)
            del rec[drop]
            known = {}
            self.assertEqual(gossip.merge(known, [rec], self.members,
                                          now=BASE), [], drop)
            self.assertEqual(known, {}, drop)

    def test_bad_signature_rejected(self):
        """A forged record signed by someone else never enters known."""
        rec = self.record("a", ["10.0.0.1:5184"], 1)
        rec["sig"] = self.record("b", ["10.0.0.1:5184"], 1)["sig"]
        known = {}
        self.assertEqual(gossip.merge(known, [rec], self.members, now=BASE),
                         [])
        self.assertEqual(known, {})

    # --- digest / wanted ------------------------------------------

    def test_digest_maps_node_to_seq(self):
        known = {"a": self.record("a", ["10.0.0.1:5184"], 2),
                 "b": self.record("b", ["10.0.0.2:5184"], 7)}
        self.assertEqual(gossip.digest(known), {"a": 2, "b": 7})

    def test_wanted_sends_only_differences(self):
        """Only records the peer lacks, or holds at an older seq, are sent."""
        known = {"a": self.record("a", ["10.0.0.1:5184"], 3),
                 "b": self.record("b", ["10.0.0.2:5184"], 3)}
        peer = {"a": 3, "b": 1}
        out = gossip.wanted(known, peer)
        self.assertEqual([r["node"] for r in out], ["b"])

    def test_three_nodes_converge(self):
        """Two rounds of exchange leave all three nodes agreeing."""
        known = {name: {name: self.record(name, ["10.0.0.%d:5184" % i], 1)}
                 for i, name in enumerate("abc")}

        def exchange(x, y):
            x_wants = gossip.wanted(known[x], gossip.digest(known[y]))
            y_wants = gossip.wanted(known[y], gossip.digest(known[x]))
            gossip.merge(known[x], y_wants, self.members, now=BASE)
            gossip.merge(known[y], x_wants, self.members, now=BASE)

        # Round one: a meets b, then b meets c.
        exchange("a", "b")
        exchange("b", "c")
        self.assertEqual(sorted(known["b"]), ["a", "b", "c"])
        self.assertEqual(sorted(known["a"]), ["a", "b"])
        # Round two: a meets c, and both close the loop.
        exchange("a", "c")
        for name in "abc":
            self.assertEqual(sorted(known[name]), ["a", "b", "c"], name)
        # Steady state: nothing left to send in any direction.
        for x in "abc":
            for y in "abc":
                if x != y:
                    self.assertEqual(
                        gossip.wanted(known[x], gossip.digest(known[y])),
                        [], "%s->%s" % (x, y))

    def test_move_propagates(self):
        """One node moving is learned by the others through a relay."""
        known = {name: {name: self.record(name, ["10.0.0.%d:5184" % i], 1)}
                 for i, name in enumerate("abc")}
        for x in "abc":
            for y in "abc":
                if x != y:
                    gossip.merge(known[x],
                                 gossip.wanted(known[y],
                                               gossip.digest(known[x])),
                                 self.members, now=BASE)
        moved = self.record("a", ["203.0.113.7:5184"], 2, when=BASE + 60)
        gossip.merge(known["b"], [moved], self.members, now=BASE + 60)
        # a has not heard yet; c hears it from b.
        gossip.merge(known["c"],
                     gossip.wanted(known["b"], gossip.digest(known["c"])),
                     self.members, now=BASE + 60)
        self.assertEqual(known["c"]["a"]["endpoints"], ["203.0.113.7:5184"])
        self.assertEqual(known["a"]["a"]["endpoints"], ["10.0.0.0:5184"])


if __name__ == "__main__":
    unittest.main()
