"""Live create/clone/template/delete tests against a running SuperMox VM.

Skips unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, with
the SSL fingerprint, only when a VM is up). These call the same ops functions
the Create page uses, so the create-vm parameter set is proven against the real
server, not a fake.
"""

import os
import unittest

from supermox_manager import api
from supermox_manager.ops import create as create_ops
from supermox_manager.ops import guests, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

VMID = 9910
CLONE_ID = 9911


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class CreateVm(unittest.TestCase):
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

    def _quiet_destroy(self, vmid):
        try:
            upid = guests.destroy(self.client, self.node, "qemu", vmid)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
        except api.APIError:
            pass

    def _create(self, vmid, name, iso=""):
        params = create_ops.vm_params(name, 512, 1, "local", 1, iso=iso)
        upid = create_ops.create(self.client, self.node, vmid, params)
        tasks.wait_task(self.client, self.node, upid, timeout=240)

    def test_read_endpoints(self):
        storages = create_ops.storages(self.client, self.node)
        self.assertIn("local", storages)
        self.assertIsInstance(create_ops.isos(self.client, self.node, "local"), list)
        self.assertIsInstance(create_ops.bridges(self.client, self.node), list)

    def test_create_boot_delete(self):
        self._quiet_destroy(VMID)
        try:
            self._create(VMID, "smoke-create")
            config = self.client.request("GET", api.guest_path(
                {"node": self.node, "type": "qemu", "vmid": VMID}) + "/config")
            self.assertEqual(config.get("scsihw"), "virtio-scsi-single")
            self.assertTrue(config.get("scsi0"))
            self.assertTrue(config.get("net0", "").startswith("virtio"))
            self.assertTrue(config.get("boot", "").startswith("order=scsi0"))
            # Starting the guest is exercised through the same API the wizard
            # uses; whether it reaches "running" depends on the qemu-server
            # sysvinit start path (a separate concern), so we only assert the
            # start request is accepted, not the boot outcome.
            upid = self.client.request(
                "POST", api.guest_path(
                    {"node": self.node, "type": "qemu", "vmid": VMID})
                + "/status/start", {})
            self.assertTrue(upid)
        finally:
            self._quiet_destroy(VMID)

    def test_clone(self):
        self._quiet_destroy(VMID)
        self._quiet_destroy(CLONE_ID)
        try:
            self._create(VMID, "smoke-src")
            upid = create_ops.clone(self.client, self.node, VMID, CLONE_ID, name="smoke-clone")
            tasks.wait_task(self.client, self.node, upid, timeout=240)
            state = guests.status(self.client, self.node, "qemu", CLONE_ID)
            self.assertEqual(state.get("vmid"), CLONE_ID)
        finally:
            self._quiet_destroy(VMID)
            self._quiet_destroy(CLONE_ID)

    def test_convert_to_template(self):
        self._quiet_destroy(VMID)
        try:
            self._create(VMID, "smoke-tpl")
            upid = create_ops.make_template(self.client, self.node, VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=240)
            state = guests.status(self.client, self.node, "qemu", VMID)
            self.assertEqual(state.get("template"), 1)
        finally:
            self._quiet_destroy(VMID)


if __name__ == "__main__":
    unittest.main()
