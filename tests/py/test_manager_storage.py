"""Unit tests for the storage operations: exact paths, params and encoding.

A recording client proves each call hits the endpoint and parameter names the
running node advertises (see .strata/notes-t69-manager-storage.md). No server
and no GTK needed.
"""

import unittest

from supermox_manager.ops import storage


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "UPID:test"

    def upload(self, path, fields, filename, fileobj, size):
        self.calls.append(("UPLOAD", path, fields, filename, size))
        return "UPID:upload"


class StorageOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_storages(self):
        self.assertEqual(self.client.request("GET", "/x"), "UPID:test")
        self.client.calls.clear()
        storage.storages(self.client, "atlas")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/atlas/storage", None)])

    def test_content_filters(self):
        storage.content(self.client, "atlas", "local")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/atlas/storage/local/content", None)])
        storage.content(self.client, "atlas", "local", content_type="iso")
        self.assertEqual(self.client.calls[-1],
                         ("GET", "/nodes/atlas/storage/local/content", {"content": "iso"}))
        storage.content(self.client, "atlas", "local", vmid=100)
        self.assertEqual(self.client.calls[-1][2], {"vmid": 100})

    def test_delete_volume_keeps_colon_and_slash(self):
        storage.delete_volume(self.client, "atlas", "local", "local:iso/t69.iso")
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "DELETE")
        self.assertEqual(path, "/nodes/atlas/storage/local/content/local:iso/t69.iso")
        self.assertEqual(params, {"delay": 1})

    def test_delete_volume_encodes_spaces(self):
        storage.delete_volume(self.client, "atlas", "local", "local:iso/my file.iso")
        self.assertEqual(self.client.calls[-1][1],
                         "/nodes/atlas/storage/local/content/local:iso/my%20file.iso")

    def test_delete_volume_requires_a_volume(self):
        with self.assertRaises(ValueError):
            storage.delete_volume(self.client, "atlas", "local", "")

    def test_upload_streams_through_client_upload(self):
        storage.upload(self.client, "atlas", "local", "t.iso", None, 42,
                       content_type="iso")
        kind, path, fields, filename, size = self.client.calls[-1]
        self.assertEqual(kind, "UPLOAD")
        self.assertEqual(path, "/nodes/atlas/storage/local/upload")
        self.assertEqual(fields, {"content": "iso"})
        self.assertEqual((filename, size), ("t.iso", 42))

    def test_download_url(self):
        storage.download_url(self.client, "atlas", "local",
                             "https://x/y.iso", "y.iso", content_type="iso")
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "POST")
        self.assertEqual(path, "/nodes/atlas/storage/local/download-url")
        self.assertEqual(params, {"url": "https://x/y.iso", "filename": "y.iso",
                                  "content": "iso"})
        with self.assertRaises(ValueError):
            storage.download_url(self.client, "atlas", "local", "", "y.iso")

    def test_backup(self):
        storage.backup(self.client, "atlas", 100, storage="local")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/atlas/vzdump"))
        self.assertEqual(params, {"vmid": 100, "mode": "snapshot", "compress": 0,
                                   "storage": "local"})
        with self.assertRaises(ValueError):
            storage.backup(self.client, "atlas", 100, mode="bogus")

    def test_restore_vm(self):
        storage.restore(self.client, "atlas", "qemu", 100,
                        "local:backup/vm-100.tar.zst")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/atlas/qemu"))
        self.assertEqual(params, {"vmid": 100, "archive": "local:backup/vm-100.tar.zst"})

    def test_restore_ct(self):
        storage.restore(self.client, "atlas", "lxc", 101,
                        "local:backup/ct-101.tar.gz")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/atlas/lxc"))
        self.assertEqual(params, {"vmid": 101, "restore": 1,
                                  "ostemplate": "local:backup/ct-101.tar.gz"})

    def test_restore_validation(self):
        with self.assertRaises(ValueError):
            storage.restore(self.client, "atlas", "qemu", 100, "")
        with self.assertRaises(ValueError):
            storage.restore(self.client, "atlas", "docker", 100, "local:backup/x")
        with self.assertRaises(ValueError):
            storage.restore(self.client, "atlas", "qemu", 99, "local:backup/x")


if __name__ == "__main__":
    unittest.main()
