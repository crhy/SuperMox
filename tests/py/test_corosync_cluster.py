#!/usr/bin/env python3
"""Tests for supermox.corosync_cluster (task c06: first node -> real cluster).

No cluster, no root and no /etc/pve here: the paths are module constants and
every test repoints them at a temporary directory, and the commands are run
through an injected runner that answers from a script. What is pinned is the
order and the evidence, because that is what the VM measurements in the
module docstring say matters: pmxcfs only accepts the cluster copy once corosync
is quorate, corosync must parse the config before it is installed, and an
init script's exit code is not proof of a working cluster.
"""
import base64
import os
import re
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "src"))

from supermox import corosync_cluster
from supermox import state as node_state

PHRASE = "abandon " * 11 + "about"


def b64(raw):
    """How membership.json stores a key: base64 text (state._b64)."""
    return base64.b64encode(raw).decode("ascii")


class State:
    """The three attributes the module reads off a NodeState."""

    def __init__(self, members=None, cluster_id=b"\x01" * 16, wg_pub=b"\x01" * 32):
        members = members if members is not None else [
            {"name": "firstnode",
             "wg_pub": b64(wg_pub),
             "overlay_addr": "fd21:3129:3360:3507:d958:db0e:fba9:0"},
        ]
        self.derived = {"cluster_id": cluster_id}
        # identity keeps the raw bytes, membership keeps base64 text: that is
        # how state.py writes both files, and the module has to cope.
        self.identity = {"wg_pub": wg_pub}
        self.membership = members


ADDR = "fd21:3129:3360:3507:d958:db0e:fba9:0"
OTHER_ADDR = "fd21:3129:3360:3507:d958:db0e:fba8:0"


class Runner:
    """Answers commands from a script; records the order they were called in."""

    def __init__(self):
        self.calls = []
        self.quorate_after = 0          # quorate from this many quorumtool calls
        self.ip_addr_after = 0         # wg0 shows the address from this call
        self.corosync_t_rc = 0
        self.pvecm_shows_cluster = True
        self.pgrep_running = True

    def __call__(self, argv):
        self.calls.append(list(argv))
        name = argv[0]
        if name == "corosync-quorumtool":
            self.quorum_seen = getattr(self, "quorum_seen", 0) + 1
            if self.quorum_seen > self.quorate_after:
                return 0, "Quorate:          Yes\n"
            return 0, "Quorate:          No\n"
        if name == "ip":
            self.ip_seen = getattr(self, "ip_seen", 0) + 1
            if self.ip_seen > self.ip_addr_after:
                return 0, "%s dev wg0\n" % ADDR
            return 1, "Error: Device \"wg0\" does not exist.\n"
        if name == "corosync":
            return self.corosync_t_rc, "syntax ok\n"
        if name == "pvecm":
            if self.pvecm_shows_cluster:
                # pvecm reports the cluster pmxcfs holds, not the one we
                # asked for, so the stub reads it back off the config.
                return 0, "Name:             %s\nQuorate: Yes\n" % self.conf_cluster_name()
            return 0, "Name:             someone-elses-cluster\n"
        if name == "corosync-keygen":
            with open(corosync_cluster.AUTHKEY, "wb") as fh:
                fh.write(b"\x00" * 128)
            return 0, ""
        if name == "pgrep":
            return (0, "4242\n") if self.pgrep_running else (1, "")
        return 0, ""

    def conf_cluster_name(self):
        """The cluster_name of the config pmxcfs currently holds."""
        try:
            with open(corosync_cluster.PVE_COROSYNC_CONF) as fh:
                text = fh.read()
        except OSError:
            return "?"
        match = re.search(r"cluster_name:\s*(\S+)", text)
        return match.group(1) if match else "?"


class Paths:
    """Repoint the module's absolute paths at a temporary tree."""

    def __init__(self, test):
        self.tmp = tempfile.TemporaryDirectory()
        test.addCleanup(self.tmp.cleanup)
        root = self.tmp.name
        self.corosync_dir = os.path.join(root, "etc", "corosync")
        self.pve_dir = os.path.join(root, "etc", "pve")
        os.makedirs(self.corosync_dir)
        os.makedirs(self.pve_dir)
        patch = mock.patch
        self._patch(test, patch, "COROSYNC_CONF",
                    os.path.join(self.corosync_dir, "corosync.conf"))
        self._patch(test, patch, "PVE_COROSYNC_CONF",
                    os.path.join(self.pve_dir, "corosync.conf"))
        self._patch(test, patch, "PVE_DIR", self.pve_dir)
        self._patch(test, patch, "AUTHKEY",
                    os.path.join(self.corosync_dir, "authkey"))

    def _patch(self, test, patch, name, value):
        patcher = patch.object(corosync_cluster, name, value)
        patcher.start()
        test.addCleanup(patcher.stop)

    def write(self, name, text, mode=0o644):
        path = os.path.join(self.corosync_dir, name)
        with open(path, "w") as fh:
            fh.write(text)
        os.chmod(path, mode)
        return path


class Base(unittest.TestCase):
    def setUp(self):
        self.paths = Paths(self)
        self.host_conf = self.paths.corosync_dir + "/corosync.conf"
        self.pve_conf = self.paths.pve_dir + "/corosync.conf"


class RenderTests(Base):
    def test_single_node_config_carries_the_measured_facts(self):
        text = corosync_cluster.render_conf(State(), name="supermox",
                                            config_version=1)
        self.assertIn("ip_version: ipv6", text)
        self.assertIn("secauth: on", text)
        self.assertIn("cluster_name: smx-01010101", text)
        self.assertIn("ring0_addr: %s" % ADDR, text)
        self.assertIn("name: supermox", text)
        self.assertNotIn("two_node", text)

    def test_managed_marker_is_the_first_line(self):
        text = corosync_cluster.render_conf(State(), name="n", config_version=1)
        self.assertIn(corosync_cluster.MANAGED_MARKER,
                      text.splitlines()[0])

    def test_two_node_cluster_asks_for_two_node_quorum(self):
        state = State(members=[
            {"name": "firstnode", "wg_pub": b"\x01" * 32, "overlay_addr": ADDR},
            {"name": "second", "wg_pub": b"\x02" * 32, "overlay_addr": OTHER_ADDR},
        ])
        text = corosync_cluster.render_conf(state, name="supermox",
                                            config_version=4)
        self.assertIn("two_node: 1", text)
        self.assertIn("ring0_addr: %s" % OTHER_ADDR, text)
        self.assertIn("nodeid: 2", text)

    def test_three_node_cluster_drops_two_node(self):
        state = State(members=[
            {"name": "firstnode", "wg_pub": b"\x01" * 32, "overlay_addr": ADDR},
            {"name": "second", "wg_pub": b"\x02" * 32, "overlay_addr": OTHER_ADDR},
            {"name": "third", "wg_pub": b"\x03" * 32,
             "overlay_addr": "fd21:3129:3360:3507:d958:db0d:fba8:0"},
        ])
        text = corosync_cluster.render_conf(state, name="supermox",
                                            config_version=4)
        self.assertNotIn("two_node", text)

    def test_member_without_an_address_is_refused(self):
        state = State(members=[{"name": "firstnode", "wg_pub": b"\x01" * 32}])
        with self.assertRaises(corosync_cluster.CorosyncError):
            corosync_cluster.render_conf(state, name="n", config_version=1)

    def test_ipv4_address_is_not_generated(self):
        # The overlay only has link-local IPv6, so an IPv4 form of the
        # nodelist address would be a config corosync exits on.
        text = corosync_cluster.render_conf(State(), name="n", config_version=1)
        self.assertNotIn("ip_version: ipv4", text)
        self.assertIn("ipv6", text)


class NameTests(Base):
    def test_cluster_name_comes_from_the_cluster_id(self):
        self.assertEqual(corosync_cluster.cluster_name(State()), "smx-01010101")

    def test_missing_cluster_id_is_refused(self):
        state = State()
        state.derived = {}
        with self.assertRaises(corosync_cluster.CorosyncError):
            corosync_cluster.cluster_name(state)

    def test_hostname_dots_become_dashes(self):
        self.assertEqual(corosync_cluster.sanitise_node_name("node-1.local"),
                         "node-1-local")

    def test_unusable_hostname_is_refused(self):
        # Everything corosync would reject is reduced to the empty name and
        # refused rather than written: a bad name makes corosync exit 8.
        for bad in ("", "_", "-", "...", "!!!"):
            with self.assertRaises(corosync_cluster.CorosyncError):
                corosync_cluster.sanitise_node_name(bad)

    def test_long_hostname_is_truncated_to_a_valid_name(self):
        name = corosync_cluster.sanitise_node_name("a" * 40)
        self.assertTrue(corosync_cluster.NODE_NAME_RE.match(name))

    def test_this_node_is_found_by_its_own_wg_pub(self):
        state = State(members=[
            {"name": "other", "wg_pub": b"\x02" * 32, "overlay_addr": OTHER_ADDR},
            {"name": "firstnode", "wg_pub": b"\x01" * 32, "overlay_addr": ADDR},
        ])
        self.assertEqual(corosync_cluster.my_entry(state)["name"], "firstnode")
        self.assertEqual(corosync_cluster.overlay_addr(state), ADDR)

    def test_node_not_in_the_membership_list_is_refused(self):
        state = State(members=[{"name": "other", "wg_pub": b"\x02" * 32}])
        with self.assertRaises(corosync_cluster.CorosyncError):
            corosync_cluster.overlay_addr(state)


class ConfigVersionTests(Base):
    def test_missing_file_reads_as_zero(self):
        self.assertEqual(corosync_cluster.read_config_version(self.host_conf), 0)

    def test_version_is_read(self):
        path = self.paths.write("corosync.conf", "totem {\n config_version: 7\n}\n")
        self.assertEqual(corosync_cluster.read_config_version(path), 7)

    def test_managed_marker_only_matches_our_own_file(self):
        ours = self.paths.write("corosync.conf",
                                corosync_cluster.MANAGED_MARKER + " x\n")
        foreign = self.paths.write("foreign.conf",
                                   "cluster_name: theirs\n")
        self.assertTrue(corosync_cluster.is_managed(ours))
        self.assertFalse(corosync_cluster.is_managed(foreign))
        self.assertFalse(corosync_cluster.is_managed(
            self.paths.pve_dir + "/nope"))


class OverlayWaitTests(Base):
    def test_wait_accepts_the_address_once_it_exists(self):
        runner = Runner()
        runner.ip_addr_after = 1  # first probe empty, second carries it
        with mock.patch("time.sleep"):
            ok, note = corosync_cluster.wait_for_overlay(State(), runner,
                                                         timeout=5)
        self.assertTrue(ok, note)
        self.assertIn(ADDR, note)

    def test_wait_gives_up_with_the_address_it_was_missing(self):
        runner = Runner()
        runner.ip_addr_after = 99
        with mock.patch("time.sleep"):
            ok, note = corosync_cluster.wait_for_overlay(State(), runner,
                                                         timeout=0)
        self.assertFalse(ok)
        self.assertIn(ADDR, note)

    def test_wait_without_an_overlay_address_is_not_a_crash(self):
        state = State(members=[{"name": "firstnode", "wg_pub": b"\x01" * 32}])
        ok, note = corosync_cluster.wait_for_overlay(state, Runner())
        self.assertFalse(ok)
        self.assertIn("overlay address", note)


class InitClusterTests(Base):
    """The order pmxcfs forces, pinned as a call sequence."""

    def run_it(self, runner=None, state=None, mounted=True, quorum_wait=0):
        runner = runner or Runner()
        with mock.patch.object(corosync_cluster.os.path, "ismount",
                               return_value=mounted):
            return corosync_cluster.init_cluster(state or State(), runner,
                                                 quorum_wait=quorum_wait)

    def names(self, runner):
        return [call[0] for call in runner.calls]

    def test_happy_path_reports_the_cluster_it_built(self):
        runner = Runner()
        ok, note = self.run_it(runner)
        self.assertTrue(ok, note)
        self.assertIn("smx-01010101", note)
        self.assertIn("quorate", note)

    def test_both_copies_are_written_and_agree(self):
        self.run_it()
        with open(self.host_conf) as fh:
            host = fh.read()
        with open(self.pve_conf) as fh:
            pve = fh.read()
        self.assertEqual(host, pve, "pmxcfs and corosync must read one config")
        self.assertIn("ring0_addr: %s" % ADDR, host)

    def test_the_pve_copy_is_written_only_after_corosync_is_quorate(self):
        # pmxcfs serves its files read-only until corosync is quorate, so
        # writing the cluster copy early is not merely untidy, it fails. The
        # fake pmxcfs here is a plain directory, so the order itself is pinned
        # by wrapping the write and reading the call log at that moment.
        runner = Runner()
        order = []
        real_write = corosync_cluster.write_pve_conf

        def spy(text, run):
            order.append([c[0] for c in run.calls])
            return real_write(text, run)

        with mock.patch.object(corosync_cluster, "write_pve_conf", spy):
            self.run_it(runner)
        self.assertIn("corosync-quorumtool", order[0],
                      "the PVE copy was written before quorum was proven")
        self.assertIn("/etc/init.d/corosync", order[0],
                      "the PVE copy was written before corosync was restarted")

    def test_the_pve_copy_is_written_before_pve_cluster_restarts(self):
        # The restart is what makes pmxcfs re-read the file, so it must come
        # after the write, not instead of it.
        runner = Runner()
        order = []
        real_write = corosync_cluster.write_pve_conf

        def spy(text, run):
            order.append([c[0] for c in run.calls])
            return real_write(text, run)

        with mock.patch.object(corosync_cluster, "write_pve_conf", spy):
            self.run_it(runner)
        self.assertNotIn("/etc/init.d/pve-cluster", order[-1],
                         "pve-cluster was restarted before the config was written")
        self.assertIn("/etc/init.d/pve-cluster", self.names(runner))

    def test_corosync_parses_the_config_before_it_is_installed(self):
        runner = Runner()
        self.run_it(runner)
        corosync_calls = [c for c in runner.calls if c[0] == "corosync"]
        self.assertEqual(corosync_calls[0][:2], ["corosync", "-t"])
        restarts = [c for c in runner.calls
                    if c[:2] == ["/etc/init.d/corosync", "restart"]]
        self.assertTrue(restarts)

    def test_a_config_corosync_rejects_is_not_installed(self):
        runner = Runner()
        runner.corosync_t_rc = 8
        ok, note = self.run_it(runner)
        self.assertFalse(ok)
        self.assertIn("corosync rejects the config", note)
        self.assertFalse(os.path.exists(self.host_conf))
        self.assertFalse(os.path.exists(self.host_conf + ".new"),
                         "the rejected temp file must not be left behind")

    def test_no_quorum_leaves_the_pve_copy_untouched(self):
        runner = Runner()
        runner.quorate_after = 99  # never quorate
        runner.pgrep_running = True
        ok, note = self.run_it(runner)
        self.assertFalse(ok)
        self.assertIn("did not reach quorum", note)
        self.assertIn("PVE was not told about it", note)
        self.assertTrue(os.path.exists(self.host_conf),
                        "the host copy is written: it is the repair path")
        self.assertFalse(os.path.exists(self.pve_conf),
                        "PVE was never told, and must not be half-told")

    def test_a_dead_corosync_says_so_instead_of_blaming_quorum(self):
        runner = Runner()
        runner.quorate_after = 99  # never quorate
        runner.pgrep_running = False
        ok, note = self.run_it(runner)
        self.assertFalse(ok)
        self.assertIn("corosync is not running", note)

    def test_corosync_is_restarted_once_not_twice(self):
        # Measured: restarting corosync a second time because quorumtool has
        # not caught up raced the first start and left no daemon at all.
        runner = Runner()
        self.run_it(runner)
        restarts = [c for c in runner.calls
                    if c[:2] == ["/etc/init.d/corosync", "restart"]]
        self.assertEqual(len(restarts), 1, "one restart, then poll")
        self.assertGreater(len([c for c in runner.calls
                                if c[0] == "corosync-quorumtool"]), 1,
                         "quorum must be polled, not sampled once")

    def test_pvecm_disagreeing_about_the_cluster_is_a_failure(self):
        runner = Runner()
        runner.pvecm_shows_cluster = False
        ok, note = self.run_it(runner)
        self.assertFalse(ok)
        self.assertIn("pvecm status does not show cluster", note)

    def test_rerunning_bumps_the_config_version(self):
        self.run_it()
        first = corosync_cluster.read_config_version(self.host_conf)
        self.run_it()
        second = corosync_cluster.read_config_version(self.host_conf)
        self.assertEqual(second, first + 1)
        self.assertEqual(corosync_cluster.read_config_version(self.pve_conf),
                         second,
                         "pmxcfs must not be left with an older config")

    def test_a_newer_foreign_copy_is_outvoted_not_clobbered(self):
        # pmxcfs refuses to overwrite a newer host file, so our version has
        # to start above both copies that exist.
        self.paths.write("corosync.conf", "config_version: 9\n")
        with open(self.pve_conf, "w") as fh:
            fh.write("config_version: 12\n")
        self.run_it()
        self.assertEqual(corosync_cluster.read_config_version(self.host_conf),
                         13)

    def test_authkey_is_generated_once_and_is_0400(self):
        runner = Runner()
        self.run_it(runner)
        self.assertIn("corosync-keygen", self.names(runner))
        mode = stat.S_IMODE(os.stat(corosync_cluster.AUTHKEY).st_mode)
        self.assertEqual(mode, 0o400)
        runner2 = Runner()
        self.run_it(runner2)
        self.assertNotIn("corosync-keygen", self.names(runner2))

    def test_unmounted_pmxcfs_is_restarted_then_reported(self):
        runner = Runner()
        ok, note = self.run_it(runner, mounted=False)
        self.assertFalse(ok)
        self.assertIn("pmxcfs is not mounted", note)
        self.assertIn("/etc/init.d/pve-cluster", self.names(runner))

    def test_the_wg_address_is_the_one_written(self):
        state = State()
        state.membership[0]["overlay_addr"] = "fd00:1:2:3:4:5:6:7:0"
        self.run_it(state=state)
        with open(self.host_conf) as fh:
            self.assertIn("ring0_addr: fd00:1:2:3:4:5:6:7:0", fh.read())


class RealStateTests(Base):
    """Drive the module with a real NodeState, not the stub above.

    The stub can hide an encoding mismatch between identity.json and
    membership.json; a real state cannot. Measured in the VM: comparing the
    two wg_pub forms raw makes a freshly created node report that it is not
    in its own membership list, and create then leaves corosync unconfigured.
    """

    def setUp(self):
        super().setUp()
        self.etc = tempfile.TemporaryDirectory()
        self.addCleanup(self.etc.cleanup)
        self.st = node_state.NodeState(base=self.etc.name)
        self.st.create_cluster(PHRASE, "smx-test", [])

    def test_this_node_is_found_in_a_state_create_wrote(self):
        entry = corosync_cluster.my_entry(self.st)
        self.assertEqual(entry["name"], "smx-test")
        self.assertEqual(corosync_cluster.overlay_addr(self.st),
                        entry["overlay_addr"])

    def test_the_local_node_is_named_by_its_hostname(self):
        with mock.patch.object(corosync_cluster.socket, "gethostname",
                              lambda: "supermox"):
            text = corosync_cluster.render_conf(self.st, name="supermox",
                                                config_version=1)
        self.assertIn("name: supermox", text)
        self.assertNotIn("name: smx-test", text)
        self.assertIn("ring0_addr: %s"
                      % self.st.membership[0]["overlay_addr"], text)

    def test_init_cluster_works_on_a_state_create_wrote(self):
        runner = Runner()
        with mock.patch.object(corosync_cluster.os.path, "ismount",
                              return_value=True), \
             mock.patch.object(corosync_cluster.socket, "gethostname",
                              lambda: "supermox"):
            ok, note = corosync_cluster.init_cluster(self.st, runner)
        self.assertTrue(ok, note)
        with open(self.host_conf) as fh:
            host = fh.read()
        with open(self.pve_conf) as fh:
            pve = fh.read()
        self.assertEqual(host, pve)
        self.assertIn("ip_version: ipv6", host)
        self.assertIn("ring0_addr: %s"
                      % self.st.membership[0]["overlay_addr"], host)

    def test_the_overlay_address_create_recorded_is_an_ipv6_ula(self):
        # create records it, the nodelist must carry the same string, and
        # corosync has to be told to read IPv6 or the address is nonsense.
        addr = corosync_cluster.overlay_addr(self.st)
        self.assertRegex(addr, r"^fd[0-9a-f]+(:[0-9a-f]+){6}:0$")


class QuorumEvidenceTests(Base):
    def test_quorate_yes_is_required_not_the_exit_code(self):
        self.assertTrue(corosync_cluster.quorate(
            lambda argv: (0, "Quorate:          Yes\n")))
        self.assertFalse(corosync_cluster.quorate(
            lambda argv: (0, "Quorate:          No\n")))
        self.assertFalse(corosync_cluster.quorate(
            lambda argv: (1, "Quorate:          Yes\n")))


if __name__ == "__main__":
    unittest.main()
