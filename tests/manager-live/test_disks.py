#!/usr/bin/env python3
"""Live tests for the disks page against a running Manager.

Skipped unless SUPERMOX_LIVE_URL is set (see tests/manager-live.sh). Read-only:
the disk inventory, SMART health and data-directory usage are reported, never
modified.
"""
import os
import unittest

from supermox_manager import api
from supermox_manager.ops import disks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")


class DisksLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LIVE_URL:
            raise unittest.SkipTest("SUPERMOX_LIVE_URL is not set")
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login("root@pam", "supermox")
        cls.node = cls.client.request("GET", "/nodes")[0]["node"]

    def test_disk_list(self):
        rows = disks.disks(self.client, self.node)
        self.assertIsInstance(rows, list)
        self.assertTrue(rows, "expected at least one disk")
        for row in rows:
            self.assertIn("devpath", row)

    def test_smart_of_first_disk(self):
        rows = disks.disks(self.client, self.node)
        self.assertTrue(rows)
        health = disks.smart(self.client, self.node, rows[0]["devpath"])
        self.assertIsInstance(health, dict)

    def test_directory_usage(self):
        rows = disks.directories(self.client, self.node)
        self.assertIsInstance(rows, list)


if __name__ == "__main__":
    if not LIVE_URL:
        raise SystemExit("SUPERMOX_LIVE_URL is not set")
    unittest.main()
