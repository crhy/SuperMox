#!/usr/bin/env python3
"""Live tests for the terminal sessions SuperMox Manager opens.

Skipped unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, with
the SSL fingerprint, only when a VM is up). tests/py/test_manager_terminal.py
proves the frames we build against a fake websocket; this file proves the real
ones: the termproxy ticket, the handshake against proxmox-termproxy on the node,
that a real pty echoes what we type, that a real guest console opens, and that
the node accepts a paste larger than one frame.

The guest test is the only write: it creates LXC VMID 9930 from a template,
boots it, opens its console, then destroys it.
"""
import os
import time
import unittest

from supermox_manager import api
from supermox_manager.ops import tasks
from supermox_manager.ops import containers as ct_ops
from supermox_manager.ops import terminal, guests

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

VMID = 9930


def collect(session, marker, seconds=15):
    """Read terminal output until ``marker`` shows up, or the wait runs out.

    Returns the readable transcript: escape sequences stripped, so the
    assertion is about what a window would display.
    """
    buf = b""
    deadline = time.time() + seconds
    while time.time() < deadline:
        data = session.recv(timeout=2)
        if data is None:
            break
        buf += data
        if marker.encode("utf-8") in buf:
            break
    return terminal.readable(buf)


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class TerminalLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASSWORD)
        cls.node = cls.client.request("GET", "/nodes")[0]["node"]

    @classmethod
    def tearDownClass(cls):
        try:
            cls.client.logout()
        except Exception:  # noqa: BLE001 - best effort
            pass

    def test_node_shell_round_trip(self):
        session = terminal.open_session(self.client, self.node)
        try:
            self.assertTrue(session.alive, "the node refused the terminal session")
            session.resize(80, 24)
            session.send("echo SMOKETEST_$((6*7))\n")
            text = collect(session, "SMOKETEST_42")
        finally:
            session.close()
        self.assertIn("SMOKETEST_42", text,
                      "the node shell never echoed the command back")
        self.assertTrue(session.closed)
        # A closed session refuses to send, and the websocket is gone.
        with self.assertRaises(api.APIError):
            session.send("echo gone\n")

    def test_paste_larger_than_one_frame(self):
        # The paste is typed, not executed: the node must echo every frame back
        # in order, head first and tail last, with nothing lost in between.
        body = "x" * (terminal.CHUNK * 2 + 7)
        session = terminal.open_session(self.client, self.node)
        try:
            session.resize(80, 24)
            session.send("printf '%s' PASTE_HEAD" + body + "_TAIL\n")
            text = collect(session, "_TAIL", seconds=30)
        finally:
            session.close()
        self.assertIn("PASTE_HEAD", text)
        self.assertIn("_TAIL", text)
        # The pty wraps at 80 columns, so only the ends can be checked; their
        # order proves the frames arrived in sequence.
        self.assertLess(text.index("PASTE_HEAD"), text.index("_TAIL"))

    def test_guest_console_of_a_started_container(self):
        self._destroy()
        try:
            template = self._template()
            self.assertTrue(template, "no LXC template on this node")
            params = ct_ops.ct_params({
                "hostname": "smoke-ct", "template": template,
                "storage": "local", "size": 1, "memory": 64, "cores": 1})
            upid = ct_ops.create_ct(self.client, self.node, VMID, params)
            tasks.wait_task(self.client, self.node, upid, timeout=300)
            upid = ct_ops.start_ct(self.client, self.node, VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
            session = terminal.open_session(self.client, self.node,
                                            vmid=VMID, kind="lxc")
            try:
                self.assertTrue(session.alive, "the guest console did not open")
                session.resize(80, 24)
                # The console lands on the container's own getty, so the first
                # thing it shows is the container's boot banner and login
                # prompt. Alpine's login asks for root's password, which a
                # template container does not have, so typing a command here
                # would be swallowed as a username: what this test proves is
                # that the guest pty opened and that keystrokes reach it.
                banner = collect(session, "login:", seconds=20)
                self.assertIn("login:", banner,
                              "the guest console never showed a login prompt")
                self.assertIn("Welcome to", banner,
                              "the guest console never showed the container banner")
                session.send("root\n")
                reply = collect(session, "Password:", seconds=10)
                if "Password:" not in reply:
                    reply += collect(session, "Login incorrect", seconds=10)
                self.assertTrue("Password:" in reply or "Login incorrect" in reply,
                                "the guest console ignored what we typed")
            finally:
                session.close()
        finally:
            self._destroy()

    def _template(self):
        """A template ready to use: a cached one, else download the newest alpine."""
        ready = sorted(ct_ops.templates(self.client, self.node))
        if ready:
            return ready[-1]
        rows = [row for row in ct_ops.available_templates(self.client, self.node)
                if row["os"] == "alpine"]
        if not rows:
            return None
        name = rows[-1]["template"]
        upid = ct_ops.download_template(self.client, self.node, "local", name)
        tasks.wait_task(self.client, self.node, upid, timeout=600)
        return "local:vztmpl/" + name

    def _destroy(self):
        try:
            upid = ct_ops.stop_ct(self.client, self.node, VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=60,
                            allow_warnings=True)
        except api.APIError:
            pass
        try:
            upid = guests.destroy(self.client, self.node, "lxc", VMID)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
        except api.APIError:
            pass


if __name__ == "__main__":
    unittest.main()
