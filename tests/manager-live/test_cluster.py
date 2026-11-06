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
import re
import sys
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))

from supermox_manager import api
from supermox_manager.ops import cluster
from supermox_manager.ops import terminal

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASS = os.environ.get("SUPERMOX_LIVE_PASS", "")

DESCRIPTION = "t78 live probe"


def run_command(client, node, command, seconds=30):
    """One command in a node shell, and only its own output.

    Used by the Members, Join requests and Add a node tabs: supermox-join has
    no API, so the page runs the command and quotes what it printed.
    """
    return terminal.run_command(client, node, command, timeout=seconds)


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


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class ClusterCommandsLive(unittest.TestCase):
    """The supermox-join commands the cluster page runs in a node shell.

    supermox-join has no API of its own, so these calls are the page's only
    route to the cluster's members, its waiting join requests and its actions.
    Every assertion is about the text the page would show.
    """

    @classmethod
    def setUpClass(cls):
        if not LIVE_URL:
            raise unittest.SkipTest("SUPERMOX_LIVE_URL not set")
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASS)
        cls.node = cls.client.request("GET", "/nodes")[0]["node"]

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "client", None):
            try:
                cls.client.logout()
            except Exception:  # noqa: BLE001 - best effort
                pass

    def test_members_json_carries_the_documented_keys(self):
        text = run_command(self.client, self.node, cluster.members_command())
        rows = cluster.parse_members(text)
        self.assertIsNotNone(rows, "members --json did not parse: %r" % text[:200])
        self.assertTrue(rows, "this node reports no members of its own cluster")
        for row in rows:
            for key in ("name", "role", "overlay_addr", "arch", "caps", "core"):
                self.assertIn(key, row)
            self.assertIsInstance(row["core"], bool)
            self.assertIsInstance(row["caps"], list)
        # The node running the command is a member, and its name is the one
        # /cluster/status calls local.
        names = [row["name"] for row in rows]
        local = next((row.get("name") for row in cluster.node_rows(
            cluster.status(self.client)) if row.get("local")), None)
        self.assertIn(local, names)

    def test_pending_json_is_a_list_even_with_nothing_waiting(self):
        text = run_command(self.client, self.node, cluster.pending_command())
        rows = cluster.parse_pending(text)
        self.assertIsNotNone(rows, "pending --json did not parse: %r" % text[:200])
        self.assertIsInstance(rows, list)
        for row in rows:
            for key in ("id", "name", "arch", "age_s"):
                self.assertIn(key, row)
            self.assertGreaterEqual(row["age_s"], 0)

    def test_run_command_keeps_the_command_and_prompt_out(self):
        # The page shows this text as the whole answer, so neither the shell's
        # echo of the command nor its prompt may be in it.
        text = run_command(self.client, self.node,
                           "printf 'one\\n'; printf 'two\\n'")
        self.assertEqual(text.strip(), "one\ntwo")

    def test_a_failing_command_shows_its_own_error(self):
        # Approve and Deny show this: the command's error, not a Manager message.
        text = run_command(self.client, self.node,
                           cluster.decide_command("approve", "AAAAAAAAAAAA="))
        self.assertTrue(text.strip(), "the failure printed nothing")
        self.assertIsNone(cluster.parse_pending(text),
                          "a failing approve returned JSON")

    def test_invite_prints_a_single_use_invite(self):
        text = run_command(self.client, self.node, cluster.invite_command())
        self.assertIn("supermox://join?", text)
        # The invite never carries the phrase, so neither does this output.
        self.assertNotIn("--words", text)

    def test_cluster_init_is_idempotent(self):
        # corosync bumps config_version on every write, so idempotence is
        # "the same cluster, the same node, still quorate", not byte equality.
        # Just after a boot pmxcfs can still be local-only for a moment and
        # the first write then lands on a read-only /etc/pve; give it that.
        first = ""
        for _ in range(5):
            first = run_command(self.client, self.node,
                                cluster.cluster_init_command())
            if "corosync cluster:" in first:
                break
            time.sleep(2)
        second = run_command(self.client, self.node,
                             cluster.cluster_init_command())
        self.assertIn("corosync cluster:", first)
        self.assertIn("corosync cluster:", second)
        without_version = lambda text: re.sub(r"config_version \d+", "", text)
        self.assertEqual(without_version(first), without_version(second))

    def test_the_managed_probe_answers_yes_or_no(self):
        text = run_command(self.client, self.node, cluster.managed_command())
        self.assertTrue(("yes" in text) ^ ("no" in text),
                        "the probe printed neither marker: %r" % text[:200])

    def test_core_command_never_tracebacks(self):
        # `core` only promotes a member that joined and was approved. On a node
        # whose cluster is already corosync-managed it says so and changes
        # nothing, which is the answer the page would show.
        text = run_command(self.client, self.node, cluster.core_command())
        self.assertTrue(text.strip())
        self.assertNotIn("Traceback", text)


if __name__ == "__main__":
    unittest.main()
