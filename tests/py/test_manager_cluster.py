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
from supermox_manager.ops import terminal


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
        with open(os.path.join(root, "src", "supermox_manager",
                                  "pages", "__init__.py")) as fh:
            source = fh.read()
        self.assertIn('"cluster"', source)
        py_compile.compile(os.path.join(root, "src", "supermox_manager",
                                        "pages", "cluster.py"), doraise=True)


class ClusterActions(unittest.TestCase):
    """c08: the commands the cluster page types into a node shell, and its answers.

    The page itself is not imported here (GTK), so the command strings, the
    JSON parsing and the state that shows or hides a button are pinned at the
    ops level, which is where the page gets all three from.
    """

    def test_the_read_commands_ask_for_json(self):
        self.assertEqual(cluster.members_command(),
                         "supermox-join members --json")
        self.assertEqual(cluster.pending_command(),
                         "supermox-join pending --json")

    def test_create_names_this_node_and_its_join_endpoint(self):
        self.assertEqual(
            cluster.create_command("supermox", "10.0.2.15"),
            "supermox-join create --name supermox --endpoint 10.0.2.15:8743")
        self.assertEqual(
            cluster.create_command("supermox", "10.0.2.15:9000"),
            "supermox-join create --name supermox --endpoint 10.0.2.15:9000")

    def test_create_refuses_arguments_that_are_not_arguments(self):
        for bad in (("supermox; rm -rf /", "10.0.2.15"),
                    ("supermox", "10.0.2.15; id"),
                    ("supermox", ""),
                    ("", "10.0.2.15")):
            with self.assertRaises(ValueError):
                cluster.create_command(*bad)

    def test_invite_ttl_is_bounded(self):
        self.assertEqual(cluster.invite_command(), "supermox-join invite --ttl 900")
        self.assertEqual(cluster.invite_command(60), "supermox-join invite --ttl 60")
        for bad in (0, -1, 86401):
            with self.assertRaises(ValueError):
                cluster.invite_command(bad)

    def test_decide_quotes_a_base64_request_id(self):
        """A state-file id is base64: it can hold + / and =, so it is quoted."""
        self.assertEqual(cluster.decide_command("approve", "a+b/c==" * 2),
                         "supermox-join approve 'a+b/c==a+b/c=='")
        self.assertEqual(cluster.decide_command("deny", "aAbBcCdDeEfF00"),
                         "supermox-join deny 'aAbBcCdDeEfF00'")
        for bad in ("a+b/c", "x" * 40, "id; id", "", "approve; rm -rf /"):
            with self.assertRaises(ValueError):
                cluster.decide_command("approve", bad)
        with self.assertRaises(ValueError):
            cluster.decide_command("delete", "aAbBcCdDeEfF00")

    def test_the_changing_commands_are_one_line_each(self):
        self.assertEqual(cluster.core_command(), "supermox-join core")
        self.assertEqual(cluster.cluster_init_command(),
                         "supermox-join cluster-init")

    def test_the_managed_probe_asks_the_node_for_its_own_marker(self):
        """The Manager must not repeat supermox's marker string."""
        line = cluster.managed_command()
        self.assertIn("is_managed", line)
        self.assertIn("PVE_COROSYNC_CONF", line)
        for marker in ("# SuperMox cluster", "managed by supermox-join"):
            self.assertNotIn(marker, line)

    def test_parse_members_reads_the_documented_keys(self):
        text = ('[{"name": "node-a", "role": "core", "overlay_addr": "fd00:1", '
                '"arch": "amd64", "caps": ["kvm"], "core": true}]')
        rows = cluster.parse_members(text)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0], {"name": "node-a", "role": "core",
                                   "overlay_addr": "fd00:1", "arch": "amd64",
                                   "caps": ["kvm"], "core": True})

    def test_parse_pending_reads_the_documented_keys(self):
        text = '[{"id": "aAbBcCdDeEfF00", "name": "node-b", "arch": "arm64", "age_s": 90}]'
        rows = cluster.parse_pending(text)
        self.assertEqual(rows, [{"id": "aAbBcCdDeEfF00", "name": "node-b",
                                 "arch": "arm64", "age_s": 90}])

    def test_garbage_is_not_rows(self):
        """Every unpromising answer comes back None, so the page can show it.

        A truncated array is what a session that died mid-command leaves behind;
        prose is what a command that failed prints instead of JSON.
        """
        for text in ("", "not json", "[{\"name\":",
                     '{"name": "node-a"}', "null", "[1, 2]",
                     "supermox-join: no cluster here", None):
            self.assertIsNone(cluster.parse_members(text), text)
            self.assertIsNone(cluster.parse_pending(text), text)

    def test_an_empty_array_is_no_rows_and_no_error(self):
        self.assertEqual(cluster.parse_members("[]"), [])
        self.assertEqual(cluster.parse_pending("[]"), [])

    def test_a_page_with_no_members_offers_only_create(self):
        actions = cluster.page_actions([], True)
        self.assertEqual(actions, {"create"})

    def test_a_page_with_members_offers_invite_and_core_but_not_create(self):
        self.assertEqual(cluster.page_actions([{"name": "node-a"}], True),
                         {"invite"})
        self.assertNotIn("create", cluster.page_actions([{"name": "node-a"}], True))

    def test_upgrade_appears_only_when_the_nodelist_is_not_ours(self):
        members = [{"name": "node-a", "core": True}]
        self.assertIn("upgrade", cluster.page_actions(members, False))
        self.assertNotIn("upgrade", cluster.page_actions(members, True))

    def test_make_core_is_offered_only_for_a_member_not_in_the_nodelist(self):
        self.assertTrue(cluster.core_allowed({"name": "node-b", "core": False}))
        self.assertFalse(cluster.core_allowed({"name": "node-a", "core": True}))
        self.assertFalse(cluster.core_allowed(None))

    def test_run_shell_hands_one_command_to_the_terminal(self):
        """The page runs its commands through ops.terminal, one at a time."""
        calls = []
        real = terminal.run_command
        def fake(client, node, command, timeout=None):
            calls.append((client, node, command, timeout))
            return "[]"
        terminal.run_command = fake
        try:
            self.assertEqual(cluster.run_shell("CLIENT", "supermox",
                                               "supermox-join members --json",
                                               timeout=5),
                             "[]")
        finally:
            terminal.run_command = real
        self.assertEqual(calls, [("CLIENT", "supermox",
                                  "supermox-join members --json", 5)])

    def test_age_text_is_the_table_text(self):
        self.assertEqual(cluster.age_text(30), "30 s")
        self.assertEqual(cluster.age_text(90), "1 min")
        self.assertEqual(cluster.age_text(600), "10 min")
        self.assertEqual(cluster.age_text(7200), "2 h")
        self.assertEqual(cluster.age_text(None), "")


class TerminalMarkers(unittest.TestCase):
    """The marker pair ops.terminal uses to find one command's output."""

    def test_wrap_command_marks_the_output_on_both_sides(self):
        line = terminal.wrap_command("supermox-join members --json")
        self.assertEqual(line, 'echo SMXJSON-""BEGIN; supermox-join members '
                               '--json; echo SMXJSON-""END')

    def test_the_echo_of_the_typed_line_is_not_a_region(self):
        """The shell echoes the line back before it runs it.

        A plain ``echo SMXJSON-BEGIN; ...; echo SMXJSON-END`` would put both
        markers on the echoed line, and the text between them -- the command
        itself -- would be read as the answer. hidden() spells the markers with
        empty quotes, so the echo holds neither of them.
        """
        line = terminal.wrap_command("supermox-join pending --json")
        self.assertIsNone(terminal.command_region(line.encode()))

    def test_the_region_survives_the_echo_of_the_typed_line(self):
        """The real markers appear once, around the answer, echo included."""
        line = terminal.wrap_command("supermox-join pending --json")
        stream = ("$ " + line + "\r\n"
                  "SMXJSON-BEGIN\r\n[]\r\nSMXJSON-END\r\n$ ")
        self.assertEqual(terminal.command_region(stream.encode()), "[]")

    def test_a_split_echo_marker_still_leaves_one_region(self):
        stream = ("$ echo SMXJSON-\r\n\"\"BEGIN; id; echo SMXJSON-\r\n"
                  "\"\"END\r\nSMXJSON-BEGIN\r\nuid=0(root)\r\nSMXJSON-END\r\n")
        self.assertEqual(terminal.command_region(stream.encode()),
                         "uid=0(root)")

    def test_no_region_while_the_command_is_still_running(self):
        self.assertIsNone(terminal.command_region(b"SMXJSON-BEGIN\r\n["))
        self.assertIsNone(terminal.command_region(b"nothing yet"))

    def test_ansi_and_the_prompt_do_not_reach_the_region(self):
        stream = (b"\x1b[0m\x1b[KSMXJSON-BEGIN\r\n"
                  b"\x1b[32mok\x1b[0m\r\nSMXJSON-END\r\n")
        self.assertEqual(terminal.command_region(stream), "ok")


if __name__ == "__main__":
    unittest.main()
