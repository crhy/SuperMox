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
import select
import socket
import ssl
import sys
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

    refuse=True answers a plain 401 instead of upgrading; accept and subprotocol
    can be broken on purpose to check what the client insists on.

    The listening socket stays plain and is polled with select(), and each
    connection is handed its own daemon thread: the TLS handshake and _handle
    for one connection can never delay another connection, because a single
    serving thread finishes one connection before it accepts the next one, so
    a client that connects and then sends nothing (abandoned, half-open) costs
    every later client the whole per-connection timeout. Wrapping the listening
    socket instead is worse still: it parks the serving thread inside accept(),
    and closing a socket does not wake a thread already blocked in accept() on
    it, so stop() burned its whole join timeout and leaked the thread.
    """

    _POLL = 0.2            # select() timeout, seconds
    _CONNECTION = 10.0    # per-connection timeout, seconds
    _JOIN = 1.0           # total join budget for the connection threads, seconds

    def __init__(self, pem, key, accept=None, subprotocol="binary", refuse=False):
        self._sid = id(self)
        self.requests = []
        self.accept = accept
        self.subprotocol = subprotocol
        self.refuse = refuse
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(pem, key)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen(8)
        self._serving = True
        self._lock = threading.Lock()
        self._open = []     # (thread, connection) still being served
        self._closing = set()  # fds this server owns and has already closed
        self._overlap = 0   # most connections served at once
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _dbg(self, what, connection=None, exc=None):
        """WS_DEBUG=1: say WHY/WHEN this server closed a connection.

        Prints the server id, the thread, the fd and (when given) the exception,
        so a run that kills another test's live socket can be traced to the
        exact close path and object that did it.
        """
        if os.environ.get("WS_DEBUG") != "1":
            return
        fd = "-"
        if connection is not None:
            try:
                fd = connection.fileno()
            except (OSError, ValueError):
                fd = "closed"
        sys.stderr.write("[ws srv {} thread={} {} fd={} exc={!r}\n".format(
            self._sid, threading.current_thread().name, what, fd, exc))
        sys.stderr.flush()

    @property
    def port(self):
        return self.socket.getsockname()[1]

    def overlap(self):
        """The most connections this server has ever served at once.

        One is what a single serving thread can never exceed: it finishes one
        connection before it accepts the next, so a stalled client shows up
        here as overlap of 1 and every later client waits for it.
        """
        with self._lock:
            return self._overlap

    def _serve(self):
        """Accept in the poll loop; one thread per connection."""
        while self._serving:
            try:
                ready, _, _ = select.select([self.socket], [self.socket], [],
                                            self._POLL)
            except (OSError, ValueError):
                return          # stop() closed the listening socket
            if not ready:
                continue
            try:
                plain, _address = self.socket.accept()
            except OSError:
                return
            threading.Thread(target=self._connection,
                             args=(plain,), daemon=True).start()

    def _close(self, connection):
        """Close ONE connection this server owns, exactly once, right now.

        A connection is closed by the thread that owns it (or by stop(), which
        hands the fd to that thread by marking it), never by a thread that is
        still blocked in _handle or do_handshake: such a thread would close
        its fd only when it later wakes up, by which time the fd number has
        been recycled by another test's socket and the close would kill that
        live connection (the BrokenPipeError / 'Bad file descriptor' cascade
        seen in the full suite). The _closing set makes the close idempotent
        per fd, so stop() and the owning thread can never double-close a
        recycled fd.
        """
        with self._lock:
            try:
                fd = connection.fileno()
            except (OSError, ValueError):
                fd = None
            if fd is not None and fd in self._closing:
                return          # already closed by us; fd may be recycled now
            if fd is not None:
                self._closing.add(fd)
        try:
            connection.close()
        except OSError:
            pass

    def _connection(self, plain):
        """TLS handshake + serving of ONE connection, in its own thread.

        The timeout set on the plain socket bounds the handshake and every
        read _handle takes, so a stalled client ends on its own; stop() also
        closes the connection so it does not have to wait for that timeout.
        """
        plain.settimeout(self._CONNECTION)
        try:
            connection = self.context.wrap_socket(plain, server_side=True,
                                                  do_handshake_on_connect=False)
        except OSError as exc:
            self._dbg("wrap-fail", plain, exc)
            plain.close()
            return
        try:
            connection.do_handshake()
        except OSError as exc:
            # plain is detached by wrap_socket (plain.fileno() is -1), so plain
            # closes nothing here: the SSLSocket wrapper owns the fd and must
            # be closed explicitly, now, or it is left to the GC, which frees
            # the fd whenever it runs - possibly after another test reused it.
            self._dbg("handshake-fail", connection, exc)
            self._close(connection)
            return
        with self._lock:
            if not self._serving:
                abandoned = True
            else:
                abandoned = False
                self._open.append((threading.current_thread(), connection))
                self._overlap = max(self._overlap, len(self._open))
        if abandoned:
            # Close OUTSIDE the lock: _close re-acquires self._lock, and a
            # non-reentrant Lock deadlocks if we call it while holding it (stop()
            # then blocks reading _open). This fd is not in _open, so stop()
            # will not close it; we must, but only after releasing the lock.
            self._close(connection)
            return
        try:
            self._handle(connection)
        except (OSError, websocket.WebSocketError) as exc:
            self._dbg("handle-end", connection, exc)
        finally:
            self._close(connection)
            with self._lock:
                self._open = [(thread, sock) for thread, sock in self._open
                              if thread is not threading.current_thread()]

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
        self._serving = False
        try:
            self.socket.close()
        except OSError:
            pass
        with self._lock:
            open_now = list(self._open)
        for _thread, connection in open_now:
            # Close the connection here, while this server still owns the fd,
            # so the serving thread (which may be blocked in _handle) can never
            # close a recycled fd later; _close is idempotent per fd.
            self._dbg("stop-close", connection)
            self._close(connection)
        deadline = time.monotonic() + self._JOIN
        for thread, _connection in open_now:
            thread.join(timeout=max(0.0, deadline - time.monotonic()))
        if self.thread:
            self.thread.join(timeout=5)


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

    def abandon(self, server):
        """One client that finishes the TLS handshake and then sends nothing.

        This is what a half-open or abandoned connection looks like to the
        server: the handshake completes, so the server starts serving it, and
        then no request ever arrives.
        """
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        plain = socket.create_connection(("127.0.0.1", server.port), timeout=5)
        stalled = context.wrap_socket(plain, server_hostname="127.0.0.1")
        self.addCleanup(stalled.close)
        return stalled

    def test_abandoned_connection_does_not_delay_the_next_one(self):
        # A client that connects and then sends nothing must not cost the next
        # client its answer: the handshake and the serving of a connection
        # happen in that connection's own thread, so the two connections
        # overlap instead of queueing behind the per-connection timeout.
        # overlap() is checked instead of a wall-clock bound, because a
        # wall-clock bound on a loaded machine is what makes a test flaky.
        server = self.serve()
        self.abandon(server)
        connection = websocket.connect("127.0.0.1", server.port, "/x",
                                       self.pin)
        self.addCleanup(connection.close)
        connection.send(b"still served", opcode=0x2)
        self.assertEqual(connection.recv(), (0x2, b"still served"))
        self.assertGreaterEqual(server.overlap(), 2)

    def test_stop_returns_while_a_connection_is_stalled(self):
        # stop() closes the open connections and joins with a short budget,
        # so a stalled client cannot keep the test process waiting: the serving
        # thread is gone even though that client never sent a request.
        server = self.serve()
        self.abandon(server)
        server.stop()
        self.assertFalse(server.thread.is_alive())

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

    def test_stop_leaves_no_thread_parked_in_accept(self):
        # A refusing server returns from _handle at once, so its thread is
        # already back in accept() when stop() runs. It must still shut down
        # in one poll: a thread parked in accept() on a closed socket never
        # wakes up, and every later test pays its join timeout.
        server = self.serve(refuse=True)
        with self.assertRaisesRegex(websocket.WebSocketError,
                                    "refused the websocket"):
            websocket.connect("127.0.0.1", server.port, "/x", self.pin)
        started = time.time()
        server.stop()
        self.assertLess(time.time() - started, 3.0)
        self.assertFalse(server.thread.is_alive())
