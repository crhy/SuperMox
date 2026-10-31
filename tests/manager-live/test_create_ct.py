"""Live template and container tests against a running SuperMox VM.

Skips unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, with
the SSL fingerprint, only when a VM is up). These call the same ops functions
the Templates page uses, so the create-ct parameter set is proven against the
real server, not a fake.
"""

import os
import time
import unittest

from supermox_manager import api
from supermox_manager.ops import containers as ct_ops
from supermox_manager.ops import create as create_ops
from supermox_manager.ops import guests, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

VMID = 9920
# Newest Alpine system image; the exact name comes from the node's own index.
APPLIANCE_OS = "alpine"


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class CreateCt(unittest.TestCase):
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

    def _quiet_destroy(self):
        try:
            upid = ct_ops.stop_ct(self.client, self.node, VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=120)
        except api.APIError:
            pass
        try:
            upid = guests.destroy(self.client, self.node, "lxc", VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
        except api.APIError:
            pass

    def _template(self):
        """Return a downloaded template volid, downloading Alpine if needed."""
        downloaded = ct_ops.templates(self.client, self.node)
        if downloaded:
            return sorted(downloaded)[0]
        rows = [row for row in ct_ops.available_templates(self.client, self.node)
                if row["os"] == APPLIANCE_OS]
        if not rows:
            self.skipTest("no {} appliance in this node's index".format(APPLIANCE_OS))
        name = rows[-1]["template"]
        upid = ct_ops.download_template(self.client, self.node, "local", name)
        tasks.wait_task(self.client, self.node, upid, timeout=600)
        downloaded = ct_ops.templates(self.client, self.node)
        self.assertIn("local:vztmpl/" + name, downloaded)
        return "local:vztmpl/" + name

    def _create(self, template, bridge=""):
        params = ct_ops.ct_params({"hostname": "smoke-ct", "template": template,
                                   "storage": "local", "size": 1, "memory": 64,
                                   "cores": 1, "bridge": bridge,
                                   "password": LIVE_PASSWORD})
        upid = ct_ops.create_ct(self.client, self.node, VMID, params)
        tasks.wait_task(self.client, self.node, upid, timeout=300)

    def _path(self):
        return api.guest_path({"node": self.node, "type": "lxc", "vmid": VMID})

    def test_read_endpoints(self):
        self.assertIn("local", ct_ops.template_storages(self.client, self.node))
        self.assertIsInstance(ct_ops.templates(self.client, self.node), list)
        rows = ct_ops.available_templates(self.client, self.node)
        self.assertTrue(rows, "the appliance index should not be empty")
        self.assertTrue([row for row in rows if row["template"]])

    def test_download_then_create_start_stop_delete(self):
        self._quiet_destroy()
        try:
            template = self._template()
            bridges = create_ops.bridges(self.client, self.node)
            self._create(template, bridges[0] if bridges else "")
            config = self.client.request("GET", self._path() + "/config")
            self.assertEqual(config.get("hostname"), "smoke-ct")
            self.assertEqual(config.get("unprivileged"), 1)
            # The server expands our storage:size shorthand into a real volid.
            self.assertTrue(config.get("rootfs", "").startswith("local:9920/"))
            self.assertIn("size=1G", config.get("rootfs", ""))
            self.assertEqual(config.get("memory"), 64)
            self.assertEqual(config.get("ostype"), APPLIANCE_OS)
            # The server never returns the root password we sent.
            self.assertNotIn("password", config)
            if bridges:
                self.assertIn("bridge=" + bridges[0], config.get("net0", ""))
            else:
                self.assertNotIn("net0", config)

            upid = ct_ops.start_ct(self.client, self.node, VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
            state = guests.status(self.client, self.node, "lxc", VMID)
            self.assertEqual(state.get("status"), "running")
            # uptime is whole seconds, so give the init process a moment.
            uptime = 0
            for _ in range(10):
                time.sleep(1)
                uptime = guests.status(self.client, self.node, "lxc", VMID).get("uptime", 0)
                if uptime >= 1:
                    break
            self.assertGreaterEqual(uptime, 1)

            upid = ct_ops.stop_ct(self.client, self.node, VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
            state = guests.status(self.client, self.node, "lxc", VMID)
            self.assertEqual(state.get("status"), "stopped")

            upid = guests.destroy(self.client, self.node, "lxc", VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
            with self.assertRaises(api.APIError):
                guests.status(self.client, self.node, "lxc", VMID)
        finally:
            self._quiet_destroy()


if __name__ == "__main__":
    unittest.main()
