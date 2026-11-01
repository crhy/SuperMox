"""The cluster page: quorum, nodes, the cluster log, datacenter options.

Measured against the running node (see .strata/notes-t78-manager-cluster.md):

* ``GET /cluster/status`` returns two kinds of row: one with ``type="cluster"``
  (``name``, ``nodes``, ``quorate``, ``version``) and one per node
  (``name``, ``ip``, ``local``, ``online``, ``nodeid``). The quorum banner reads
  the cluster row; the nodes table reads the node rows. ``level`` comes back
  empty on a one-node cluster, so it is not shown.
* ``GET /cluster/log`` and ``GET /cluster/tasks`` accept no ``limit``
  ("Unknown option: limit"), so ``ops.cluster.log`` slices after fetching.
  Log ``time`` is an epoch number and ``pri`` is a syslog level number.
* ``GET /cluster/options`` returns only what was ever set (fresh node:
  ``allowed-tags``, ``description``, ``mac_prefix``), while
  ``PUT /cluster/options`` accepts 21 names. Hash-valued options travel as
  plain strings: ``{"migration": "secure"}`` is accepted, a JSON object is
  refused with "Check fields: migration". ``delete`` names options to unset,
  which is how a value goes back to the node's own default.
* ``pvesh create /cluster/config/join`` needs a fingerprint and a shared
  secret, and on a node already in a cluster it fails with
  "Check if node may join a cluster failed!". SuperMox joins nodes with
  ``supermox-join`` instead (see the "Add a node" tab), and this page never
  shows ``pve_fp`` or ``config_digest`` from ``/cluster/config/join``.
"""

import threading

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from ._view import clear, deliver, table
from ..ops import cluster
from ..ops import terminal

TITLE = "Cluster"
SUBTITLE = ("Quorum, nodes, the cluster log, datacenter options, and how "
            "SuperMox adds a node")
TABS = ("Status", "Log", "Options", "Add a node")

# The join commands, copied from bin/supermox-join's own help output.
JOIN_STEPS = (
    ("A node already in the cluster invites a new one:",
     "supermox-join invite --ttl 900 --png invite.png\n"
     "The QR code is single-use and lasts 15 minutes; it never carries the phrase."),
    ("The node that wants to join runs:",
     "supermox-join join --name <name> --endpoint <host> --words <12 words>\n"
     "or scans the QR invite. The 12-word phrase is typed by hand: this page "
     "never stores or shows it."),
    ("To see this node's view of the cluster:",
     "supermox-join members"),
)

# Typed into the node shell by the "Open node shell" button. Read-only, so
# pre-filling it is safe; `join` and `invite` are not, because they carry the
# cluster phrase.
SHELL_COMMAND = "supermox-join members"


def _status_rows(manager, box, rows):
    """Quorum banner and the node rows of GET /cluster/status."""
    head = cluster.cluster_row(rows)
    nodes = cluster.node_rows(rows)
    manager.cluster_local = next((row.get("name") for row in nodes if row.get("local")), None)
    if head is None:
        box.pack_start(Gtk.Label(label="This node answers with no cluster row: "
                                       "it is not in a cluster.", wrap=True), False, False, 6)
        return
    online = len([row for row in nodes if row.get("online")])
    total = int(head.get("nodes") or len(nodes))
    quorate = bool(head.get("quorate"))
    word = "node" if total == 1 else "nodes"
    banner = Gtk.Label(label="{} — {} of {} {} online, {}".format(
        head.get("name") or "cluster", online, total, word,
        "quorate" if quorate else "NOT quorate"), wrap=True)
    banner.get_style_context().add_class("brand" if quorate else "status")
    box.pack_start(banner, False, False, 6)
    if total < 2:
        box.pack_start(Gtk.Label(label=(
            "One node only: cluster-wide failover and HA are not in effect until a second "
            "node joins. The Add a node tab shows the SuperMox join commands."), wrap=True),
            False, False, 4)
    table(box, ("Node", "Online", "This node", "Address"),
          [[row.get("name", ""), "yes" if row.get("online") else "no",
            "this node" if row.get("local") else "", row.get("ip", "")]
           for row in nodes])


def _log_rows(manager, box, rows):
    """Newest entries of GET /cluster/log."""
    if not rows:
        box.pack_start(Gtk.Label(label="The cluster log is empty."), False, False, 6)
        return
    size = getattr(manager, "cluster_log_size", 0) or len(rows)
    if len(rows) < size:
        head = "{} newest of {} entries, newest first — the endpoint has no " \
               "limit parameter, so the Manager slices the answer".format(len(rows), size)
    else:
        head = "{} entries, newest first — the endpoint has no limit parameter".format(size)
    box.pack_start(Gtk.Label(label=head, wrap=True), False, False, 4)
    table(box, ("Time", "Node", "Level", "Message"),
          [[cluster.log_time(row), row.get("node", ""),
            cluster.LEVEL_NAMES.get(int(row.get("pri") or 0), ""),
            row.get("msg", "").strip()]
           for row in rows])


def _options_rows(manager, box, record):
    """Current datacenter options: only what was ever set comes back."""
    manager.cluster_options = record if isinstance(record, dict) else {}
    if not manager.cluster_options:
        box.pack_start(Gtk.Label(label="No datacenter options are set: every value "
                                       "is the node's own default."), False, False, 6)
        return
    word = "option" if len(record) == 1 else "options"
    box.pack_start(Gtk.Label(label="{} datacenter {} the node reports; anything not "
                                   "listed keeps its default.".format(len(record), word),
                            wrap=True), False, False, 4)
    table(box, ("Option", "Value"),
          [[name, _json_value(value)] for name, value in sorted(record.items())])


def _json_value(value):
    """How a hash, list or empty option shows in the table."""
    if isinstance(value, dict):
        return str(value.get("type", "")) or "not set"
    if isinstance(value, list):
        return ", ".join(str(item) for item in value) or "none"
    if value in ("", None):
        return "not set"
    return str(value)


def _change_options(manager):
    """PUT /cluster/options with the fields the user filled in."""
    if manager.demo:
        manager.message("Preview mode", "Restart without --demo to change datacenter options.")
        return
    current = getattr(manager, "cluster_options", {})
    values = manager.form(
        "Change datacenter options",
        [("description", "Description", cluster.option_text("description", current), False),
         ("console", "Console", cluster.option_text("console", current), False),
         ("keyboard", "Keyboard", cluster.option_text("keyboard", current), False),
         ("language", "Language", cluster.option_text("language", current), False),
         ("migration", "Migration", cluster.option_text("migration", current), False)],
        submit="Apply",
        note="Leave a field empty to keep it as it is. Console, keyboard, language and "
             "migration take one value from the list the node itself accepts.")
    if values is None:
        return
    fields = {key: value.strip() for key, value in values.items() if value.strip()}
    if not fields:
        manager.message("Nothing to change", "Every field was left empty.")
        return
    client = manager.client
    manager.work(lambda: cluster.set_options(client, **fields),
                 lambda answer: _options_reload(manager))


def _reset_options(manager):
    """PUT /cluster/options --delete: back to the node's own defaults."""
    if manager.demo:
        manager.message("Preview mode", "Restart without --demo to reset datacenter options.")
        return
    names = ",".join(sorted(getattr(manager, "cluster_options", {})))
    if not names:
        manager.message("Nothing to reset", "No datacenter options are set.")
        return
    if not manager.confirm("Reset datacenter options",
                           "Remove {} so the node uses its own defaults again.".format(names)):
        return
    client = manager.client
    manager.work(lambda: cluster.set_options(client, delete=names),
                 lambda answer: _options_reload(manager))


def _options_reload(manager):
    _load_options(manager, manager.cluster_results["Options"])


def _load_status(manager, results):
    manager.work(lambda: cluster.status(manager.client),
                 deliver(manager, "cluster_results", TITLE, "Status", _status_rows))


def _load_log(manager, results):
    """GET /cluster/log has no limit: keep the size, show the newest entries."""
    def operation():
        rows = cluster.log(manager.client)
        manager.cluster_log_size = len(rows)
        return rows

    manager.work(operation, deliver(manager, "cluster_results", TITLE, "Log", _log_rows))


def _load_options(manager, results):
    manager.work(lambda: cluster.options(manager.client),
                 deliver(manager, "cluster_results", TITLE, "Options", _options_rows))


def _join_rows(manager, box, rows):
    """The SuperMox join path, as text (delivered so the tab paints once)."""
    clear(box)
    del rows
    box.pack_start(Gtk.Label(label=(
        "SuperMox does not use pvesh create /cluster/config/join: that call needs a "
        "fingerprint and a shared secret, and on a node that is already in a cluster the "
        "node answers \u201cCheck if node may join a cluster failed!\u201d. Nodes join with "
        "supermox-join, which carries a 12-word phrase (128 bits plus a checksum) through "
        "the QR invite or the terminal. This page never shows the fingerprint or the "
        "config digest."), wrap=True), False, False, 6)
    for title, text in JOIN_STEPS:
        box.pack_start(Gtk.Label(label=title, wrap=True), False, False, 0)
        command = Gtk.Label(label=text, xalign=0, yalign=0, wrap=True)
        command.get_style_context().add_class("preview")
        box.pack_start(command, False, False, 6)


def _open_shell(manager):
    """Open the t70 node shell with SHELL_COMMAND typed at the prompt, not run."""
    if manager.demo:
        manager.message("Preview mode", "Restart without --demo to open a node shell.")
        return
    node = getattr(manager, "cluster_local", None)
    if not node:
        manager.message("No node selected",
                        "Open the Status tab first: it names this node.")
        return
    client = manager.client
    manager.work(lambda: terminal.open_session(client, node),
                 lambda session: _shell_window(manager, session, node))


def _shell_window(manager, session, node):
    """A node shell window: the command sits at the prompt until Enter runs it.

    Keystrokes go through the same termproxy session the web console uses
    (ops/terminal.py, t70). The command is sent without a newline, so the
    shell echoes it and waits; Enter in the field sends the newline.
    """
    from ..app import box, label
    window = Gtk.Window(title="{} — node shell".format(node))
    window.set_transient(True)
    window.set_default_size(820, 480)
    state = {"closed": False}
    window.connect("close", lambda widget: (state.update(closed=True), session.close()))
    window.connect("destroy", lambda widget: state.update(closed=True))
    area = box(True, 8, 12)
    window.add(area)
    area.pack_start(label("The command below is typed at the prompt, not run. "
                          "Press Enter in the field to run it, or type to add "
                          "to the line.", "subtitle"), False, False, 0)
    entry = Gtk.Entry()
    entry.set_hexpand(True)
    entry.set_text(SHELL_COMMAND)
    entry.connect("activate", lambda widget: _run(session))
    entry.connect("key-press", lambda widget, event: _control_c(session, event))
    area.pack_start(entry, False, False, 0)
    transcript = Gtk.TextView(editable=False, cursor_visible=False, monospace=True)
    transcript.set_hexpand(True)
    transcript.set_vexpand(True)
    frame = Gtk.Frame()
    frame.add(transcript)
    area.pack_start(frame, True, True, 0)
    window.show_all()
    session.resize(80, 24)
    threading.Thread(target=_pump, args=(session, transcript, state), daemon=True).start()


def _run(session):
    """Enter in the field: one newline, so the shell runs the line."""
    try:
        session.send("\n")
    except Exception:  # noqa: BLE001 - a dead session shows up in the transcript
        pass


def _control_c(session, event):
    """Ctrl+C drops the typed line without running it."""
    if event.is_action() and event.get_key_code() in (0x63, 0x43):
        try:
            session.send("\x03")
        except Exception:  # noqa: BLE001 - a dead session shows up in the transcript
            pass
    return False


def _pump(session, transcript, state):
    """Copy terminal bytes into the window until either side closes."""
    while not state["closed"]:
        try:
            data = session.recv(timeout=0.5)
        except Exception:  # noqa: BLE001 - a dead session ends the loop
            data = None
        if data is None:
            return
        if data:
            GLib.idle_add(_append, transcript, terminal.readable(data))


def _append(transcript, data):
    if transcript.get_parent() is None:
        return False
    buffer = transcript.get_buffer()
    buffer.insert_text(buffer.get_end(), data)
    return False


def render(manager, content):
    from ..app import button
    clear(content)
    manager.cluster_results = {}
    manager.cluster_options = {}
    manager.cluster_log_size = 0
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
    for name in TABS:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        page.set_hexpand(True)
        page.set_vexpand(True)
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        results.set_hexpand(True)
        results.set_vexpand(True)
        manager.cluster_results[name] = results
        if name == "Status":
            actions.pack_start(button("Reload", lambda *_: _load_status(manager, results)), False, False, 0)
        elif name == "Log":
            actions.pack_start(button("Reload", lambda *_: _load_log(manager, results)), False, False, 0)
        elif name == "Options":
            actions.pack_start(button("Reload", lambda *_: _load_options(manager, results)), False, False, 0)
            actions.pack_start(button("Change", lambda *_: _change_options(manager)), False, False, 0)
            actions.pack_start(button("Reset to defaults", lambda *_: _reset_options(manager)), False, False, 0)
        else:
            _join_rows(manager, results, None)
            actions.pack_start(button("Open node shell", lambda *_: _open_shell(manager)), False, False, 0)
        page.pack_start(actions, False, False, 0)
        page.pack_start(results, True, True, 0)
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
