#!/usr/bin/env python3
"""CLI-level tests for bin/supermox-join.

The script has no .py suffix, so it is loaded through SourceFileLoader rather
than imported; its `if __name__ == "__main__"` guard keeps main() from running
at load time. Everything the CLI touches on disk is redirected by the
documented environment overrides (SUPERMOX_ETC, SUPERMOX_WG_DIR, SUPERMOX_WG_INITD),
so no test here needs root or a real /etc.

f10d-3: `create` used to stop at the state files. A cluster of one member is
still a cluster, so create must write this node's wg0.conf (0600) and ask
init.d/supermox-wg to bring the overlay up, exactly like `join` and `conf`
already do (f11 made join do it).
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
from supermox import corosync_cluster  # noqa: E402
from supermox import identity as identity_mod  # noqa: E402
from supermox import state as node_state  # noqa: E402

PHRASE = "abandon " * 11 + "about"


def _b64t(data: bytes) -> str:
    """base64 of raw key bytes, the form the state files store."""
    import base64
    return base64.b64encode(data).decode("ascii")


def _load_cli():
    name = "supermox_join_cli"
    path = str(ROOT / "bin" / "supermox-join")
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


cli = _load_cli()


class CreateOverlayTest(unittest.TestCase):
    """`supermox-join create` with the state dir, wg dir and init script stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.tmp.name
        self.etc = os.path.join(root, "etc", "supermox")
        self.wg_dir = os.path.join(root, "etc", "wireguard")
        self.initd = os.path.join(root, "init.d", "supermox-wg")
        self.calls = os.path.join(root, "overlay-calls")
        os.makedirs(os.path.dirname(self.initd))
        # Stub service script: records the action it was asked for, plus the
        # config directory the caller passed in its environment, then succeeds.
        stub_src = ("#!/bin/sh\n"
                    "printf '%%s %%s\\n' \"$1\" \"${SUPERMOX_WG_DIR:-none}\" "
                    ">> '%s'\n"
                    "exit 0\n") % self.calls
        with open(self.initd, "w") as fh:
            fh.write(stub_src)
        os.chmod(self.initd, 0o755)
        saved = dict(os.environ)
        self.addCleanup(self._restore_env, saved)
        for var in ("SUPERMOX_ETC", "SUPERMOX_WG_DIR", "SUPERMOX_WG_INITD"):
            os.environ.pop(var, None)
        os.environ["SUPERMOX_ETC"] = self.etc
        os.environ["SUPERMOX_WG_DIR"] = self.wg_dir
        os.environ["SUPERMOX_WG_INITD"] = self.initd
        # c06: create also drives the corosync cluster step (src/supermox/
        # corosync_cluster.py), which needs a mounted pmxcfs and a live corosync.
        # These tests are about the overlay, so the step is stubbed; the real
        # module has its own tests, and test_corosync_failure below pins that a
        # failed step makes create fail.
        self.corosync_ok = True
        self.corosync_calls = []
        self._real_corosync = cli.corosync_cluster
        self.addCleanup(self._restore_corosync)
        cli.corosync_cluster = self._make_corosync_stub()

    def _restore_corosync(self):
        cli.corosync_cluster = self._real_corosync

    def _make_corosync_stub(self):
        """Stands in for corosync_cluster: needs a mounted pmxcfs and a live
        corosync, which these overlay-focused tests do not have."""
        test = self

        class Stub:
            def name_ok(self, name):
                # Same rule as the real module: letters, digits and internal
                # dashes, at most 30 characters.
                import re
                return bool(name) and len(name) <= 30 and bool(
                    re.match(r"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\Z", name))

            def wait_for_overlay(self, st):
                test.corosync_calls.append("wait")
                return True, "overlay carries fd00:1:2:3:4:5:6:7:0"

            def init_cluster(self, st):
                test.corosync_calls.append("init")
                return test.corosync_ok, "cluster stub quorate"

        return Stub()

    def _restore_env(self, saved):
        for var in ("SUPERMOX_ETC", "SUPERMOX_WG_DIR", "SUPERMOX_WG_INITD"):
            if var in saved:
                os.environ[var] = saved[var]
            else:
                os.environ.pop(var, None)

    def _create(self, *argv):
        buf = io.StringIO()
        err = io.StringIO()
        self.corosync_calls = []
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, buf.getvalue() + err.getvalue()

    def test_create_writes_conf_and_starts_overlay(self):
        rc, out = self._create("create", "--name", "firstnode")
        self.assertEqual(rc, 0, out)

        conf = os.path.join(self.wg_dir, "wg0.conf")
        self.assertTrue(os.path.exists(conf), "create wrote no wg0.conf")
        mode = stat.S_IMODE(os.stat(conf).st_mode)
        self.assertEqual(mode, 0o600, "wg0.conf must be 0600 (holds the key)")
        with open(conf) as fh:
            text = fh.read()
        self.assertIn("[Interface]", text)
        self.assertIn("ListenPort = 51820", text)

        # The overlay service must have been asked to start, and told which
        # directory this node's config lives in.
        self.assertTrue(os.path.exists(self.calls),
                        "create never called the overlay service script")
        with open(self.calls) as fh:
            lines = fh.read().splitlines()
        self.assertEqual(lines, ["start %s" % self.wg_dir])

        # And the user is told both, while the 12 words stay on stdout.
        self.assertIn("wrote %s" % conf, out)
        self.assertIn("overlay up:", out)
        self.assertIn("Cluster created.", out)

    def test_a_name_corosync_would_refuse_fails_before_anything_is_written(self):
        # c06: `create --name` is checked up front. A trailing dash is a name
        # corosync itself rejects; generating a keypair, an overlay and state
        # files for a cluster that cannot exist is worse than saying no early.
        for bad in ("bad-name-", "a" * 31, "two words"):
            rc, out = self._create("create", "--name", bad)
            self.assertEqual(rc, 1, bad)
            self.assertIn("not a valid cluster name", out)
        # A leading dash needs the `=` form, or argparse reads it as an option.
        rc, out = self._create("create", "--name=-lead")
        self.assertEqual(rc, 1)
        self.assertIn("not a valid cluster name", out)
        self.assertEqual(os.listdir(self.etc), [],
                         "a rejected name left files behind")
        self.assertEqual(self.corosync_calls, [])

    def test_create_survives_a_broken_overlay_script(self):
        # The overlay is reported, never fatal: the cluster already exists by
        # then, so a tunnel that did not come up must not make create fail.
        os.chmod(self.initd, 0o644)  # not executable -> OSError in the caller
        rc, out = self._create("create", "--name", "firstnode")
        self.assertEqual(rc, 0)
        self.assertIn("overlay not up:", out)
        self.assertTrue(os.path.exists(os.path.join(self.wg_dir, "wg0.conf")))

    def test_conf_still_writes_and_starts(self):
        # The sibling path create now mirrors; pinned so the two cannot drift.
        self._create("create", "--name", "firstnode")
        os.remove(self.calls)
        rc, out = self._create("conf")
        self.assertEqual(rc, 0, out)
        with open(self.calls) as fh:
            lines = fh.read().splitlines()
        self.assertEqual(lines, ["start %s" % self.wg_dir])
        self.assertIn("wrote %s" % os.path.join(self.wg_dir, "wg0.conf"), out)

    def test_create_fails_when_the_corosync_step_fails(self):
        # The cluster, keys and overlay exist, but corosync and pmxcfs were
        # never told about the node: that is not a working cluster, so create
        # must say so instead of reporting success.
        self.corosync_ok = False
        rc, out = self._create("create", "--name", "firstnode")
        self.assertEqual(rc, 1)
        self.assertIn("corosync cluster: FAILED", out)
        self.assertIn("cluster-init", out)

    def test_create_tells_the_user_the_cluster_is_quorate(self):
        rc, out = self._create("create", "--name", "firstnode")
        self.assertEqual(rc, 0, out)
        self.assertIn("corosync cluster: cluster stub quorate", out)


class CoreCommandTest(unittest.TestCase):
    """`supermox-join core`: this node becomes a corosync core member.

    The CORE_REQ -> CORE_ACK round trip is test_joind's job, so the answer
    is handed over by a stub here. What these tests pin is what the CLI does
    with it: which files it writes with which modes, what it refuses before
    writing anything, the arguments it gives upstream's finish_join, and the
    rollback when that call fails.
    """

    CONF = "global\n\tnum_nodes = 2\n\nnode\n\n\thostname = node-a\n"
    AUTHKEY = bytes(range(64))

    def setUp(self):
        self.root = os.path.join(str(ROOT), "build", "test-core-cli-%d"
                                % os.getpid())
        shutil.rmtree(self.root, ignore_errors=True)
        self.etc = os.path.join(self.root, "etc", "supermox")
        self.corosync = os.path.join(self.root, "etc", "corosync")
        self.run_dir = os.path.join(self.root, "run", "supermox")
        self.stub = os.path.join(self.root, "stub")
        self.perl_calls = os.path.join(self.root, "perl-calls")
        for d in (self.corosync, self.run_dir, self.stub):
            os.makedirs(d)
        saved = dict(os.environ)
        self.addCleanup(self._restore_env, saved)
        os.environ["SUPERMOX_ETC"] = self.etc
        os.environ["SUPERMOX_COROSYNC_DIR"] = self.corosync
        os.environ["SUPERMOX_RUN_DIR"] = self.run_dir
        os.environ["PATH"] = self.stub + os.pathsep + saved.get("PATH", "")
        # The daemon round trip, stubbed: the endpoints and names this node
        # asked with are what the CLI test can observe.
        self.asks = []
        self.ack = None
        self.perl_rc = 0
        self._real_core_join = cli.joind.core_join
        self.addCleanup(self._restore_core_join)
        cli.joind.core_join = self._fake_core_join
        # A two-member cluster whose corosync step has already run: this node
        # is node-a, node-b is the member whose daemon will be asked.
        st = node_state.NodeState(self.etc)
        st.create_cluster(PHRASE, "node-a", ["10.0.0.1:8743"], "amd64",
                          ["kvm"], "10.0.0.1:8744")
        other = identity_mod.new_identity()
        st.add_member({
            "name": "node-b",
            "ed_pub": _b64t(other["ed_pub"]),
            "wg_pub": _b64t(other["wg_pub"]),
            "overlay_addr": "fd00:5:6:7:8:9:a:0",
            "role": "edge",
        })
        self.cluster_name = corosync_cluster.cluster_name(st)

    def _restore_env(self, saved):
        for var in ("SUPERMOX_ETC", "SUPERMOX_COROSYNC_DIR", "SUPERMOX_RUN_DIR",
                    "PATH"):
            if var in saved:
                os.environ[var] = saved[var]
            else:
                os.environ.pop(var, None)

    def _restore_core_join(self):
        cli.joind.core_join = self._real_core_join

    async def _fake_core_join(self, ep, ident, name, wg_pub):
        """One member answering with this cluster's config and key."""
        self.asks.append((ep, name, wg_pub))
        if self.ack is None:
            raise cli.joind.JoinError("no member answered")
        return self.ack

    def _want_ack(self):
        self.ack = {"corosync_conf": self.CONF,
                    "corosync_authkey": self.AUTHKEY,
                    "cluster_name": self.cluster_name}

    def _stub(self, name, body):
        """Put one stub command first on PATH for this test."""
        path = os.path.join(self.stub, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n%s\n" % body)
        os.chmod(path, 0o755)

    def _stub_pvesh(self, payload="[]", rc=0):
        self._stub("pvesh", "printf '%%s' '%s'\nexit %d" % (payload, rc))

    def _stub_perl(self, rc=0):
        """Stub perl: records each call's arguments, then a -- separator."""
        self._stub("perl", "printf '%%s\\n' \"$@\" >> '%s'\n"
                   "printf -- '--\\n' >> '%s'\nexit %d"
                   % (self.perl_calls, self.perl_calls, rc))

    def _core(self, *argv):
        buf = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, buf.getvalue() + err.getvalue()

    def _perl_argv(self):
        """The arguments of each perl call, in order, -- separated."""
        if not os.path.exists(self.perl_calls):
            return []
        with open(self.perl_calls) as fh:
            lines = fh.read().split("\n")
        calls, current = [], []
        for line in lines:
            if line == "--":
                if current:
                    calls.append(current)
                current = []
            else:
                current.append(line)
        return calls

    def test_core_writes_key_and_config_then_calls_finish_join(self):
        """authkey 0400, corosync.conf 0644, then upstream's finish_join.

        The old single-node config is moved aside rather than overwritten:
        a node that fails half way through becoming a core member has to be
        able to boot the cluster it had before.
        """
        self._stub_pvesh()
        self._stub_perl()
        old = os.path.join(self.corosync, "corosync.conf")
        with open(old, "w") as fh:
            fh.write("num_nodes = 1\n")
        self._want_ack()
        rc, out = self._core("core")
        self.assertEqual(rc, 0, out)
        self.assertIn("core member of cluster %s" % self.cluster_name, out)
        auth = os.path.join(self.corosync, "authkey")
        with open(auth, "rb") as fh:
            self.assertEqual(fh.read(), self.AUTHKEY)
        self.assertEqual(stat.S_IMODE(os.stat(auth).st_mode), 0o400)
        with open(old) as fh:
            self.assertEqual(fh.read(), self.CONF)
        self.assertEqual(stat.S_IMODE(os.stat(old).st_mode), 0o644)
        with open(os.path.join(self.corosync,
                              "corosync.conf.supermox-single")) as fh:
            self.assertEqual(fh.read(), "num_nodes = 1\n")
        calls = self._perl_argv()
        self.assertEqual(len(calls), 1, calls)
        self.assertEqual(calls[0][-3], "node-a")
        self.assertTrue(calls[0][-2].endswith("core-join.conf"))
        self.assertTrue(calls[0][-1].endswith("core-join.authkey"))
        # The staged secret is gone as soon as perl has read it.
        self.assertEqual(os.listdir(self.run_dir), [])
        # The request went to the member's overlay address and named this
        # node, the one the member has to add to the cluster.
        self.assertEqual(self.asks, [("[fd00:5:6:7:8:9:a:0]:8743", "node-a",
                                      self._member_wg_pub())])

    def _member_wg_pub(self):
        st = node_state.NodeState(self.etc)
        st.load()
        for m in st.membership:
            if m["name"] == "node-b":
                return m["wg_pub"]
        raise AssertionError("node-b is not in the membership list")

    def test_core_refuses_a_node_that_runs_guests(self):
        """A node with a VM or a container stays an edge node, loudly.

        Upstream refuses this too (assert_joinable): a guest's disks, MAC
        address and backup jobs belong to one machine, and a cluster has to
        decide which one, so the operator has to move them off first.
        """
        self._stub_pvesh('[{"type": "vm", "node": "node-a", "vmid": 100}]')
        self._stub_perl()
        self._want_ack()
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("guest(s)", out)
        self.assertFalse(os.path.exists(os.path.join(self.corosync, "authkey")))
        self.assertEqual(self._perl_argv(), [])

    def test_core_refuses_when_the_guest_count_is_unknown(self):
        """No answer from pvesh is not an answer of \"no guests\".

        The guest check is the only thing standing between a node with VMs
        on it and a cluster that disagrees about where those VMs live, so a
        failed check has to stop the join rather than wave it through.
        """
        self._stub_pvesh("", rc=3)
        self._stub_perl()
        self._want_ack()
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("cannot tell whether this node has guests", out)
        self.assertFalse(os.path.exists(os.path.join(self.corosync, "authkey")))

    def test_core_write_only_stops_before_finish_join(self):
        """--write-only leaves the node an edge node with the files in place.

        The point of the flag is to let an operator look at the config the
        cluster handed over before anything is restarted.
        """
        self._stub_pvesh()
        self._stub_perl()
        self._want_ack()
        rc, out = self._core("core", "--write-only")
        self.assertEqual(rc, 0, out)
        self.assertIn("re-run without --write-only", out)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(
            self.corosync, "authkey")).st_mode), 0o400)
        self.assertEqual(self._perl_argv(), [])

    def test_core_restores_the_old_config_when_finish_join_fails(self):
        """A failed finish_join puts this node back the way it was.

        Upstream may have written its own files and stopped pve-cluster before
        it died, so the rollback is the old config plus a restart of both
        services, and the node is reported as what it still is: an edge node.
        """
        self._stub_pvesh()
        self._stub_perl(rc=11)
        old = os.path.join(self.corosync, "corosync.conf")
        with open(old, "w") as fh:
            fh.write("num_nodes = 1\n")
        self._want_ack()
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("finish_join failed (rc=11)", out)
        self.assertIn("still an edge node", out)
        with open(old) as fh:
            self.assertEqual(fh.read(), "num_nodes = 1\n")
        self.assertFalse(os.path.exists(
            os.path.join(self.corosync, "corosync.conf.supermox-single")))
        calls = self._perl_argv()
        self.assertEqual(len(calls), 2, calls)
        self.assertIn("PVE::SysvService", " ".join(calls[1]))
        self.assertEqual(os.listdir(self.run_dir), [])

    def test_core_refuses_while_a_join_awaits_approval(self):
        """A cluster with a request in its queue does not hand out its key.

        The member that answers would be giving the corosync secret to a node
        whose membership has not been decided yet, so the whole cluster has
        to wait for that decision first.
        """
        self._stub_pvesh()
        self._stub_perl()
        self._want_ack()
        st = node_state.NodeState(self.etc)
        st.load()
        st.add_pending({"name": "node-c", "arch": "amd64"})
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("awaiting approval", out)
        self.assertFalse(os.path.exists(os.path.join(self.corosync, "authkey")))

    def test_core_refuses_a_node_that_is_not_a_member(self):
        """No entry for this node means no name to ask a core member with."""
        self._stub_pvesh()
        self._stub_perl()
        self._want_ack()
        st = node_state.NodeState(self.etc)
        st.load()
        st.membership = [m for m in st.membership if m["name"] == "node-b"]
        st.save()
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("not in the membership list", out)
        self.assertEqual(self.asks, [])

    def test_core_reports_a_member_that_refused(self):
        """A member that said no is reported, and the node stays an edge node.

        The reason comes from the daemon (slow link, no quorum, replay), so
        the CLI's job is to pass it through rather than to invent one.
        """
        self._stub_pvesh()
        self._stub_perl()
        self.ack = None
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("no member made this node a core member", out)
        self.assertFalse(os.path.exists(os.path.join(self.corosync, "authkey")))

    def test_core_refuses_a_config_for_another_cluster(self):
        """A member naming a different cluster gets no files written.

        Two clusters that were told the same phrase would otherwise accept
        each other's corosync key, which is the whole point of the check.
        """
        self._stub_pvesh()
        self._stub_perl()
        self._want_ack()
        self.ack["cluster_name"] = "smx-other0"
        rc, out = self._core("core")
        self.assertEqual(rc, 1, out)
        self.assertIn("smx-other0", out)
        self.assertFalse(os.path.exists(os.path.join(self.corosync, "authkey")))


class JsonOutputTest(unittest.TestCase):
    """c08: `members --json` and `pending --json` for the Manager's cluster page.

    The Manager runs these in the node's shell and parses what it gets back, so
    the shape of the JSON, and the empty-array answers, are pinned here.
    """

    def setUp(self):
        self.root = os.path.join(str(ROOT), "build",
                                 "test-json-cli-%d" % os.getpid())
        shutil.rmtree(self.root, ignore_errors=True)
        self.etc = os.path.join(self.root, "etc", "supermox")
        self.conf = os.path.join(self.root, "etc", "pve", "corosync.conf")
        os.makedirs(os.path.dirname(self.conf))
        saved = dict(os.environ)
        self.addCleanup(self._restore_env, saved)
        os.environ["SUPERMOX_ETC"] = self.etc
        self._patcher = mock.patch.object(corosync_cluster,
                                          "PVE_COROSYNC_CONF", self.conf)
        self._patcher.start()
        self.addCleanup(self._patcher.stop)

    def _restore_env(self, saved):
        for var in ("SUPERMOX_ETC",):
            if var in saved:
                os.environ[var] = saved[var]
            else:
                os.environ.pop(var, None)

    def _run(self, *argv):
        buf = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, buf.getvalue(), err.getvalue()

    def _state(self):
        st = node_state.NodeState(self.etc)
        st.create_cluster(PHRASE, "node-a", ["10.0.0.1:8743"], "amd64",
                          ["kvm", "amd64"])
        return st

    def _write_conf(self, *names):
        body = ["# SuperMox cluster (managed by supermox-join; do not rewrite)",
                "nodelist {"]
        for index, name in enumerate(names, start=1):
            body += ["    node {", "        name: %s" % name,
                     "        nodeid: %d" % index, "    }"]
        body += ["}", ""]
        with open(self.conf, "w") as fh:
            fh.write("\n".join(body))

    def test_members_json_lists_the_documented_keys(self):
        self._state()
        rc, out, err = self._run("members", "--json")
        self.assertEqual(rc, 0, out + err)
        members = json.loads(out)
        self.assertEqual(len(members), 1)
        self.assertEqual(
            set(members[0]),
            {"name", "role", "overlay_addr", "arch", "caps", "core"})
        self.assertEqual(members[0]["name"], "node-a")
        self.assertEqual(members[0]["role"], "core")
        self.assertEqual(members[0]["arch"], "amd64")
        self.assertEqual(members[0]["caps"], ["kvm", "amd64"])
        self.assertIn(":", members[0]["overlay_addr"])

    def test_members_json_core_tracks_the_corosync_nodelist(self):
        """core is true only for a member /etc/pve/corosync.conf lists."""
        self._state()
        rc, out, _ = self._run("members", "--json")
        self.assertEqual(rc, 0)
        self.assertFalse(json.loads(out)[0]["core"],
                         "no nodelist yet: not a corosync member")
        self._write_conf("node-a")
        _rc, out, _ = self._run("members", "--json")
        self.assertTrue(json.loads(out)[0]["core"],
                        "listed in the nodelist: a corosync member")

    def test_members_json_without_a_cluster_is_an_empty_array(self):
        """Machine-readable "no cluster": exit 0 and [], not prose and exit 1.

        The Manager offers "Create cluster" exactly when this answer is empty,
        so it has to be able to parse it.
        """
        rc, out, err = self._run("members", "--json")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(json.loads(out), [])

    def test_pending_json_reports_age_in_seconds(self):
        st = self._state()
        st.add_pending({"name": "node-b", "arch": "arm64",
                        "caps": [], "invite_id": "i",
                        "time": int(time.time()) - 90})
        rc, out, err = self._run("pending", "--json")
        self.assertEqual(rc, 0, out + err)
        pending = json.loads(out)
        self.assertEqual(len(pending), 1)
        self.assertEqual(set(pending[0]), {"id", "name", "arch", "age_s"})
        self.assertEqual(pending[0]["name"], "node-b")
        self.assertEqual(pending[0]["arch"], "arm64")
        self.assertIn(pending[0]["id"], st.pending)
        self.assertLessEqual(85, pending[0]["age_s"])
        self.assertLessEqual(pending[0]["age_s"], 95)

    def test_pending_json_with_nothing_waiting_is_an_empty_array(self):
        self._state()
        rc, out, err = self._run("pending", "--json")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(json.loads(out), [])

    def test_plain_output_is_unchanged(self):
        """Without --json the human output, and its exit codes, stay as they were.

        The Manager is a consumer added on top; people reading this on a phone
        still get the prose.
        """
        self._state()
        rc, out, _ = self._run("pending")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "no join requests waiting\n")
        rc, out, _ = self._run("members")
        self.assertIn("node-a", out)
        self.assertNotIn("{", out)


if __name__ == "__main__":
    unittest.main()
