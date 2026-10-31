#!/usr/bin/env python3
"""Live tests for HA resources and rules against a running SuperMox node.

Skipped unless SUPERMOX_LIVE_URL points at a reachable node.  Puts a
guest under management, adds a rule over it, reads the live status, and
removes both.  Cleans up before and after.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))

from supermox_manager import api
from supermox_manager.ops import ha

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASS = os.environ.get("SUPERMOX_LIVE_PASS", "")

RID = "vm:9950"
VMID = 9950
RULE = "t75rule"
NODE = "supermox"


class HaLive(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not LIVE_URL:
            raise unittest.SkipTest("SUPERMOX_LIVE_URL not set")
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASS)

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "client", None):
            try:
                cls._cleanup(cls.client)
            except Exception:
                pass
            cls.client.logout()

    @staticmethod
    def _cleanup(client):
        try:
            ha.remove_rule(client, RULE)
        except api.APIError:
            pass
        try:
            ha.remove_resource(client, RID)
        except api.APIError:
            pass

    def test_validation(self):
        self.assertEqual(ha.sid("vm", 100), "vm:100")
        self.assertEqual(ha._rid("vm:100"), "vm:100")
        with self.assertRaises(ValueError):
            ha.sid("disk", 1)
        with self.assertRaises(ValueError):
            ha._rid("vm:10:0")

    def test_resource_rule_lifecycle(self):
        self._cleanup(self.client)
        ha.add_resource(self.client, VMID, kind="vm", state="enabled")
        self.assertIn(RID, [r["sid"] for r in ha.resources(self.client)])

        ha.add_rule(self.client, RULE, "node-affinity",
                    nodes=[NODE], resources=[RID])
        self.assertIn(RULE, [r["rule"] for r in ha.rules(self.client)])

        ha.remove_rule(self.client, RULE)
        self.assertNotIn(RULE, [r["rule"] for r in ha.rules(self.client)])

        ha.update_resource(self.client, RID, state="ignored")
        record = next(r for r in ha.resources(self.client) if r["sid"] == RID)
        self.assertEqual(record["state"], "ignored")

        status = ha.status(self.client)
        self.assertIsInstance(status, list)

        ha.remove_resource(self.client, RID)
        self.assertNotIn(RID, [r["sid"] for r in ha.resources(self.client)])


if __name__ == "__main__":
    unittest.main()
