"""Offline unit tests for the ops layer: a fake client records every call."""

import unittest

from supermox_manager.ops import guests, tasks, create as create_ops
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


class CreateOps(unittest.TestCase):
    def test_vm_params_full(self):
        params = create_ops.vm_params("web01", 1024, 2, "local", 20,
                                      iso="local:iso/ubuntu.iso", bridge="vmbr0")
        self.assertEqual(params["name"], "web01")
        self.assertEqual(params["memory"], 1024)
        self.assertEqual(params["cores"], 2)
        self.assertEqual(params["scsihw"], "virtio-scsi-single")
        self.assertEqual(params["scsi0"], "local:20")
        self.assertEqual(params["net0"], "virtio,bridge=vmbr0")
        self.assertEqual(params["ide2"], "local:iso/ubuntu.iso,media=cdrom")
        self.assertEqual(params["boot"], "order=scsi0;ide2;net0")

    def test_vm_params_no_iso_no_bridge(self):
        params = create_ops.vm_params("a1", 512, 1, "local", 8)
        self.assertNotIn("ide2", params)
        self.assertEqual(params["net0"], "virtio")
        self.assertEqual(params["boot"], "order=scsi0;net0")

    def test_vm_params_rejects_bad_names(self):
        for bad in ("", "-lead", "trail-", "up per", "x" * 64, "a__b"):
            with self.assertRaises(ValueError):
                create_ops.vm_params(bad, 512, 1, "local", 8)

    def test_vm_params_rejects_bad_numbers(self):
        with self.assertRaises(ValueError):
            create_ops.vm_params("ok", 0, 1, "local", 8)
        with self.assertRaises(ValueError):
            create_ops.vm_params("ok", 512, 0, "local", 8)
        with self.assertRaises(ValueError):
            create_ops.vm_params("ok", 512, 1, "local", 0)

    def test_vm_params_rejects_bad_storage_and_bridge(self):
        with self.assertRaises(ValueError):
            create_ops.vm_params("ok", 512, 1, "bad storage", 8)
        with self.assertRaises(ValueError):
            create_ops.vm_params("ok", 512, 1, "local", 8, bridge="a b")

    def test_vm_params_ostype(self):
        with self.assertRaises(ValueError):
            create_ops.vm_params("ok", 512, 1, "local", 8, ostype="ubuntu")
        params = create_ops.vm_params("ok", 512, 1, "local", 8, ostype="win11")
        self.assertEqual(params["ostype"], "win11")
        self.assertEqual(create_ops.vm_params("ok", 512, 1, "local", 8)["ostype"],
                         "other")

    def test_vm_params_accepts_absolute_iso(self):
        params = create_ops.vm_params("ok", 512, 1, "local", 8, iso="/tmp/x.iso")
        self.assertEqual(params["ide2"], "/tmp/x.iso,media=cdrom")

    def test_create_reuses_guests_create_vm(self):
        client = FakeClient(["UPID:c:qemu"])
        params = create_ops.vm_params("web01", 1024, 2, "local", 20)
        upid = create_ops.create(client, "pve", 105, params)
        self.assertEqual(upid, "UPID:c:qemu")
        method, path, sent = client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/pve/qemu"))
        self.assertEqual(sent["name"], "web01")
        self.assertEqual(sent["memory"], 1024)
        self.assertEqual(sent["cores"], 2)
        self.assertEqual(sent["scsi0"], "local:20")
        self.assertEqual(sent["boot"], "order=scsi0;net0")

    def test_storages_isos_bridges_parse(self):
        client = FakeClient([[{"storage": "local"}, {"storage": "secondary"}]])
        self.assertEqual(create_ops.storages(client, "pve"), ["local", "secondary"])
        self.assertEqual(client.calls[-1][:2], ("GET", "/nodes/pve/storage"))
        client = FakeClient([[{"volid": "local:iso/a.iso"}]])
        self.assertEqual(create_ops.isos(client, "pve", "local"), ["local:iso/a.iso"])
        self.assertEqual(client.calls[-1][:2], ("GET", "/nodes/pve/storage/local/content"))
        self.assertEqual(client.calls[-1][2], {"content": "iso"})
        client = FakeClient([[{"bridge": "vmbr0"}, {"bridge": "vmbr1"}]])
        self.assertEqual(create_ops.bridges(client, "pve"), ["vmbr0", "vmbr1"])
        self.assertEqual(client.calls[-1][:2], ("GET", "/nodes/pve/network"))

    def test_clone_params(self):
        client = FakeClient(["UPID:clone"])
        self.assertEqual(create_ops.clone(client, "pve", 100, 105, name="copy"), "UPID:clone")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/pve/qemu/100/clone"))
        self.assertEqual(params, {"newid": 105, "full": 1, "name": "copy"})

    def test_make_template_path(self):
        client = FakeClient(["UPID:tpl"])
        self.assertEqual(create_ops.make_template(client, "pve", 100), "UPID:tpl")
        self.assertEqual(client.calls[-1][:2], ("POST", "/nodes/pve/qemu/100/template"))


if __name__ == "__main__":
    unittest.main()
