"""Live backup and restore tests against a running SuperMox VM.

Skips unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, with
the SSL fingerprint, only when a VM is up). These call the same ops functions
the Storage page uses, so the vzdump backup and restore parameter set is proven
against the real server, not a fake.
"""

import os
import unittest

from supermox_manager import api
from supermox_manager.ops import guests, storage, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class BackupRestore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASSWORD)
        cls.node = cls.client.request("GET", "/nodes")[0]["node"]

    @classmethod
    def tearDownClass(cls):
        try:
            cls.client.logout()
        except Exception:  # noqa: BLE001 - best effort
            pass

    def _guests(self):
        return [r for r in self.client.request("GET", "/cluster/resources")
                if r["type"] in ("qemu", "lxc")]

    def _backup_volumes(self):
        return sorted(row["volid"] for row in storage.content(self.client, self.node, "local",
                                                              content_type="backup"))

    def test_backup_then_restore(self):
        guests_here = self._guests()
        if not guests_here:
            self.skipTest("no guest to back up on this node")
        guest = next((g for g in guests_here if g["type"] == "lxc"), guests_here[0])
        kind = guest["type"]
        vmid = int(guest["vmid"])

        upid = storage.backup(self.client, self.node, vmid, storage="local", mode="snapshot")
        self.assertTrue(upid.startswith("UPID:"))
        tasks.wait_task(self.client, self.node, upid, timeout=300)

        before = self._backup_volumes()
        self.assertTrue(before, "the backup should have produced a volume")
        volume = before[-1]

        new_id = int(guests.next_id(self.client))
        try:
            restore = storage.restore(self.client, self.node, kind, new_id, volume)
            self.assertTrue(restore.startswith("UPID:"))
            tasks.wait_task(self.client, self.node, restore, timeout=300)
            state = guests.status(self.client, self.node, kind, new_id)
            self.assertEqual(int(state["vmid"]), new_id)
        finally:
            guests.destroy(self.client, self.node, kind, new_id)
            storage.delete_volume(self.client, self.node, "local", volume)


if __name__ == "__main__":
    unittest.main()
