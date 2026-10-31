"""Unit tests for the node administration operations: exact paths, params and
verbs.

A recording client proves each call hits the endpoint and parameter names the
running node advertises (see .strata/notes-t72-manager-node-admin.md). No server
and no GTK needed.
"""

import unittest

from supermox_manager.ops import node


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return {}


class NodeOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_summary_hits_status_and_version(self):
        result = node.summary(self.client, "supermox")
        self.assertEqual(
            [c[:2] for c in self.client.calls],
            [("GET", "/nodes/supermox/status"),
             ("GET", "/nodes/supermox/version")])
        self.assertIn("pveversion", result)
        self.assertIn("kernel", result)

    def test_services(self):
        node.services(self.client, "supermox")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/services", None)])

    def test_service_action_verbs_and_path(self):
        node.service_action(self.client, "supermox", "pvestatd", "restart")
        self.assertEqual(self.client.calls,
                         [("POST", "/nodes/supermox/services/pvestatd/restart", None)])

    def test_service_action_rejects_unknown(self):
        for action in ("start", "stop", "restart", "reload"):
            node.service_action(self.client, "supermox", "pvestatd", action)
        with self.assertRaises(ValueError):
            node.service_action(self.client, "supermox", "pvestatd", "destroy")

    def test_syslog_defaults_and_filters(self):
        node.syslog(self.client, "supermox")
        self.assertEqual(self.client.calls[-1],
                         ("GET", "/nodes/supermox/syslog", {"start": 0, "limit": 500}))
        node.syslog(self.client, "supermox", start=10, limit=50, service="pve-proxy")
        self.assertEqual(self.client.calls[-1][2],
                         {"start": 10, "limit": 50, "service": "pve-proxy"})
        node.syslog(self.client, "supermox", since="2026-01-01 00:00:00",
                    until="2026-01-02 00:00:00")
        self.assertEqual(self.client.calls[-1][2],
                         {"start": 0, "limit": 500,
                          "since": "2026-01-01 00:00:00",
                          "until": "2026-01-02 00:00:00"})

    def test_updates_get(self):
        node.updates(self.client, "supermox")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/apt/update", None)])

    def test_refresh_updates_posts_quiet(self):
        node.refresh_updates(self.client, "supermox")
        self.assertEqual(self.client.calls,
                         [("POST", "/nodes/supermox/apt/update", {"quiet": 1})])

    def test_dns_get(self):
        node.dns(self.client, "supermox")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/dns", None)])

    def test_set_dns_put(self):
        node.set_dns(self.client, "supermox", search="example.com", dns1="10.0.2.3")
        self.assertEqual(self.client.calls,
                         [("PUT", "/nodes/supermox/dns",
                           {"search": "example.com", "dns1": "10.0.2.3"})])

    def test_set_dns_empty_string_clears(self):
        node.set_dns(self.client, "supermox", search="")
        self.assertEqual(self.client.calls[-1][2], {"search": ""})

    def test_set_dns_requires_a_field(self):
        with self.assertRaises(ValueError):
            node.set_dns(self.client, "supermox")

    def test_time_info(self):
        node.time_info(self.client, "supermox")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/time", None)])

    def test_set_timezone_put(self):
        node.set_timezone(self.client, "supermox", "Europe/Berlin")
        self.assertEqual(self.client.calls,
                         [("PUT", "/nodes/supermox/time", {"timezone": "Europe/Berlin"})])

    def test_set_timezone_rejects_empty(self):
        with self.assertRaises(ValueError):
            node.set_timezone(self.client, "supermox", "")

    def test_hosts_get(self):
        node.hosts(self.client, "supermox")
        self.assertEqual(self.client.calls,
                         [("GET", "/nodes/supermox/hosts", None)])


if __name__ == "__main__":
    unittest.main()
