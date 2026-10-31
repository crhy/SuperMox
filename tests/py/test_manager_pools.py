"""Unit tests for resource pools: exact paths, params and member handling.

Endpoints and parameter names come from `pvesh usage` on the running node
(recorded in .strata/notes-t75-manager-backup-jobs-ha.md).
"""

import unittest

from supermox_manager.ops import pools


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "ok"


class PoolOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_list_and_read(self):
        pools.pools(self.client)
        pools.pool(self.client, "lab")
        self.assertEqual(self.client.calls,
                         [("GET", "/pools", None), ("GET", "/pools/lab", None)])

    def test_create(self):
        pools.create_pool(self.client, "lab", comment="lab machines")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/pools"))
        self.assertEqual(params, {"poolid": "lab", "comment": "lab machines"})
        pools.create_pool(self.client, "lab")
        self.assertEqual(self.client.calls[-1][2], {"poolid": "lab"})

    def test_create_rejects_bad_names(self):
        for bad in ("", "bad name", "a/b", "-lead"):
            with self.assertRaises(ValueError):
                pools.create_pool(self.client, bad)

    def test_add_members_accepts_one_or_many(self):
        pools.add_members(self.client, "lab", vms=100)
        self.assertEqual(self.client.calls[-1],
                         ("PUT", "/pools/lab", {"vms": ["100"]}))
        pools.add_members(self.client, "lab", vms="100, 101",
                          storage=["local:backup"], allow_move=True)
        self.assertEqual(self.client.calls[-1][2],
                         {"vms": ["100", "101"], "storage": ["local:backup"],
                          "allow-move": 1})

    def test_remove_members_sets_delete(self):
        pools.remove_members(self.client, "lab", vms=[100, 101])
        self.assertEqual(self.client.calls[-1],
                         ("PUT", "/pools/lab", {"delete": 1, "vms": ["100", "101"]}))

    def test_member_calls_need_something(self):
        with self.assertRaises(ValueError):
            pools.add_members(self.client, "lab")
        with self.assertRaises(ValueError):
            pools.remove_members(self.client, "lab", vms="")

    def test_delete(self):
        pools.delete_pool(self.client, "lab")
        self.assertEqual(self.client.calls[-1], ("DELETE", "/pools/lab", None))

    def test_pool_members(self):
        record = {"poolid": "lab", "members": [
            {"type": "qemu", "vmid": 100, "id": "qemu/100"},
            {"type": "lxc", "vmid": 101, "id": "lxc/101"},
            {"type": "storage", "storage": "local:backup",
             "id": "storage/node/local:backup"},
        ]}
        self.assertEqual(pools.pool_members(record),
                         [("guest", "100"), ("guest", "101"),
                          ("storage", "local:backup")])
        self.assertEqual(pools.pool_members({"poolid": "empty"}), [])


if __name__ == "__main__":
    unittest.main()
