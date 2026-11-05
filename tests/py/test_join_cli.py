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
import os
import stat
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


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

    def _restore_env(self, saved):
        for var in ("SUPERMOX_ETC", "SUPERMOX_WG_DIR", "SUPERMOX_WG_INITD"):
            if var in saved:
                os.environ[var] = saved[var]
            else:
                os.environ.pop(var, None)

    def _create(self, *argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cli.main(list(argv))
        return rc, buf.getvalue()

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


if __name__ == "__main__":
    unittest.main()
