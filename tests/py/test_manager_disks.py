"""Unit tests for the disk operations: exact paths and parameter names.

A recording client proves each call hits the endpoint and parameter set the
running node advertises (see .strata/notes-t73-manager-network-disks.md). No
server and no GTK needed.
"""

import unittest

from supermox_manager.ops import disks


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "data"


class DiskOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_disks_list(self):
        disks.disks(self.client, "atlas")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/atlas/disks/list", None)])

    def test_smart(self):
        disks.smart(self.client, "atlas", "/dev/vda")
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "GET")
        self.assertEqual(path, "/nodes/atlas/disks/smart")
        self.assertEqual(params, {"disk": "/dev/vda"})

    def test_smart_healthonly(self):
        disks.smart(self.client, "atlas", "/dev/nvme0n1", healthonly=True)
        self.assertEqual(self.client.calls[-1][2],
                         {"disk": "/dev/nvme0n1", "healthonly": 1})

    def test_smart_requires_disk(self):
        with self.assertRaises(ValueError):
            disks.smart(self.client, "atlas", "")

    def test_directories(self):
        disks.directories(self.client, "atlas")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/atlas/disks/directory", None)])

    def test_node_is_url_segmented(self):
        disks.disks(self.client, "n od")
        self.assertEqual(self.client.calls[-1][1], "/nodes/n%20od/disks/list")


if __name__ == "__main__":
    unittest.main()
