"""Unit tests for the terminal session: exact paths, framing and paste helpers.

A fake websocket stands in for the node; no server and no GTK. The framing
checked here is the one the running node advertises (see
.strata/notes-t70-manager-terminal.md): handshake "<user>:<ticket>\\n",
data "0:<byte length>:<data>", resize "1:<cols>:<rows>:", keepalive "2".
"""

import socket
import time
import unittest

from supermox_manager import api
from supermox_manager.ops import terminal, websocket


class Recorder:
    """Records API calls; carries the attributes open_session needs."""

    def __init__(self, proxy=None):
        self.calls = []
        self.proxy = proxy if proxy is not None else {
            "port": "5900", "ticket": "pveconsole-abc/def+ghi",
            "user": "root@pam", "upid": "UPID:x:vncshell::root@pam:"}
        self.host, self.port, self.pin = "node.example", 8006, "a" * 64
        self.ticket = "PVE-TICKET"
        self.username = "root@pam"
        self.timeout = 15

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return self.proxy


class FakeWebSocket:
    """Stands in for a connected websocket: records frames, feeds answers."""

    def __init__(self, answers=()):
        self.sent = []          # (opcode, payload bytes), in order
        self._answers = list(answers)
        self.closed = False

    def send(self, data, opcode=0x2, chunk=0):
        self.sent.append((opcode, data))

    def send_text(self, text):
        self.send(text.encode("utf-8"), opcode=0x1)

    def recv(self):
        if self._answers:
            return 0x1, self._answers.pop(0)
        raise socket.timeout  # a quiet session, like a real socket

    def close(self):
        self.closed = True


class ConnectPatch:
    """Replaces websocket.connect and remembers how it was called."""

    def __init__(self, ws=None, answers=()):
        self.ws = ws if ws is not None else FakeWebSocket(answers)
        self.args = None
        self.original = None

    def __enter__(self):
        self.original = websocket.connect
        websocket.connect = self._connect
        return self

    def __exit__(self, *exc):
        websocket.connect = self.original
        return False

    def _connect(self, host, port, path, pin, cookie=None, timeout=15,
                 subprotocol="binary", extra_headers=()):
        self.args = dict(host=host, port=port, path=path, pin=pin,
                         cookie=cookie, timeout=timeout,
                         subprotocol=subprotocol)
        return self.ws


class OpenSession(unittest.TestCase):
    def test_node_shell_paths_are_exact(self):
        client = Recorder()
        with ConnectPatch(answers=[b"OK"]) as patch:
            session = terminal.open_session(client, "atlas")
        self.assertEqual(client.calls, [("POST", "/nodes/atlas/termproxy", None)])
        self.assertEqual(patch.args["path"],
                         "/api2/json/nodes/atlas/vncwebsocket"
                         "?port=5900&vncticket=pveconsole-abc%2Fdef%2Bghi")
        self.assertEqual(patch.args["cookie"], "PVEAuthCookie=PVE-TICKET")
        self.assertEqual(patch.args["subprotocol"], "binary")
        self.assertEqual(patch.args["host"], "node.example")
        self.assertEqual(patch.args["port"], 8006)
        self.assertEqual(patch.args["pin"], "a" * 64)
        self.assertEqual(patch.ws.sent[0],
                         (0x1, b"root@pam:pveconsole-abc/def+ghi\n"))
        session.close()

    def test_container_console_paths(self):
        client = Recorder()
        with ConnectPatch(answers=[b"OK"]) as patch:
            session = terminal.open_session(client, "atlas", vmid=101, kind="lxc")
        self.assertEqual(client.calls,
                         [("POST", "/nodes/atlas/lxc/101/termproxy", None)])
        self.assertIn("/api2/json/nodes/atlas/lxc/101/vncwebsocket?port=5900",
                      patch.args["path"])
        session.close()
        client = Recorder()
        with ConnectPatch(answers=[b"OK"]) as patch:
            session = terminal.open_session(client, "atlas", vmid=102, kind="qemu")
        self.assertEqual(client.calls,
                         [("POST", "/nodes/atlas/qemu/102/termproxy", None)])
        session.close()

    def test_handshake_answer_must_start_with_ok(self):
        client = Recorder()
        with ConnectPatch(answers=[b"error"]) as patch:
            with self.assertRaises(api.APIError):
                terminal.open_session(client, "atlas")
        self.assertTrue(patch.ws.closed)

    def test_missing_port_is_an_error(self):
        client = Recorder(proxy={"user": "root@pam", "ticket": "t"})
        with ConnectPatch():
            with self.assertRaises(api.APIError):
                terminal.open_session(client, "atlas")
        self.assertEqual(client.calls, [("POST", "/nodes/atlas/termproxy", None)])

    def test_refused_handshake_names_the_failure(self):
        client = Recorder()
        ws = FakeWebSocket()
        ws.recv = lambda: (_ for _ in ()).throw(websocket.WebSocketError("gone"))
        with ConnectPatch(ws) as patch:
            with self.assertRaises(api.APIError) as caught:
                terminal.open_session(client, "atlas")
        self.assertIn("refused", str(caught.exception))
        self.assertTrue(patch.ws.closed)

    def test_output_after_ok_reaches_recv(self):
        client = Recorder()
        with ConnectPatch(answers=[b"OKtail-data"]) as patch:
            session = terminal.open_session(client, "atlas")
            self.assertEqual(session.recv(timeout=2), b"tail-data")
        session.close()

    def test_argument_validation(self):
        for kwargs in ({"vmid": 101}, {"kind": "lxc"}, {"vmid": 101,
                                       "kind": "spice"}):
            with self.assertRaises(ValueError):
                terminal.open_session(Recorder(), "atlas", **kwargs)


class Framing(unittest.TestCase):
    def session(self, answers=(b"OK",)):
        patch = ConnectPatch(answers=list(answers))
        patch.__enter__()
        self.addCleanup(patch.__exit__)
        session = terminal.open_session(Recorder(), "atlas")
        self.addCleanup(session.close)
        return patch.ws, session

    def data_frames(self, ws):
        """Keystroke payloads: the bytes after "0:<len>:" in each data frame.

        Also checks every frame states its own byte length and stays within
        CHUNK, so a reordered or truncated paste cannot slip through.
        """
        out = []
        for opcode, payload in ws.sent:
            if opcode != 0x1 or not payload.startswith(b"0:"):
                continue
            length, _, data = payload[2:].partition(b":")
            self.assertEqual(int(length), len(data), payload[:16])
            self.assertLessEqual(len(data), terminal.CHUNK)
            out.append(data)
        return out

    def test_large_paste_arrives_as_ordered_chunks(self):
        ws, session = self.session()
        lines = ["line %04d é →\t%d" % (index, index) for index in range(1200)]
        text = "\n".join(lines) + "\n"
        self.assertGreater(len(text.encode("utf-8")), 20 * 1024)
        session.send(text)
        payloads = self.data_frames(ws)
        self.assertGreater(len(payloads), 4)
        self.assertEqual(b"".join(payloads), text.encode("utf-8"))

    def test_a_chunk_never_cuts_a_utf8_character(self):
        ws, session = self.session()
        text = "é" * (terminal.CHUNK + 10)
        session.send(text)
        payloads = self.data_frames(ws)
        self.assertGreater(len(payloads), 1)
        for data in payloads:
            self.assertEqual(len(data) % 2, 0)  # é is two bytes, never split
            data.decode("utf-8")
        self.assertEqual(b"".join(payloads), text.encode("utf-8"))

    def test_resize_frame(self):
        ws, session = self.session()
        session.resize(120, 30)
        self.assertIn((0x1, b"1:120:30:"), ws.sent)

    def test_bytes_and_str_send_identically(self):
        ws, session = self.session()
        session.send("é\n")
        first = ws.sent[-1]
        session.send("é\n".encode("utf-8"))
        self.assertEqual(first, (0x1, b"0:3:\xc3\xa9\n"))
        self.assertEqual(ws.sent[-1], first)

    def test_keepalive_is_sent(self):
        original = terminal.KEEPALIVE_SECONDS
        terminal.KEEPALIVE_SECONDS = 0.05
        self.addCleanup(setattr, terminal, "KEEPALIVE_SECONDS", original)
        ws, session = self.session()
        deadline = time.time() + 5
        while time.time() < deadline:
            if any(payload == b"2" for _, payload in ws.sent):
                break
            time.sleep(0.02)
        self.assertIn((0x1, b"2"), ws.sent)

    def test_send_after_close_raises(self):
        ws, session = self.session()
        session.close()
        session.close()
        self.assertTrue(ws.closed)
        with self.assertRaises(api.APIError):
            session.send("ls\n")

    def test_recv_reports_a_dead_session(self):
        ws, session = self.session()
        ws.recv = lambda: (_ for _ in ()).throw(websocket.WebSocketError("gone"))
        self.assertIsNone(session.recv(timeout=5))
        self.assertFalse(session.alive)


class PasteHelpers(unittest.TestCase):
    def test_paste_lines(self):
        self.assertEqual(terminal.paste_lines(""), 0)
        self.assertEqual(terminal.paste_lines("   \n\t\n"), 0)
        self.assertEqual(terminal.paste_lines("one"), 1)
        self.assertEqual(terminal.paste_lines("one\ntwo"), 2)
        self.assertEqual(terminal.paste_lines("one\ntwo\n"), 2)
        self.assertEqual(terminal.paste_lines("one\r\ntwo\r\n"), 2)
        self.assertEqual(terminal.paste_lines("one\rtwo"), 2)
        self.assertEqual(terminal.paste_lines("\n"), 0)

    def test_one_line(self):
        self.assertEqual(terminal.one_line("a\nb\r\nc\n"), "a b c")
        self.assertEqual(terminal.one_line("  a\tb  "), "a b")
        self.assertEqual(terminal.one_line(""), "")


if __name__ == "__main__":
    unittest.main()
