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
import re
import socket
import threading
import time

from .. import api
from . import websocket

# Keystrokes travel as one frame per chunk; the web console sends one frame
# per xterm.js data event, so a bounded chunk size keeps both sides happy.
CHUNK = 4096
KEEPALIVE_SECONDS = 30

# One command typed into a shell comes back mixed with the prompt, the echo
# of the line that was typed and the next prompt. Two markers around it are
# what the output between can be found by; they are the ones the cluster page
# uses (see .strata/c08-manager-cluster-actions.md).
BEGIN_MARK = "SMXJSON-BEGIN"
END_MARK = "SMXJSON-END"
MARK_PREFIX = "SMXJSON-"

# Reading a node's JSON is quick; `supermox-join core` asks pvesh and then
# upstream's finish_join, so the caller that runs it passes its own timeout.
COMMAND_TIMEOUT = 30

# A fresh ssh session prints its banner before it opens a prompt; the wait for
# that prompt is bounded so a session that never prompts cannot hang a page.
PROMPT_WAIT = 10


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

def hidden(mark):
    """A marker spelled so the shell's echo of the typed line is not a marker.

    ``SMXJSON-""BEGIN``: the terminal echoes those characters back as typed,
    which is not ``SMXJSON-BEGIN``; the shell joins the empty word to its
    neighbours and prints the real marker. This is what keeps the echoed
    command line from looking like a complete pair of markers.
    """
    return '{}""{}'.format(MARK_PREFIX, mark[len(MARK_PREFIX):])


def wrap_command(command):
    """One shell line whose output can be found between two markers.

    ``echo SMXJSON-""BEGIN; <command>; echo SMXJSON-""END``: the shell echoes
    the whole line back, and that echo would otherwise put both markers on one
    line, a pair command_region() would mistake for the answer. hidden() breaks
    the echo while still printing the real markers, so the only pair in the
    stream is the real one, and the output that matters is between them. A
    command that fails still prints its end marker, because the shell runs the
    next statement after a semicolon.
    """
    return "echo {}; {}; echo {}".format(hidden(BEGIN_MARK), command,
                                         hidden(END_MARK))


def command_region(data):
    """The text between the markers, or None while the end marker is missing.

    ``data`` is the whole byte stream of the session so far, so a marker split
    across two messages is still found. Returns None when the command has not
    finished (or the markers were never printed), which is how run_command()
    knows to keep waiting.
    """
    text = readable(data)
    start = text.rfind(BEGIN_MARK)
    if start < 0:
        return None
    end = text.find(END_MARK, start + len(BEGIN_MARK))
    if end < 0:
        return None
    return text[start + len(BEGIN_MARK):end].strip()


def await_prompt(session, limit=PROMPT_WAIT):
    """Wait until the shell has printed its prompt, and return what it said.

    A fresh ssh terminal prints its banner first and only then opens a prompt. A
    command typed before that prompt is eaten by the shell's own start-up, so the
    markers never appear and the caller sees the echoed command line instead of
    the answer. The prompt is the end of the line: it finishes with ``#`` or
    ``$`` (the trailing space is stripped before the test). Returns whatever
    came back when the prompt appeared or the wait ran out, so a session that
    never prompts still reaches the caller.
    """
    collected = bytearray()
    deadline = time.monotonic() + max(1, int(limit))
    while time.monotonic() < deadline:
        data = session.recv(timeout=0.2)
        if data is None:
            break
        if data:
            collected.extend(data)
            if readable(bytes(collected)).rstrip().endswith(("#", "$")):
                return bytes(collected)
    return bytes(collected)


def run_command(client, node, command, timeout=COMMAND_TIMEOUT, cols=100, rows=30):
    """Open a node shell, type ONE command, and return its output as text.

    The session is opened and closed by this call: the page never leaves a
    shell behind. The command is typed as one line and Enter is sent with it,
    so there is no half-typed line for the user to finish. The answer is the
    text between the markers, which is the command's own output: its stdout
    and its stderr, since a terminal sends both to the same place. When the
    markers never appear (the session died, or the command is still running
    at the timeout) everything that did come back is returned instead, so the
    caller can show the raw text rather than nothing.
    """
    session = open_session(client, node)
    try:
        session.resize(cols, rows)
        await_prompt(session)
        session.send(wrap_command(command) + "\n")
        collected = bytearray()
        deadline = time.monotonic() + max(1, int(timeout))
        while True:
            data = session.recv(timeout=1)
            if data is None:
                break
            if data:
                collected.extend(data)
                if command_region(bytes(collected)) is not None:
                    return command_region(bytes(collected))
            if time.monotonic() >= deadline:
                break
        region = command_region(bytes(collected))
        return region if region is not None else readable(bytes(collected))
    finally:
        session.close()


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


# The node sends raw terminal bytes: colours, cursor moves, the prompt's own
# control characters. A TextView shows none of that, so only printable text
# and line breaks are kept.
_ANSI_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"                       # CSI: colours, moves
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"          # OSC: title, hyperlinks
    r"|(\x1b[PX^_][ -~]*\x1b\\)"                     # DCS: passthrough
    r"|\x1b[()#][0-9A-B]"                        # charset designator
    r"|\x1b.")                                     # any other escape
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def readable(data):
    """Turn terminal bytes into text a window can display.

    Escape sequences are dropped whole (a colour change must not leave its
    letters behind), CR and CRLF both become one line break, and the
    remaining control characters are removed. Bytes are decoded with
    'replace' so a split multi-byte character never kills the transcript.
    """
    if isinstance(data, bytes):
        data = data.decode("utf-8", "replace")
    text = _ANSI_RE.sub("", data)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return _CONTROL_RE.sub("", text)
