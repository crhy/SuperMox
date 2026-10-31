#!/usr/bin/env python3
"""Live tests for resource pools against a running SuperMox node.

Skipped unless SUPERMOX_LIVE_URL points at a reachable node.  Creates a
pool, adds a guest, refuses to delete it while it has members, removes
the member, and deletes the pool.  Cleans up before and after.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))

from supermox_manager import api
from supermox_manager.ops import pools

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASS = os.environ.get("SUPERMOX_LIVE_PASS", "")

POOL = "t75pool"
VMID = 9950


class PoolsLive(unittest.TestCase):

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
        for p in pools.pools(client):
            if p.get("poolid") != POOL:
                continue
            record = pools.pool(client, POOL)
            vms = [m[1] for m in pools.pool_members(record) if m[0] == "guest"]
            stor = [m[1] for m in pools.pool_members(record) if m[0] == "storage"]
            if vms:
                pools.remove_members(client, POOL, vms=vms)
            if stor:
                pools.remove_members(client, POOL, storage=stor)
            try:
                pools.delete_pool(client, POOL)
            except api.APIError:
                pass

    def test_poolid_validation(self):
        with self.assertRaises(ValueError):
            pools.create_pool(self.client, "bad pool")
        with self.assertRaises(ValueError):
            pools.create_pool(self.client, "a/b")

    def test_create_add_members_delete(self):
        self._cleanup(self.client)
        pools.create_pool(self.client, POOL, comment="t75")
        self.assertIn(POOL, [p["poolid"] for p in pools.pools(self.client)])

        pools.add_members(self.client, POOL, vms=[VMID])
        record = pools.pool(self.client, POOL)
        members = pools.pool_members(record)
        self.assertIn(("guest", str(VMID)), members)

        with self.assertRaises(api.APIError):
            pools.delete_pool(self.client, POOL)

        pools.remove_members(self.client, POOL, vms=[VMID])
        pools.delete_pool(self.client, POOL)
        self.assertNotIn(POOL, [p["poolid"] for p in pools.pools(self.client)])


if __name__ == "__main__":
    unittest.main()
