"""Unit tests for the native firewall operations.

Paths and parameter names come from `pvesh usage <path> --verbose` on the
running node (recorded in .strata/notes-t76-manager-firewall.md). The same
operations run against three base paths: /cluster/firewall, /nodes/{node}/firewall
and /nodes/{node}/{kind}/{vmid}/firewall.
"""

import unittest

from supermox_manager.ops import firewall


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "ok"


class BaseFor(unittest.TestCase):
    def test_cluster(self):
        self.assertEqual(firewall.base_for(), "/cluster/firewall")

    def test_node(self):
        self.assertEqual(firewall.base_for(node="supermox"),
                         "/nodes/supermox/firewall")

    def test_guest(self):
        self.assertEqual(firewall.base_for(node="supermox", kind="qemu", vmid=9980),
                         "/nodes/supermox/qemu/9980/firewall")
        self.assertEqual(firewall.base_for(node="supermox", kind="lxc", vmid="101"),
                         "/nodes/supermox/lxc/101/firewall")

    def test_rejects_bad_combinations(self):
        with self.assertRaises(ValueError):
            firewall.base_for(vmid=9980)
        with self.assertRaises(ValueError):
            firewall.base_for(node="supermox", kind="qemu")
        with self.assertRaises(ValueError):
            firewall.base_for(node="supermox", kind="docker", vmid=9980)
        with self.assertRaises(ValueError):
            firewall.base_for(node="")


class Rules(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_list(self):
        firewall.rules(self.client, "/cluster/firewall")
        self.assertEqual(self.client.calls,
                         [("GET", "/cluster/firewall/rules", None)])

    def test_add_minimal(self):
        firewall.add_rule(self.client, "/cluster/firewall", action="ACCEPT",
                          type="forward", dport="22")
        self.assertEqual(self.client.calls[-1],
                         ("POST", "/cluster/firewall/rules",
                          {"action": "ACCEPT", "type": "forward", "dport": "22"}))

    def test_add_full(self):
        firewall.add_rule(self.client, "/nodes/supermox/firewall", action="REJECT",
                          type="in", source="10.0.0.0/8", dest="192.168.1.1",
                          proto="tcp", dport="80", sport="90", iface="fw-in",
                          comment="block lab", log=True, macro="WHITELISTED",
                          icmp_type="echo-reply", enable=1, pos=2)
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/supermox/firewall/rules"))
        self.assertEqual(params, {
            "action": "REJECT", "type": "in", "source": "10.0.0.0/8",
            "dest": "192.168.1.1", "proto": "tcp", "dport": "80", "sport": "90",
            "iface": "fw-in", "comment": "block lab", "log": 1,
            "macro": "WHITELISTED", "icmp-type": "echo-reply", "enable": 1,
            "pos": 2})

    def test_add_validation(self):
        with self.assertRaises(ValueError):
            firewall.add_rule(self.client, "/cluster/firewall", action="ACCEPT",
                              type="maybe")
        with self.assertRaises(ValueError):
            firewall.add_rule(self.client, "/cluster/firewall", action="bad name",
                              type="forward")

    def test_update(self):
        firewall.update_rule(self.client, "/cluster/firewall", 1, action="DROP",
                             comment="now drop it")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/cluster/firewall/rules/1"))
        self.assertEqual(params, {"action": "DROP", "comment": "now drop it"})

    def test_update_requires_a_field(self):
        with self.assertRaises(ValueError):
            firewall.update_rule(self.client, "/cluster/firewall", 1)

    def test_move(self):
        firewall.move_rule(self.client, "/cluster/firewall", 1, 0)
        self.assertEqual(self.client.calls[-1],
                         ("PUT", "/cluster/firewall/rules/1", {"moveto": 0}))

    def test_delete(self):
        firewall.delete_rule(self.client, "/cluster/firewall", 0)
        self.assertEqual(self.client.calls[-1],
                         ("DELETE", "/cluster/firewall/rules/0", {}))

    def test_position_validation(self):
        with self.assertRaises(ValueError):
            firewall.delete_rule(self.client, "/cluster/firewall", "first")
        with self.assertRaises(ValueError):
            firewall.move_rule(self.client, "/cluster/firewall", 0, -1)


class Options(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_get(self):
        firewall.options(self.client, "/nodes/supermox/qemu/9980/firewall")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/qemu/9980/firewall/options", None)])

    def test_set_keeps_underscore_names_and_maps_booleans(self):
        firewall.set_options(self.client, "/nodes/supermox/qemu/9980/firewall",
                             enable=True, policy_in="DROP", policy_out="ACCEPT",
                             ipfilter=False, log_level_in="info")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path),
                         ("PUT", "/nodes/supermox/qemu/9980/firewall/options"))
        self.assertEqual(params, {"enable": 1, "policy_in": "DROP",
                                  "policy_out": "ACCEPT", "ipfilter": 0,
                                  "log_level_in": "info"})

    def test_set_requires_a_field(self):
        with self.assertRaises(ValueError):
            firewall.set_options(self.client, "/cluster/firewall")


class Aliases(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_list(self):
        firewall.aliases(self.client, "/cluster/firewall")
        self.assertEqual(self.client.calls,
                         [("GET", "/cluster/firewall/aliases", None)])

    def test_add(self):
        firewall.add_alias(self.client, "/cluster/firewall", name="t76a",
                           cidr="10.0.0.7", comment="test alias")
        self.assertEqual(self.client.calls[-1],
                         ("POST", "/cluster/firewall/aliases",
                          {"name": "t76a", "cidr": "10.0.0.7",
                           "comment": "test alias"}))

    def test_add_requires_cidr(self):
        with self.assertRaises(ValueError):
            firewall.add_alias(self.client, "/cluster/firewall", name="t76a", cidr="")

    def test_add_rejects_bad_name(self):
        with self.assertRaises(ValueError):
            firewall.add_alias(self.client, "/cluster/firewall", name="9bad", cidr="10.0.0.7")

    def test_delete(self):
        firewall.delete_alias(self.client, "/cluster/firewall", "t76a")
        self.assertEqual(self.client.calls[-1],
                         ("DELETE", "/cluster/firewall/aliases/t76a", {}))


class Ipsets(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_list(self):
        firewall.ipsets(self.client, "/cluster/firewall")
        self.assertEqual(self.client.calls,
                         [("GET", "/cluster/firewall/ipset", None)])

    def test_members(self):
        firewall.ipset_members(self.client, "/cluster/firewall", "t76s")
        self.assertEqual(self.client.calls[-1],
                         ("GET", "/cluster/firewall/ipset/t76s", None))

    def test_add_set(self):
        firewall.add_ipset(self.client, "/cluster/firewall", name="t76s",
                           comment="a set")
        self.assertEqual(self.client.calls[-1],
                         ("POST", "/cluster/firewall/ipset",
                          {"name": "t76s", "comment": "a set"}))

    def test_add_cidr(self):
        firewall.add_cidr(self.client, "/cluster/firewall", "t76s",
                          cidr="10.0.0.7", nomatch=True)
        self.assertEqual(self.client.calls[-1],
                         ("POST", "/cluster/firewall/ipset/t76s",
                          {"cidr": "10.0.0.7", "nomatch": 1}))

    def test_add_cidr_requires_cidr(self):
        with self.assertRaises(ValueError):
            firewall.add_cidr(self.client, "/cluster/firewall", "t76s", cidr="")

    def test_delete_set(self):
        firewall.delete_ipset(self.client, "/cluster/firewall", "t76s")
        self.assertEqual(self.client.calls[-1],
                         ("DELETE", "/cluster/firewall/ipset/t76s", {}))
        firewall.delete_ipset(self.client, "/cluster/firewall", "t76s", force=True)
        self.assertEqual(self.client.calls[-1],
                         ("DELETE", "/cluster/firewall/ipset/t76s", {"force": 1}))


if __name__ == "__main__":
    unittest.main()
