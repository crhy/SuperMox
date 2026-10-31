"""Live storage content and upload/delete tests against a running SuperMox VM.

Skips unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, with
the SSL fingerprint, only when a VM is up). These call the same ops functions
the Storage page uses, so the storage parameter set is proven against the real
server, not a fake.
"""

import io
import os
import unittest

from supermox_manager import api
from supermox_manager.ops import storage, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

UPLOAD_NAME = "t69-smoke.iso"
UPLOAD_VOLID = "local:iso/" + UPLOAD_NAME


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class StorageContent(unittest.TestCase):
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

    def _iso_volumes(self):
        return [row["volid"] for row in storage.content(self.client, self.node, "local",
                                                        content_type="iso")]

    def _quiet_delete(self):
        try:
            storage.delete_volume(self.client, self.node, "local", UPLOAD_VOLID)
        except api.APIError:
            pass

    def test_read_endpoints(self):
        names = [entry["storage"] for entry in storage.storages(self.client, self.node)]
        self.assertIn("local", names)
        self.assertIsInstance(storage.content(self.client, self.node, "local"), list)

    def test_upload_list_delete(self):
        self._quiet_delete()
        try:
            data = b"supermox t69 live upload\n" * 40
            upid = storage.upload(self.client, self.node, "local", UPLOAD_NAME,
                                  io.BytesIO(data), len(data), content_type="iso")
            self.assertTrue(upid.startswith("UPID:"))
            tasks.wait_task(self.client, self.node, upid, timeout=60)
            self.assertIn(UPLOAD_VOLID, self._iso_volumes())
            storage.delete_volume(self.client, self.node, "local", UPLOAD_VOLID)
            self.assertNotIn(UPLOAD_VOLID, self._iso_volumes())
        finally:
            self._quiet_delete()


if __name__ == "__main__":
    unittest.main()
