#!/usr/bin/env python3
"""Live tests for the node page against a running Manager.

Skipped unless SUPERMOX_LIVE_URL is set (see tests/manager-live.sh). Read-mostly:
the node summary, services, system log, updates and DNS/time settings are read
from the running node. A few round trips prove the write paths work and are
restored afterwards: a service restart (pvestatd, a benign daemon), a timezone
change back to Etc/UTC, and a DNS search-domain change back to empty.
"""
import os
import time
import unittest

from supermox_manager import api
from supermox_manager.ops import node

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")


class NodeLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LIVE_URL:
            raise unittest.SkipTest("SUPERMOX_LIVE_URL is not set")
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login("root@pam", "supermox")
        cls.node = cls.client.request("GET", "/nodes")[0]["node"]

    def test_summary(self):
        result = node.summary(self.client, self.node)
        self.assertIsInstance(result, dict)
        self.assertIn("pveversion", result)
        self.assertIn("kernel", result)

    def test_services(self):
        rows = node.services(self.client, self.node)
        self.assertIsInstance(rows, list)
        self.assertTrue(rows, "expected at least one service")
        for row in rows:
            self.assertIn("name", row)

    def test_syslog(self):
        rows = node.syslog(self.client, self.node, limit=20)
        self.assertIsInstance(rows, list)

    def test_updates(self):
        rows = node.updates(self.client, self.node)
        self.assertIsInstance(rows, list)

    def test_dns_read(self):
        result = node.dns(self.client, self.node)
        self.assertIsInstance(result, dict)

    def test_time_read(self):
        result = node.time_info(self.client, self.node)
        self.assertIsInstance(result, dict)
        self.assertIn("timezone", result)

    def test_hosts_read(self):
        result = node.hosts(self.client, self.node)
        self.assertIsInstance(result, dict)
        self.assertIn("data", result)

    def test_service_restart_roundtrip(self):
        upid = node.service_action(self.client, self.node, "pvestatd", "restart")
        self.assertIsInstance(upid, str)
        self.assertTrue(upid.startswith("UPID:"))
        # pvestatd must be running again once the task settles.
        running = False
        for _ in range(20):
            states = [s["state"] for s in node.services(self.client, self.node)
                      if s["name"] == "pvestatd"]
            if states and states[0] == "running":
                running = True
                break
            time.sleep(1)
        self.assertTrue(running, "pvestatd not running after restart")

    def test_timezone_roundtrip(self):
        original = node.time_info(self.client, self.node)["timezone"]
        try:
            node.set_timezone(self.client, self.node, "Europe/Berlin")
            self.assertEqual(node.time_info(self.client, self.node)["timezone"],
                             "Europe/Berlin")
        finally:
            node.set_timezone(self.client, self.node, original)
        self.assertEqual(node.time_info(self.client, self.node)["timezone"], original)

    def test_dns_roundtrip(self):
        original = node.dns(self.client, self.node)
        try:
            node.set_dns(self.client, self.node, search="example.com")
            self.assertEqual(node.dns(self.client, self.node).get("search"),
                             "example.com")
        finally:
            node.set_dns(self.client, self.node, search="")
        self.assertNotIn("search", node.dns(self.client, self.node))

    def test_refresh_updates(self):
        upid = node.refresh_updates(self.client, self.node)
        self.assertIsInstance(upid, str)
        self.assertTrue(upid.startswith("UPID:"))


if __name__ == "__main__":
    if not LIVE_URL:
        raise SystemExit("SUPERMOX_LIVE_URL is not set")
    unittest.main()
