"""Unit tests for the network operations: exact paths and parameter names.

A recording client proves each call hits the endpoint and parameter set the
running node advertises (see .strata/notes-t73-manager-network-disks.md). No
server and no GTK needed.
"""

import unittest

from supermox_manager.ops import network


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "data"


class NetworkOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_interfaces(self):
        network.interfaces(self.client, "atlas")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/atlas/network", None)])

    def test_create_required_and_options(self):
        network.create(self.client, "atlas", "vmbr98", "bridge",
                       cidr="10.98.98.1/24", bridge_ports="10.98.98.2-10.98.98.254",
                       autostart=True)
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "POST")
        self.assertEqual(path, "/nodes/atlas/network")
        self.assertEqual(params, {
            "iface": "vmbr98", "type": "bridge",
            "cidr": "10.98.98.1/24", "bridge_ports": "10.98.98.2-10.98.98.254",
            "autostart": 1})

    def test_create_requires_iface_and_type(self):
        with self.assertRaises(ValueError):
            network.create(self.client, "atlas", "", "bridge")
        with self.assertRaises(ValueError):
            network.create(self.client, "atlas", "vmbr98", "")

    def test_update_puts_iface_in_path(self):
        network.update(self.client, "atlas", "vmbr98", type="eth", autostart=False)
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "PUT")
        self.assertEqual(path, "/nodes/atlas/network/vmbr98")
        self.assertEqual(params, {"type": "eth", "autostart": 0})

    def test_update_requires_iface(self):
        with self.assertRaises(ValueError):
            network.update(self.client, "atlas", "")

    def test_delete(self):
        network.delete(self.client, "atlas", "vmbr98")
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "DELETE")
        self.assertEqual(path, "/nodes/atlas/network/vmbr98")
        self.assertEqual(params, {})

    def test_apply_returns_task_and_regenerate_frr(self):
        network.apply(self.client, "atlas")
        method, path, params = self.client.calls[-1]
        self.assertEqual(method, "PUT")
        self.assertEqual(path, "/nodes/atlas/network")
        self.assertEqual(params, {"regenerate-frr": 0})
        network.apply(self.client, "atlas", regenerate_frr=True)
        self.assertEqual(self.client.calls[-1][2], {"regenerate-frr": 1})

    def test_iface_is_url_segmented(self):
        network.delete(self.client, "n od", "vm br")
        self.assertEqual(self.client.calls[-1][1], "/nodes/n%20od/network/vm%20br")


if __name__ == "__main__":
    unittest.main()
