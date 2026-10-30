"""Live tests against a running SuperMox VM.

Skips unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, along
with the SSL fingerprint, only when a VM is up). These hit the real server, so
paths and parameter names are proven, not guessed.
"""

import os
import unittest

from supermox_manager import api
from supermox_manager.ops import guests, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

VMID = 9900


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class Basics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASSWORD)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.client.logout()
        except Exception:  # noqa: BLE001 - best effort
            pass

    def test_version(self):
        version = self.client.request("GET", "/version")
        self.assertTrue(version)

    def test_resources(self):
        resources = self.client.resources()
        self.assertIsInstance(resources, list)

    def test_node_present(self):
        nodes = self.client.request("GET", "/nodes")
        self.assertTrue(nodes)

    def test_create_and_destroy_vm(self):
        node = self.client.request("GET", "/nodes")[0]["node"]
        # Best-effort pre-clean so a crashed earlier run cannot block us.
        self._destroy_quiet(node, "qemu", VMID)
        upid = guests.create_vm(self.client, node, VMID, "smoke-vm",
                                memory=512, cores=1)
        try:
            tasks.wait_task(self.client, node, upid, timeout=180)
            state = guests.status(self.client, node, "qemu", VMID)
            self.assertEqual(state.get("vmid"), VMID)
        finally:
            dupid = guests.destroy(self.client, node, "qemu", VMID)
            tasks.wait_task(self.client, node, dupid, timeout=180)
            self._destroy_quiet(node, "qemu", VMID)

    def _destroy_quiet(self, node, kind, vmid):
        try:
            upid = guests.destroy(self.client, node, kind, vmid)
            tasks.wait_task(self.client, node, upid, timeout=120)
        except api.APIError:
            pass


if __name__ == "__main__":
    unittest.main()
