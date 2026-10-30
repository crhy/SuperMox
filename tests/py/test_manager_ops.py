"""Offline unit tests for the ops layer: a fake client records every call."""

import unittest

from supermox_manager.ops import guests, tasks
from supermox_manager import api


class FakeClient:
    """Records (method, path, params) and returns canned data per call."""

    def __init__(self, responses=None):
        self.calls = []
        self.responses = list(responses or [])

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        if self.responses:
            return self.responses.pop(0)
        return {}


class GuestsOps(unittest.TestCase):
    def test_next_id_path(self):
        client = FakeClient([105])
        self.assertEqual(guests.next_id(client), 105)
        self.assertEqual(client.calls, [("GET", "/cluster/nextid", None)])

    def test_create_vm_defaults_and_params(self):
        client = FakeClient(["UPID:node:0000:qemu"])
        upid = guests.create_vm(client, "pve", 9900, "t-vm")
        self.assertEqual(upid, "UPID:node:0000:qemu")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/pve/qemu"))
        self.assertEqual(params, {"vmid": 9900, "name": "t-vm", "memory": 512, "cores": 1})

    def test_create_vm_extra_merges(self):
        client = FakeClient()
        guests.create_vm(client, "pve", 9901, "x", memory=128, cores=2,
                         extra={"ostype": "ubuntu", "netif_cardio": "yes"})
        _method, _path, params = client.calls[-1]
        self.assertEqual(params, {"vmid": 9901, "name": "x", "memory": 128, "cores": 2,
                                  "ostype": "ubuntu", "netif_cardio": "yes"})

    def test_create_vm_escapes_node(self):
        client = FakeClient()
        guests.create_vm(client, "a b", 1, "n")
        self.assertEqual(client.calls[-1][1], "/nodes/a%20b/qemu")

    def test_destroy_path_and_purge(self):
        client = FakeClient(["UPID:del"])
        self.assertEqual(guests.destroy(client, "pve", "qemu", 9900), "UPID:del")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("DELETE", "/nodes/pve/qemu/9900"))
        self.assertEqual(params, {"purge": 1})

    def test_destroy_lxc_kind(self):
        client = FakeClient()
        guests.destroy(client, "pve", "lxc", 9902)
        self.assertEqual(client.calls[-1][1], "/nodes/pve/lxc/9902")

    def test_destroy_rejects_bad_kind(self):
        client = FakeClient()
        with self.assertRaises(ValueError):
            guests.destroy(client, "pve", "pod", 1)
        self.assertEqual(client.calls, [])

    def test_status_path(self):
        client = FakeClient([{"status": "running"}])
        self.assertEqual(guests.status(client, "pve", "qemu", 9900), {"status": "running"})
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("GET", "/nodes/pve/qemu/9900/status/current"))
        self.assertIsNone(params)

    def test_status_rejects_bad_kind(self):
        with self.assertRaises(ValueError):
            guests.status(FakeClient(), "pve", "pod", 1)


class TasksOps(unittest.TestCase):
    def test_wait_task_ok_returns_exitstatus(self):
        client = FakeClient([{"status": "stopped", "exitstatus": "OK"}])
        self.assertEqual(tasks.wait_task(client, "pve", "UPID:1:2:3", timeout=0), "OK")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("GET", "/nodes/pve/tasks/UPID%3A1%3A2%3A3/status"))
        self.assertIsNone(params)

    def test_wait_task_polls_until_stopped(self):
        client = FakeClient([{"status": "running"}, {"status": "stopped", "exitstatus": "OK"}])
        self.assertEqual(tasks.wait_task(client, "pve", "u", timeout=30), "OK")
        self.assertEqual(len(client.calls), 2)
        self.assertTrue(all(c[0] == "GET" for c in client.calls))

    def test_wait_task_raises_on_failure(self):
        client = FakeClient([{"status": "stopped", "exitstatus": "failed"}])
        with self.assertRaises(api.APIError) as caught:
            tasks.wait_task(client, "pve", "u", timeout=0)
        self.assertIn("failed", str(caught.exception))

    def test_wait_task_raises_on_timeout(self):
        client = FakeClient([{"status": "running"}] * 50)
        with self.assertRaises(api.APIError):
            tasks.wait_task(client, "pve", "u", timeout=0)


if __name__ == "__main__":
    unittest.main()
