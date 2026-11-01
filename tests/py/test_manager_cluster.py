"""Unit tests for the cluster page's calls: exact paths, params and limits.

Endpoints, enums and error strings come from `pvesh usage` and live probes on
the running node (recorded in .strata/notes-t78-manager-cluster.md). Two
measured facts drive the shape of this code: /cluster/log and /cluster/tasks
accept no limit parameter, and a hash-valued datacenter option travels as a
plain string while it comes back from GET as a dict.
"""

import inspect
import os
import py_compile
import time
import unittest

from supermox_manager import api
from supermox_manager.ops import cluster


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "ok"


STATUS_ROWS = [
    {"id": "cluster", "name": "supermox", "nodes": 2, "quorate": 1,
     "type": "cluster", "version": 1},
    {"id": "node/supermox", "ip": "10.0.2.15", "level": "", "local": 1,
     "name": "supermox", "nodeid": 1, "online": 1, "type": "node"},
    {"id": "node/orbit", "ip": "10.0.2.16", "level": "", "local": 0,
     "name": "orbit", "nodeid": 2, "online": 1, "type": "node"},
]


class ClusterOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_status_and_config_nodes_are_two_answers(self):
        cluster.status(self.client)
        cluster.nodes(self.client)
        self.assertEqual(self.client.calls,
                         [("GET", "/cluster/status", None),
                          ("GET", "/cluster/config/nodes", None)])

    def test_rows_split_by_type(self):
        head = cluster.cluster_row(STATUS_ROWS)
        self.assertEqual((head["name"], head["nodes"], head["quorate"]),
                         ("supermox", 2, 1))
        self.assertEqual([row["name"] for row in cluster.node_rows(STATUS_ROWS)],
                         ["supermox", "orbit"])
        # A node that is not in a cluster answers without a cluster row.
        self.assertIsNone(cluster.cluster_row(STATUS_ROWS[1:]))
        self.assertIsNone(cluster.cluster_row(None))

    def test_log_is_sliced_after_fetching_because_limit_is_refused(self):
        rows = [{"id": "{}:supermox".format(n)} for n in range(60, 0, -1)]
        recorder = self.client
        recorder.request = lambda method, path, params=None: (
            recorder.calls.append((method, path, params)) or rows)
        kept = cluster.log(self.client)
        self.assertEqual(self.client.calls, [("GET", "/cluster/log", None)])
        self.assertEqual(len(kept), cluster.MAX_LOG)
        self.assertEqual(kept[0]["id"], "60:supermox")
        self.assertEqual(cluster.log(self.client, max=2), rows[:2])
        self.assertEqual(cluster.log(self.client, max=None), rows)

    def test_tasks_page_and_cluster_page_use_the_same_call(self):
        cluster.cluster_tasks(self.client)
        self.assertEqual(self.client.calls, [("GET", "/cluster/tasks", None)])
        # api.Client.tasks() feeds the Tasks page; it must be the same call.
        self.assertIn('request("GET", "/cluster/tasks")',
                      inspect.getsource(api.Client.tasks))

    def test_options_read(self):
        cluster.options(self.client)
        self.assertEqual(self.client.calls, [("GET", "/cluster/options", None)])

    def test_set_options_sends_server_names_and_plain_hash_values(self):
        cluster.set_options(self.client, description="lab", console="xtermjs",
                            migration="secure")
        self.assertEqual(self.client.calls,
                         [("PUT", "/cluster/options",
                           {"description": "lab", "console": "xtermjs",
                            "migration": "secure"})])

    def test_a_dict_read_back_from_get_round_trips_to_a_plain_string(self):
        cluster.set_options(self.client, migration={"type": "insecure"})
        self.assertEqual(self.client.calls[-1][2], {"migration": "insecure"})

    def test_delete_names_options_to_unset(self):
        cluster.set_options(self.client, delete="console,keyboard")
        self.assertEqual(self.client.calls[-1][2], {"delete": "console,keyboard"})
        cluster.set_options(self.client, delete=["console", "keyboard"])
        self.assertEqual(self.client.calls[-1][2], {"delete": "console,keyboard"})

    def test_option_names_the_server_does_not_know_are_refused(self):
        for bad in ({"colour": "red"}, {"console": "putty"},
                    {"migration": "maybe"}, {"language": "klingon"},
                    {"delete": "console; rm -rf /"}):
            with self.assertRaises(ValueError):
                cluster.option_params(**bad)

    def test_nothing_to_change_is_refused_before_the_request(self):
        with self.assertRaises(ValueError):
            cluster.set_options(self.client, description="")
        with self.assertRaises(ValueError):
            cluster.set_options(self.client)

    def test_option_text_reads_a_form_default_out_of_either_shape(self):
        record = {"description": "t78 probe\n", "migration": {"type": "secure"},
                  "console": ""}
        self.assertEqual(cluster.option_text("description", record), "t78 probe")
        self.assertEqual(cluster.option_text("migration", record), "secure")
        self.assertEqual(cluster.option_text("console", record), "")
        self.assertEqual(cluster.option_text("keyboard", record), "")
        self.assertEqual(cluster.option_text("keyboard", None), "")

    def test_log_time_turns_the_epoch_the_node_sends_into_local_text(self):
        row = {"time": int(time.time())}
        self.assertRegex(cluster.log_time(row), r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$")
        self.assertEqual(cluster.log_time({"time": ""}), "")
        self.assertEqual(cluster.log_time({}), "")

    def test_pri_is_a_syslog_number(self):
        self.assertEqual(cluster.LEVEL_NAMES[6], "info")
        self.assertEqual(cluster.LEVEL_NAMES[3], "err")

    def test_the_join_config_is_never_read(self):
        # /cluster/config/join carries pve_fp and config_digest: the Manager
        # must not fetch it, so no function body may name it.
        for name in dir(cluster):
            function = getattr(cluster, name)
            if not inspect.isfunction(function):
                continue
            source = inspect.getsource(function)
            self.assertNotIn("config/join", source, name)
            self.assertNotIn("pve_fp", source, name)

    def test_join_command_keeps_arguments_from_becoming_a_shell_line(self):
        words = " ".join(["abandon"] * 11 + ["ability"])
        line = cluster.join_command("orbit", "10.0.0.5:8743", words)
        self.assertEqual(
            line,
            "supermox-join join --name orbit --endpoint 10.0.0.5:8743 "
            "--words " + words)
        for bad in (("orbit; rm -rf /", "10.0.0.5", None),
                    ("orbit", "10.0.0.5; id", None),
                    ("orbit", "10.0.0.5", "abandon ability"),
                    ("", "10.0.0.5", None),
                    ("orbit", "", None)):
            with self.assertRaises(ValueError):
                cluster.join_command(*bad)


class ClusterPage(unittest.TestCase):
    """The page is registered and compiles.

    The page module itself is not imported here: importing GTK in this process
    would break test_manager_pin.py, so the rendering checks stay in the GUI
    smoke test (tests/gui-manager.py), which walks every registered page.
    """

    def test_the_page_is_registered(self):
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        root = os.path.dirname(here)
        source = open(os.path.join(root, "src", "supermox_manager",
                                  "pages", "__init__.py")).read()
        self.assertIn('"cluster"', source)
        py_compile.compile(os.path.join(root, "src", "supermox_manager",
                                        "pages", "cluster.py"), doraise=True)


if __name__ == "__main__":
    unittest.main()
