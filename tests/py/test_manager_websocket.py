"""Unit tests for the stdlib WebSocket client in ops/websocket.py.

Frame codec round trips (0, 125, 126, 65535, 65536 payload bytes), client
masking, fragmented messages, ping/pong, and the upgrade handshake against a
local TLS server, including the pinned-certificate rule: a wrong fingerprint
must fail before any cookie or request line reaches the server.

The production decoder refuses masked frames because servers must not mask
(RFC 6455), so frames this client sends are checked with a reader that does
unmask them, exactly as a server would.
"""

import os
import socket
import ssl
import threading
import time
import unittest

from supermox_manager import api, logic
from supermox_manager.ops import websocket
from test_manager_pin import _self_signed_cn, _TempDir

TEXT = "é→ tab\t"


class _Stream:
    """A read(count) callable over a fixed byte buffer, as a frame source."""

    def __init__(self, data):
        self.data = data

    def read(self, count):
        chunk, self.data = self.data[:count], self.data[count:]
        return chunk


def _read_exact(read, count):
    parts = b""
    while len(parts) < count:
        chunk = read(count - len(parts))
        if not chunk:
            raise OSError("test reader: truncated frame")
        parts += chunk
    return parts


def _client_frame(read):
    """Read one frame as a server would: unmask it when the client masked it."""
    head = _read_exact(read, 2)
    masked = bool(head[1] & 0x80)
    opcode = head[0] & 0x0F
    finished = bool(head[0] & 0x80)
    length = head[1] & 0x7F
    if length == 126:
        length = int.from_bytes(_read_exact(read, 2), "big")
    elif length == 127:
        length = int.from_bytes(_read_exact(read, 8), "big")
    key = _read_exact(read, 4) if masked else b""
    payload = _read_exact(read, length)
    if masked:
        payload = websocket.mask(payload, key)
    return opcode, payload, finished


def _client_message(read):
    """Reassemble one message out of the frames this client produced."""
    parts, opcode = [], None
    while True:
        frame_opcode, payload, finished = _client_frame(read)
        if frame_opcode:
            opcode = frame_opcode
        parts.append(payload)
        if finished:
            return opcode, b"".join(parts)


class FrameCodec(unittest.TestCase):
    def test_unmasked_round_trip_lengths(self):
        for length in (0, 1, 125, 126, 65535, 65536, 200000):
            payload = os.urandom(length)
            raw = websocket.encode_frame(payload, 0x2, b"")
            opcode, decoded, finished = websocket.FrameDecoder(
                _Stream(raw).read).frame()
            self.assertEqual((opcode, finished), (0x2, True), "length {}".format(length))
            self.assertEqual(decoded, payload, "length {}".format(length))

    def test_masked_round_trip_lengths(self):
        for length in (0, 1, 125, 126, 65535, 65536, 200000):
            payload = os.urandom(length)
            for key in (b"\x01\x02\x03\x04", os.urandom(4)):
                raw = websocket.encode_frame(payload, 0x2, key)
                opcode, decoded, finished = _client_frame(_Stream(raw).read)
                self.assertEqual((opcode, finished), (0x2, True), "length {}".format(length))
                self.assertEqual(decoded, payload, "length {}".format(length))

    def test_client_frames_are_masked_and_recoverable(self):
        payload = TEXT.encode("utf-8") * 400
        raw = websocket.encode_frame(payload, 0x2, b"\x01\x02\x03\x04")
        self.assertTrue(raw[1] & 0x80, "client frame must be masked")
        self.assertNotIn(payload, raw, "payload must not travel unmasked")
        self.assertEqual(_client_frame(_Stream(raw).read)[:2], (0x2, payload))

    def test_a_random_key_is_used_when_none_is_given(self):
        payload = b"the same payload twice"
        first = websocket.encode_frame(payload, 0x2)
        second = websocket.encode_frame(payload, 0x2)
        self.assertNotEqual(first, second, "frames must not repeat a mask key")
        self.assertEqual(_client_frame(_Stream(first).read)[1], payload)

    def test_server_frames_must_not_be_masked(self):
        raw = websocket.encode_frame(b"hi", 0x2, os.urandom(4))
        with self.assertRaisesRegex(websocket.WebSocketError, "masked a server frame"):
            websocket.FrameDecoder(_Stream(raw).read).frame()

    def test_fragmented_message_is_reassembled(self):
        payload = TEXT.encode("utf-8") * 300
        frames = websocket.split_frames(payload, 0x2, 1000)
        self.assertGreater(len(frames), 1, "payload should split")
        opcode, decoded = _client_message(_Stream(b"".join(frames)).read)
        self.assertEqual((opcode, decoded), (0x2, payload))
        unmasked = [websocket.encode_frame(payload[:1000], 0x2, b"", continuation=True),
                    websocket.encode_frame(payload[1000:], 0x0, b"")]
        self.assertEqual(websocket.FrameDecoder(
            _Stream(b"".join(unmasked)).read).message(), (0x2, payload))

    def test_accept_token_matches_an_independent_computation(self):
        # cross-checked with:
        #   printf '<key>258EAFA5-E914-47DA-95CA-C5AB0DC85B11' |
        #       openssl sha1 -sha1 -binary | base64
        self.assertEqual(websocket.accept_token("dG7eF2yYhZ0YWSOoxcpeYOGiilA="),
                         "yacVyxHd50TpiuJNQtEOr0Ik3n4=")

    def test_ping_is_answered_with_a_pong_and_skipped(self):
        written = []
        stream = (websocket.encode_frame(b"tick", 0x9, b"") +
                  websocket.encode_frame(b"body", 0x2, b""))
        decoder = websocket.FrameDecoder(_Stream(stream).read,
                                         send_frame=written.append)
        self.assertEqual(decoder.message(), (0x2, b"body"))
        self.assertEqual(len(written), 1, "exactly one pong was sent")
        self.assertEqual(_client_frame(_Stream(written[0]).read)[:2],
                         (0xA, b"tick"), "the pong echoes the ping payload")

    def test_close_frame_ends_the_connection(self):
        raw = websocket.encode_frame(b"", 0x8, b"")
        with self.assertRaisesRegex(websocket.WebSocketError, "closed the connection"):
            websocket.FrameDecoder(_Stream(raw).read).message()

    def test_oversized_frame_is_refused(self):
        raw = bytes([0x82, 0x7F]) + (2 ** 63).to_bytes(8, "big")
        with self.assertRaisesRegex(websocket.WebSocketError, "oversized frame"):
            websocket.FrameDecoder(_Stream(raw).read).frame()


class _EchoServer:
    """A TLS websocket server that echoes every message back unmasked.

    Every accepted connection gets its own daemon thread and its own read
    deadline (``timeout``, 10 s: the per-connection timeout the SuperMox#11
    log showed), so an idle or abandoned connection can never sit in front of
    the next connection the way an inline _handle did.

    refuse=True answers a plain 401 instead of upgrading; accept and subprotocol
    can be broken on purpose to check what the client insists on.
    """

    def __init__(self, pem, key, accept=None, subprotocol="binary", refuse=False,
                 timeout=10):
        self.requests = []
        self.accept = accept
        self.subprotocol = subprotocol
        self.refuse = refuse
        self.timeout = timeout
        self._open = []
        self._lock = threading.Lock()
        self._stopping = False
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(pem, key)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket = self.context.wrap_socket(self.socket, server_side=True)
        self.socket.listen(8)
        # accept() must not park forever: a closed listening socket does not
        # always wake a thread already blocked in accept(), which is how a
        # harness ends up waiting out a join timeout for every test.
        self.socket.settimeout(0.5)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    @property
    def port(self):
        return self.socket.getsockname()[1]

    def _serve(self):
        while not self._stopping:
            try:
                connection, _address = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if self._stopping:
                connection.close()
                return
            threading.Thread(target=self._serve_connection,
                             args=(connection,), daemon=True).start()

    def _serve_connection(self, connection):
        """One connection, in its own thread, with its own read deadline.

        The thread registers itself, so stop() can never join a thread that
        has not started, and settimeout is inside the try because stop() may
        close this connection at any moment.
        """
        with self._lock:
            self._open.append((connection, threading.current_thread()))
        try:
            connection.settimeout(self.timeout)
            self._handle(connection)
        except (OSError, websocket.WebSocketError):
            pass
        finally:
            with self._lock:
                self._open = [item for item in self._open
                              if item[0] is not connection]
            connection.close()

    def _handle(self, connection):
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = connection.recv(1)
            if not chunk:
                return
            head += chunk
        lines = head.decode("latin-1").split("\r\n")
        self.requests.append(lines[0])
        fields = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            fields[name.lower().strip()] = value.strip()
        if self.refuse:
            connection.sendall(b"HTTP/1.1 401 Unauthorized\r\n\r\n")
            return
        answer = ["HTTP/1.1 101 Upgrade", "Upgrade: websocket",
                  "Connection: upgrade",
                  "Sec-WebSocket-Accept: " + (self.accept or
                                             websocket.accept_token(
                                                 fields["sec-websocket-key"]))]
        if self.subprotocol:
            answer.append("Sec-WebSocket-Protocol: " + self.subprotocol)
        connection.sendall(("\r\n".join(answer) + "\r\n\r\n").encode("latin-1"))
        read = connection.recv
        while True:
            opcode, payload, _finished = _client_frame(read)
            if opcode == 0x8:
                return
            connection.sendall(websocket.encode_frame(payload, 0x2, b""))

    def stop(self):
        self._stopping = True
        self.socket.close()
        with self._lock:
            pending = list(self._open)
        for connection, _thread in pending:
            try:
                connection.close()
            except OSError:
                pass
        for _connection, thread in pending:
            thread.join(timeout=5)
        self.thread.join(timeout=1)


class Handshake(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = _TempDir().make()
        root = os.path.join(cls.directory.name, "tls")
        os.makedirs(root)
        pem, key, der = _self_signed_cn("websocket-test")
        with open(os.path.join(root, "cert.pem"), "wb") as handle:
            handle.write(pem)
        with open(os.path.join(root, "key.pem"), "wb") as handle:
            handle.write(key)
        cls.pem, cls.key = os.path.join(root, "cert.pem"), os.path.join(root, "key.pem")
        cls.pin = logic.fingerprint_der(der)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def serve(self, **kwargs):
        self.server = _EchoServer(self.pem, self.key, **kwargs)
        self.addCleanup(self.server.stop)
        return self.server

    def test_handshake_accept_and_echo(self):
        server = self.serve()
        connection = websocket.connect("127.0.0.1", server.port,
                                       "/api2/json/nodes/atlas/vncwebsocket?port=5&vncticket=x",
                                       self.pin, cookie="PVEAuthCookie=PVE%3Aticket")
        try:
            connection.send(b"root@pam:ticket\n", opcode=0x2)
            self.assertEqual(connection.recv(), (0x2, b"root@pam:ticket\n"))
            connection.send(b"a" * 9000, opcode=0x2)
            self.assertEqual(connection.recv(), (0x2, b"a" * 9000))
        finally:
            connection.close()
        self.assertIn("GET /api2/json/nodes/atlas/vncwebsocket?port=5&vncticket=x HTTP/1.1",
                      server.requests)

    def test_abandoned_connection_does_not_delay_the_next_one(self):
        # A connection that finishes its handshake and then sends nothing - no
        # frame, no close frame - must not be the thing standing in front of
        # the next connection. The live round trip has to come back well inside
        # the server's 10 s per-connection deadline, while the abandoned one is
        # still open and is the one that ends in a timeout.
        server = self.serve()
        abandoned = websocket.connect("127.0.0.1", server.port, "/x", self.pin,
                                      timeout=2)
        try:
            live = websocket.connect("127.0.0.1", server.port, "/x", self.pin,
                                     timeout=4)
            try:
                started = time.monotonic()
                live.send_text(TEXT)
                answer = live.recv()
                elapsed = time.monotonic() - started
            finally:
                live.close()
            self.assertEqual(answer, (0x2, TEXT.encode("utf-8")))
            self.assertLess(elapsed, 3.0, "the live round trip must finish inside "
                            "3 s, while the abandoned connection is still open")
            self.assertEqual(len(server.requests), 2,
                             "both handshakes reached the server")
            self.assertFalse(abandoned.closed,
                             "the abandoned connection is still open")
            with self.assertRaises(socket.timeout):
                abandoned.recv()
        finally:
            abandoned.close()

    def test_ping_round_trip(self):
        server = self.serve()
        connection = websocket.connect("127.0.0.1", server.port, "/x", self.pin)
        connection.ping(b"keepalive")
        # the echo server answers a ping with a text message, so the client
        # sees the payload back as a message
        self.assertEqual(connection.recv(), (0x2, b"keepalive"))
        connection.close()

    def test_wrong_pin_sends_no_cookie_and_no_request(self):
        server = self.serve()
        with self.assertRaisesRegex(api.APIError, "No credentials were sent"):
            websocket.connect("127.0.0.1", server.port, "/x", "0" * 64,
                               cookie="PVEAuthCookie=never-send-this")
        self.assertEqual(server.requests, [])

    def test_bad_accept_token_is_rejected(self):
        server = self.serve(accept="not-the-accept-token")
        with self.assertRaisesRegex(websocket.WebSocketError,
                                    "handshake key was not accepted"):
            websocket.connect("127.0.0.1", server.port, "/x", self.pin)

    def test_missing_subprotocol_is_rejected(self):
        server = self.serve(subprotocol=None)
        with self.assertRaisesRegex(websocket.WebSocketError, "binary subprotocol"):
            websocket.connect("127.0.0.1", server.port, "/x", self.pin)

    def test_plain_http_answer_is_reported(self):
        server = self.serve(refuse=True)
        with self.assertRaisesRegex(websocket.WebSocketError,
                                    "refused the websocket"):
            websocket.connect("127.0.0.1", server.port, "/x", self.pin)
