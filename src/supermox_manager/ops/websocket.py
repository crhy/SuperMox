"""A minimal RFC 6455 WebSocket client on the standard library.

Used for the node shell and the container console (see ops/terminal.py).
There is no websocket package on the target, so this module is written from
the RFC: an upgrade handshake whose Sec-WebSocket-Accept is verified, masked
client frames (RFC 6455 requires clients to mask), unmasked frames from the
server, 7/16/64-bit payload lengths, text, binary, ping, pong and close, and
fragmented messages reassembled before the caller sees them.

Security: the connection is made with api.pinned_socket(), so the leaf
certificate's SHA256 is verified on the real connection before the session
cookie is written. A pin mismatch never sends the cookie.
"""

import base64
import hashlib
import os
import threading

from supermox_manager import api

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 16 * 1024 * 1024
CHUNK = 4096


class WebSocketError(Exception):
    """A safe, user-facing handshake, framing or connection failure."""


def accept_token(key):
    """The Sec-WebSocket-Accept value a server must answer for ``key``."""
    return base64.b64encode(hashlib.sha1(
        (key + GUID).encode("ascii")).digest()).decode("ascii")


def mask(payload, key):
    """XOR a payload with the 4-byte frame key (RFC 6455 client masking)."""
    return bytes(byte ^ key[index & 3] for index, byte in enumerate(payload))


def encode_frame(payload, opcode=0x2, mask_key=None, continuation=False):
    """One frame: FIN/opcode, payload length, optional client masking.

    ``payload`` is sent unmodified; ``mask_key`` is None for a random key
    (client frames are always masked), pass ``b""`` for an unmasked frame.
    """
    payload = bytes(payload)
    if len(payload) > MAX_FRAME:
        raise WebSocketError("Message is too large for one frame.")
    masked = mask_key != b""
    if masked:
        key = mask_key or os.urandom(4)
        data = mask(payload, key)
        flag = 0x80
    else:
        key, data, flag = b"", payload, 0x00
    first = 0x00 if continuation else 0x80
    length = len(data)
    if length < 126:
        head = bytes([first | opcode, flag | length])
    elif length < 0x10000:
        head = bytes([first | opcode, flag | 126]) + length.to_bytes(2, "big")
    else:
        head = bytes([first | opcode, flag | 127]) + length.to_bytes(8, "big")
    return head + (key if masked else b"") + data


def split_frames(payload, opcode=0x2, size=CHUNK):
    """Split a message into frames of at most ``size`` payload bytes.

    The first frame carries the opcode, the rest are continuation frames
    (opcode 0, FIN clear), so the receiver reassembles one message.
    """
    payload = bytes(payload)
    if not payload:
        return [encode_frame(b"", opcode, os.urandom(4))]
    parts = [payload[offset:offset + size]
             for offset in range(0, len(payload), size)]
    frames = []
    for index, part in enumerate(parts):
        frames.append(encode_frame(part, opcode if not index else 0x0,
                                   os.urandom(4),
                                   continuation=index < len(parts) - 1))
    return frames


class FrameDecoder:
    """Turn a byte stream into whole messages: (opcode, payload)."""

    def __init__(self, read, send_frame=None):
        self._read = read
        self._send_frame = send_frame

    def _read_exact(self, count):
        parts = []
        while count > 0:
            chunk = self._read(count)
            if not chunk:
                raise WebSocketError("The connection closed without a message.")
            parts.append(chunk)
            count -= len(chunk)
        return b"".join(parts)

    def frame(self):
        """Read one frame. Server frames must not be masked (RFC 6455)."""
        head = self._read_exact(2)
        finished = bool(head[0] & 0x80)
        opcode = head[0] & 0x0F
        if head[1] & 0x80:
            raise WebSocketError("The node masked a server frame.")
        length = head[1] & 0x7F
        if length == 126:
            length = int.from_bytes(self._read_exact(2), "big")
        elif length == 127:
            length = int.from_bytes(self._read_exact(8), "big")
        if not 0 <= length <= MAX_FRAME:
            raise WebSocketError("The node sent an oversized frame.")
        return opcode, self._read_exact(length), finished

    def message(self):
        """Return one application message, reassembling fragments.

        Ping frames are answered with a pong here, close frames end the
        connection, and control frames may appear between fragments.
        """
        parts = []
        opcode = None
        while True:
            frame_opcode, payload, finished = self.frame()
            if frame_opcode in (0x7, 0x8, 0x9):
                if not finished:
                    raise WebSocketError("The node fragmented a control frame.")
                if frame_opcode == 0x8:
                    raise WebSocketError("The node closed the connection.")
                if frame_opcode == 0x9 and self._send_frame:
                    self._send_frame(encode_frame(payload, 0xA, os.urandom(4)))
                continue
            if frame_opcode == 0xA:
                continue
            if frame_opcode in (0x1, 0x2):
                if opcode is not None:
                    raise WebSocketError("The node interleaved data frames.")
                opcode = frame_opcode
            elif frame_opcode != 0x0 or opcode is None:
                raise WebSocketError("The node sent an unexpected frame.")
            parts.append(payload)
            if finished:
                return opcode, b"".join(parts)


class WebSocket:
    """A connected websocket: send(), recv(), ping(), close()."""

    def __init__(self, sock, timeout=15):
        self._sock = sock
        self._lock = threading.Lock()
        self._decoder = FrameDecoder(sock.recv, self._write_frame)
        self.closed = False

    def _write_frame(self, frame):
        with self._lock:
            self._sock.sendall(frame)

    def send(self, data, opcode=0x2, chunk=0):
        """Send ``data`` as one message; ``chunk`` splits it into frames."""
        data = bytes(data)
        if chunk:
            for frame in split_frames(data, opcode, chunk):
                self._write_frame(frame)
            return
        self._write_frame(encode_frame(data, opcode, os.urandom(4)))

    def send_text(self, text):
        """Send ``text`` as one UTF-8 text frame (what a browser sends)."""
        self.send(text.encode("utf-8"), opcode=0x1)

    def ping(self, data=b"supermox"):
        self.send(data, opcode=0x9)

    def recv(self):
        """Wait for the next application message (blocks)."""
        return self._decoder.message()

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self._write_frame(encode_frame(b"", 0x8, os.urandom(4)))
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


def connect(host, port, path, pin, cookie=None, timeout=15, subprotocol="binary",
            extra_headers=()):
    """Open a websocket to ``host:port`` + ``path``, pinned to ``pin``.

    The TLS certificate is verified before the cookie is written, the
    handshake response must be an upgrade whose Sec-WebSocket-Accept matches
    our key, and the negotiated subprotocol must be the one we asked for.
    """
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    sock = api.pinned_socket(host, port, pin, timeout)
    lines = ["GET {} HTTP/1.1".format(path),
             "Host: {}:{}".format(host, port),
             "Upgrade: websocket",
             "Connection: Upgrade",
             "Sec-WebSocket-Key: " + key,
             "Sec-WebSocket-Version: 13"]
    if subprotocol:
        lines.append("Sec-WebSocket-Protocol: " + subprotocol)
    if cookie:
        lines.append("Cookie: " + cookie)
    lines.extend(extra_headers)
    try:
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("ascii"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1)
            if not chunk:
                raise WebSocketError("The node closed the handshake.")
            head += chunk
            if len(head) > 65536:
                raise WebSocketError("The handshake response was too large.")
        status = head.split(b"\r\n", 1)[0]
        fields = {}
        for line in head.split(b"\r\n")[1:]:
            name, _, value = line.partition(b":")
            fields[name.decode("latin-1").lower().strip()] = value.decode("latin-1").strip()
        if b" 101" not in status:
            raise WebSocketError("The node refused the websocket (HTTP {})."
                                 .format(status.split()[-1] if len(status.split()) > 1 else "?"))
        if fields.get("upgrade", "").lower() != "websocket":
            raise WebSocketError("The node did not upgrade the connection.")
        if fields.get("sec-websocket-accept") != accept_token(key):
            raise WebSocketError("The websocket handshake key was not accepted.")
        if subprotocol and fields.get("sec-websocket-protocol", "") != subprotocol:
            raise WebSocketError("The node did not negotiate the binary subprotocol.")
    except Exception:
        sock.close()
        raise
    return WebSocket(sock, timeout)
