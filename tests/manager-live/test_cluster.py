#!/usr/bin/env python3
"""Live tests for the cluster page's calls against a running SuperMox node.

Skipped unless SUPERMOX_LIVE_URL points at a reachable node. Reads quorum,
the node rows, the cluster log and the datacenter options, and puts one
datacenter option through set, read-back and reset. Cleans up before and
after, so the node ends with the options it started with.
"""
import inspect
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))

from supermox_manager import api
from supermox_manager.ops import cluster

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASS = os.environ.get("SUPERMOX_LIVE_PASS", "")

DESCRIPTION = "t78 live probe"


class ClusterLive(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not LIVE_URL:
            raise unittest.SkipTest("SUPERMOX_LIVE_URL not set")
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASS)

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "client", None):
            try:
                cls.client.request("PUT", "/cluster/options",
                                   {"delete": "description,migration"})
            except Exception:
                pass
            cls.client.logout()

    def _reset(self):
        cluster.set_options(self.client, delete="description,migration")

    def test_status_separates_quorum_from_nodes(self):
        rows = cluster.status(self.client)
        head = cluster.cluster_row(rows)
        nodes = cluster.node_rows(rows)
        self.assertIsInstance(head, dict)
        for key in ("name", "nodes", "quorate", "version"):
            self.assertIn(key, head)
        self.assertTrue(nodes)
        # Measured: the cluster row carries numbers, the node rows carry
        # numbers too, and exactly one node row says it is this one.
        self.assertIsInstance(head["nodes"], int)
        self.assertEqual(len([row for row in nodes if row.get("local")]), 1)
        self.assertEqual(head["nodes"], len(nodes))

    def test_config_nodes_is_a_separate_answer(self):
        rows = cluster.nodes(self.client)
        self.assertTrue(rows)
        for key in ("name", "nodeid", "quorum_votes", "ring0_addr"):
            self.assertIn(key, rows[0])
        # Measured: every value in this answer is a string.
        self.assertTrue(all(isinstance(value, str) for value in rows[0].values()))

    def test_log_comes_back_newest_first_and_has_no_limit(self):
        rows = cluster.log(self.client, max=None)
        self.assertTrue(rows)
        numbers = [int(row["id"].split(":")[0]) for row in rows]
        self.assertEqual(numbers, sorted(numbers, reverse=True))
        # The slice keeps the newest entries, which is what the page shows.
        self.assertEqual(cluster.log(self.client, max=1), rows[:1])
        for row in rows[:3]:
            self.assertRegex(cluster.log_time(row), r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$")
            self.assertIn(cluster.LEVEL_NAMES.get(int(row["pri"])),
                          ("emerg", "alert", "crit", "err", "warning",
                           "notice", "info", "debug"))

    def test_tasks_page_reads_the_cluster_task_list(self):
        # The Tasks page goes through api.Client.tasks(); the cluster page
        # goes through ops.cluster.cluster_tasks(). Both must be GET /cluster/tasks.
        page = cluster.cluster_tasks(self.client)
        tasks_page = self.client.tasks()
        self.assertEqual([row["upid"] for row in page],
                         [row["upid"] for row in tasks_page])
        for row in page[:5]:
            for key in ("upid", "node", "type", "status", "starttime"):
                self.assertIn(key, row)

    def test_options_round_trip_and_reset(self):
        self._reset()
        before = cluster.options(self.client)
        self.assertNotEqual(before.get("description"), DESCRIPTION)

        cluster.set_options(self.client, description=DESCRIPTION)
        record = cluster.options(self.client)
        # Measured: the node stores the description with a trailing newline,
        # so the page reads it through option_text(), which strips.
        self.assertEqual(record.get("description").strip(), DESCRIPTION)
        self.assertEqual(cluster.option_text("description", record), DESCRIPTION)

        # A hash option: sent as a plain string, read back as a dict.
        cluster.set_options(self.client, migration="secure")
        record = cluster.options(self.client)
        self.assertEqual(record["migration"], {"type": "secure"})
        self.assertEqual(cluster.option_text("migration", record), "secure")

        self._reset()
        record = cluster.options(self.client)
        self.assertNotIn("migration", record)
        self.assertNotEqual(record.get("description"), DESCRIPTION)

    def test_the_node_refuses_a_json_object_for_a_hash_option(self):
        # Measured: HTTP 400 "Check fields: migration".
        with self.assertRaises(api.APIError):
            self.client.request("PUT", "/cluster/options",
                                {"migration": json.dumps({"type": "secure"})})
        with self.assertRaises(api.APIError):
            self.client.request("PUT", "/cluster/options",
                                {"migration": "maybe"})

    def test_the_join_config_is_never_read(self):
        # /cluster/config/join carries pve_fp and config_digest. Nothing in
        # ops/cluster.py may fetch it: check the body of every function.
        for name in dir(cluster):
            if name.startswith("_"):
                continue
            function = getattr(cluster, name)
            if not inspect.isfunction(function):
                continue
            source = inspect.getsource(function)
            self.assertNotIn("config/join", source, name)
            self.assertNotIn("pve_fp", source, name)

    def test_join_command_refuses_arguments_that_are_not_arguments(self):
        line = cluster.join_command("orbit", "10.0.0.5",
                                    " ".join(["abandon"] * 11 + ["ability"]))
        self.assertTrue(line.startswith("supermox-join join --name orbit"))
        for bad in (("orbit; rm -rf /", "10.0.0.5", None),
                    ("orbit", "10.0.0.5; id", None),
                    ("orbit", "10.0.0.5", "abandon ability")):
            with self.assertRaises(ValueError):
                cluster.join_command(*bad)


if __name__ == "__main__":
    unittest.main()
