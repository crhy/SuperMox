"""Unit tests for high availability: exact paths, params and id encoding.

Endpoints and parameter names come from `pvesh usage` on the running node
(recorded in .strata/notes-t75-manager-backup-jobs-ha.md). Note that this
version has migrated HA groups to rules, and that a resource id keeps its
colon inside the URL path.
"""

import unittest

from supermox_manager.ops import ha


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "ok"


class HaOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_sid(self):
        self.assertEqual(ha.sid("vm", 100), "vm:100")
        self.assertEqual(ha.sid("ct", "101"), "ct:101")
        with self.assertRaises(ValueError):
            ha.sid("docker", 100)
        with self.assertRaises(ValueError):
            ha.sid("vm", "10:0")

    def test_list_resources(self):
        ha.resources(self.client)
        ha.resources(self.client, kind="vm")
        self.assertEqual(self.client.calls,
                         [("GET", "/cluster/ha/resources", None),
                          ("GET", "/cluster/ha/resources", {"type": "vm"})])

    def test_add_resource(self):
        ha.add_resource(self.client, 100)
        self.assertEqual(self.client.calls[-1],
                         ("POST", "/cluster/ha/resources",
                          {"sid": "vm:100", "type": "vm", "state": "started"}))
        ha.add_resource(self.client, 101, kind="ct", state="enabled", group="lab",
                        failback=False, auto_rebalance=False, max_restart=0,
                        max_relocate=2, comment="keep it running")
        self.assertEqual(self.client.calls[-1][2],
                         {"sid": "ct:101", "type": "ct", "state": "enabled",
                          "group": "lab", "failback": 0, "auto-rebalance": 0,
                          "max_restart": 0, "max_relocate": 2,
                          "comment": "keep it running"})

    def test_add_resource_rejects_bad_state(self):
        with self.assertRaises(ValueError):
            ha.add_resource(self.client, 100, state="running")

    def test_update_resource_keeps_underscore_names(self):
        ha.update_resource(self.client, "vm:100", state="stopped",
                           auto_rebalance=False, max_restart=3)
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/cluster/ha/resources/vm:100"))
        self.assertEqual(params, {"state": "stopped", "auto-rebalance": 0,
                                   "max_restart": 3})

    def test_update_resource_validation(self):
        with self.assertRaises(ValueError):
            ha.update_resource(self.client, "vm:100")
        with self.assertRaises(ValueError):
            ha.update_resource(self.client, "vm:100", state="nope")

    def test_remove_resource(self):
        ha.remove_resource(self.client, "vm:100")
        self.assertEqual(self.client.calls[-1], ("DELETE", "/cluster/ha/resources/vm:100", None))
        with self.assertRaises(ValueError):
            ha.remove_resource(self.client, "100")
        with self.assertRaises(ValueError):
            ha.remove_resource(self.client, "vm:10:0")

    def test_add_rule(self):
        ha.add_rule(self.client, "lab", "node-affinity", nodes=["atlas", "orbit:2"],
                    resources=["vm:100"], affinity="positive", strict=True,
                    comment="prefer atlas")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/cluster/ha/rules"))
        self.assertEqual(params, {"rule": "lab", "type": "node-affinity",
                                   "nodes": ["atlas", "orbit:2"],
                                   "resources": ["vm:100"],
                                   "affinity": "positive", "strict": 1,
                                   "comment": "prefer atlas"})

    def test_add_rule_validation(self):
        with self.assertRaises(ValueError):
            ha.add_rule(self.client, "lab", "group", nodes=["atlas"],
                        resources=["vm:100"])
        with self.assertRaises(ValueError):
            ha.add_rule(self.client, "lab", "node-affinity", nodes=["atlas"])
        with self.assertRaises(ValueError):
            ha.add_rule(self.client, "lab", "node-affinity", nodes=["atlas"],
                        resources=["vm:100"], affinity="maybe")

    def test_remove_rule(self):
        ha.remove_rule(self.client, "lab")
        self.assertEqual(self.client.calls[-1], ("DELETE", "/cluster/ha/rules/lab", None))
        with self.assertRaises(ValueError):
            ha.remove_rule(self.client, "bad name")

    def test_status_and_groups(self):
        ha.status(self.client)
        ha.groups(self.client)
        self.assertEqual(self.client.calls,
                         [("GET", "/cluster/ha/status/current", None),
                          ("GET", "/cluster/ha/groups", None)])


if __name__ == "__main__":
    unittest.main()
