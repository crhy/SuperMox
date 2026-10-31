"""Interactive terminal sessions for SuperMox Manager (no Gtk import).

A session is two calls on the same node, exactly as the web console does:

  1. POST ``/nodes/{node}/termproxy`` (node shell) or
     ``/nodes/{node}/{kind}/{vmid}/termproxy`` (guest console) ->
     ``{port, ticket, user, upid}``
  2. a websocket to ``{same path}/vncwebsocket?port={port}&vncticket={ticket}``
     with the session cookie and the ``binary`` subprotocol.

Wire framing (read from the node's /usr/share/pve-xtermjs/main.js and the
proxmox-termproxy binary, see .strata/notes-t70-manager-terminal.md):

  client -> server, one text frame each:
      "<user>:<ticket>\\n"  handshake, the node answers "OK"
      "0:<len>:<data>"      keystrokes, <len> is the BYTE length of <data>
      "1:<cols>:<rows>:"    terminal size
      "2"                   keepalive, sent every 30 seconds
  server -> client: raw terminal bytes (ANSI escapes), first message "OK..."

The websocket is opened by ops/websocket.connect(), which reuses
api.pinned_socket(): the leaf certificate's SHA256 is verified on the real
connection before the session cookie is written.
"""

import queue
import socket
import threading

from .. import api
from . import websocket

# Keystrokes travel as one frame per chunk; the web console sends one frame
# per xterm.js data event, so a bounded chunk size keeps both sides happy.
CHUNK = 4096
KEEPALIVE_SECONDS = 30


class Session:
    """One live terminal session: send keystrokes, receive terminal bytes."""

    def __init__(self, ws, node, vmid=None, kind="ssh", initial=b""):
        self.node = node
        self.vmid = vmid
        self.kind = kind
        self._ws = ws
        self._messages = queue.Queue()
        self._ended = False
        self._stop = threading.Event()
        if initial:
            self._messages.put(initial)
        self._reader = threading.Thread(target=self._pump, name="terminal-reader")
        self._reader.daemon = True
        self._reader.start()
        self._ticker = threading.Thread(target=self._keepalive,
                                        name="terminal-keepalive")
        self._ticker.daemon = True
        self._ticker.start()

    @property
    def alive(self):
        """False once the session ended (socket closed or handshake refused)."""
        return not self._ended and not self._ws.closed

    def send(self, data):
        """Send keystrokes; ``data`` is str (encoded UTF-8) or bytes.

        Input is split into chunks of at most CHUNK bytes, each chunk sent
        as its own ``0:<len>:<data>`` frame, in order, so a large paste
        never overflows the frame limit or arrives reordered.
        """
        for chunk in self._chunks(data):
            self._send_frame(b"0:%d:" % len(chunk) + chunk)

    def resize(self, cols, rows):
        """Tell the node the terminal size (``1:<cols>:<rows>:``)."""
        self._send_frame("1:{}:{}:".format(int(cols), int(rows)).encode("ascii"))

    def recv(self, timeout=None):
        """Return the next bytes of terminal output.

        Returns b"" when the wait timed out and None once the session has
        ended and no output is left, so callers can tell "quiet" from "gone".
        """
        try:
            data = self._messages.get(timeout=timeout)
        except queue.Empty:
            return b""
        if data is None:
            self._ended = True
            return None
        return data

    def close(self):
        """Close the websocket; safe to call more than once."""
        if not self._stop.is_set():
            self._stop.set()
            self._ws.close()

    @property
    def closed(self):
        return self._stop.is_set()

    def _send_frame(self, payload):
        """One message per call, as a text frame of exactly these bytes."""
        if self._stop.is_set():
            raise api.APIError("This terminal session is closed.")
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        self._ws.send(payload, opcode=0x1)

    def _pump(self):
        while True:
            try:
                _, payload = self._ws.recv()
            except socket.timeout:
                continue  # quiet session: no message in flight
            except (websocket.WebSocketError, OSError):
                break
            self._messages.put(payload)
        self._ended = True
        self._messages.put(None)

    def _keepalive(self):
        while not self._stop.wait(KEEPALIVE_SECONDS):
            try:
                self._send_frame("2")
            except Exception:  # noqa: BLE001 - the reader reports the failure
                return

    @staticmethod
    def _chunks(data):
        """Split into chunks of at most CHUNK bytes, never inside a UTF-8
        character, so a large paste keeps its byte order and its characters.
        """
        if isinstance(data, str):
            data = data.encode("utf-8")
        out = []
        offset = 0
        while offset < len(data):
            end = min(offset + CHUNK, len(data))
            while end < len(data) and (data[end] & 0xC0) == 0x80:
                end -= 1  # back off to a character boundary
            out.append(data[offset:end])
            offset = end
        return out


def open_session(client, node, vmid=None, kind="ssh"):
    """Open a terminal session on a node and return a Session.

    ``kind="ssh"`` gives a shell on the node itself (``vmid`` must be None);
    ``kind="lxc"`` or ``kind="qemu"`` opens that guest's console.
    """
    base = _base_path(node, vmid, kind)
    proxy = client.request("POST", base + "/termproxy")
    if not isinstance(proxy, dict):
        raise api.APIError("The node did not return a terminal session.")
    port, ticket = proxy.get("port"), proxy.get("ticket")
    user = proxy.get("user") or client.username
    if not port or not ticket:
        raise api.APIError("The node did not return a terminal session.")
    path = "{}/vncwebsocket?port={}&vncticket={}".format(
        base, int(port), api.quote(ticket, safe=""))
    ws = websocket.connect(client.host, client.port, "/api2/json" + path,
                           client.pin,
                           cookie="PVEAuthCookie=" + api.quote(
                               client.ticket, safe=""),
                           timeout=client.timeout, subprotocol="binary")
    ws.send("{}:{}\n".format(user, ticket).encode("utf-8"), opcode=0x1)
    try:
        _, answer = ws.recv()
    except (websocket.WebSocketError, OSError) as exc:
        ws.close()
        raise api.APIError("The node refused the terminal session: {}"
                           .format(type(exc).__name__)) from None
    if not answer.startswith(b"OK"):
        ws.close()
        raise api.APIError("The node refused the terminal session.")
    return Session(ws, node, vmid=vmid, kind=kind, initial=answer[2:])


def _base_path(node, vmid, kind):
    if kind == "ssh":
        if vmid is not None:
            raise ValueError("A node shell does not take a guest id.")
        return "/nodes/{}".format(api.segment(node))
    if kind not in ("lxc", "qemu"):
        raise ValueError("Unknown terminal kind: {}.".format(kind))
    if vmid is None:
        raise ValueError("A guest console needs a vmid.")
    return "/nodes/{}/{}/{}".format(api.segment(node), api.segment(kind),
                                     api.segment(str(vmid)))

def paste_lines(text):
    """Number of lines a clipboard paste would type into the terminal.

    CRLF and lone CR count as one break; a single trailing newline does not
    add a line; an empty or whitespace-only clipboard pastes nothing (0).
    """
    if not text or not text.strip():
        return 0
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if text.endswith("\n"):
        text = text[:-1]
    return len(text.split("\n"))


def one_line(text):
    """Join a multi-line selection into one line (newlines become spaces).

    Used by "Copy as one line" and "Paste as one line": the text is
    normalised so it can be typed as a single command without executing
    the pasted lines one by one.
    """
    return " ".join(text.split())
