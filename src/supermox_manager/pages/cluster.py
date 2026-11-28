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
  ``supermox-join``, which has no API of its own: the state lives in
  ``/etc/supermox`` and only that command reads it. So the Members, Join
  requests and Add a node tabs run one command in a node shell and show its
  raw output (see ``ops.cluster`` and ``ops.terminal.run_command``). This page
  never shows ``pve_fp`` or ``config_digest`` from ``/cluster/config/join``,
  and never shows the 12-word phrase: ``create`` prints it once, in the
  terminal output the page quotes.
"""

import threading

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from ._view import clear, deliver, table
from ..ops import cluster
from ..ops import terminal

TITLE = "Cluster"
SUBTITLE = ("Quorum, nodes, the cluster log, datacenter options, and the "
            "SuperMox cluster: its members, its join requests, its actions")
TABS = ("Status", "Log", "Options", "Members", "Join requests", "Add a node")

# Typed into the node shell by the "Open node shell" button. Read-only, so
# pre-filling it is safe; `join` and `invite` are not, because they carry the
# cluster phrase. The other buttons on this page run their command instead of
# pre-filling it, and show what came back.
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
            "node joins. The Add a node tab creates the cluster and invites one."), wrap=True),
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


# --- the cluster's own actions, run in a node shell (c08) -------------------
#
# The Manager has no API for SuperMox's join state: it lives in /etc/supermox
# and only `supermox-join` reads it. So every action here is ONE command typed
# into a node shell (ops/terminal.run_command) and its output shown as it came
# back. ops/cluster.py builds the command strings and parses the answers, so
# the offline tests can pin both without GTK.

# Reading is quick. `create`, `core` and `cluster-init` wait on pvesh and, for
# core, on upstream's finish_join, so they get the longer budget.
READ_TIMEOUT = 30
WRITE_TIMEOUT = 180


def _local_node(manager):
    """This node's name, or None with a message when the Status tab is closed."""
    node = getattr(manager, "cluster_local", None)
    if not node:
        manager.message("No node selected",
                        "Open the Status tab first: it names this node.")
    return node


def _shell(manager, command, builder, tab, timeout=READ_TIMEOUT, node=None):
    """Type ONE command into a node shell and paint its answer into a tab.

    The command is shown before it runs, so the user always knows what was
    typed; the answer replaces the tab's contents, raw, whether or not it
    parses. `node` names whose shell it is: this node's by default, another
    member's when the action has to run there.
    """
    node = node or _local_node(manager)
    if not node:
        return
    if manager.demo:
        manager.message("Preview mode",
                        "Restart without --demo to run commands on a node.")
        return
    client = manager.client
    manager.work(lambda: cluster.run_shell(client, node, command, timeout=timeout),
                 deliver(manager, "cluster_results", TITLE, tab, builder))


def _command_line(manager, box, command):
    """The command that is about to run, as text (delivered so the tab paints)."""
    clear(box)
    box.pack_start(Gtk.Label(label="Running this command in {}'s shell:".format(
        getattr(manager, "cluster_local", "the node")), wrap=True), False, False, 4)
    line = Gtk.Label(label=command, xalign=0, yalign=0, wrap=True)
    line.get_style_context().add_class("preview")
    box.pack_start(line, False, False, 0)
    box.show_all()


def _output_rows(manager, box, text):
    """Raw shell output: what the command printed, nothing hidden."""
    clear(box)
    box.pack_start(Gtk.Label(label="The command's output, as it came back:",
                             wrap=True), False, False, 4)
    body = Gtk.Label(label=text.strip() if text and text.strip() else
                     "(the command printed nothing)", xalign=0, yalign=0, wrap=True)
    body.get_style_context().add_class("preview")
    box.pack_start(body, False, False, 0)
    box.show_all()


def _created_rows(manager, box, text):
    """The output of `supermox-join create`, plus what to do with the words."""
    _output_rows(manager, box, text)
    warning = Gtk.Label(xalign=0)
    warning.set_line_wrap(True)
    warning.set_max_width_chars(72)
    warning.set_markup(
        "<b>The 12 words are printed once, by the command above, and never "
        "again.</b> Write them down now: they are the only copy, and the node "
        "that joins has to be given them. This page never stores or shows them "
        "itself.")
    box.pack_start(warning, False, False, 6)
    box.show_all()


def _draw_members(manager, box):
    """The member table, plus the nodelist line once the probe has answered.

    The probe redraws this table, so the member double-clicked for Make core
    stays selected by name: the row widget is new, the choice is not.
    """
    if not manager.cluster_members:
        box.pack_start(Gtk.Label(label=(
            "This node knows no members: no cluster has been created here yet. "
            "The Add a node tab creates one."), wrap=True), False, False, 6)
        return
    box.pack_start(Gtk.Label(label=(
        "{} member(s). Double-click a row to select it for Make core.".format(
            len(manager.cluster_members))), wrap=True), False, False, 4)

    def pick(view, path, _column):
        """Double-click a member row: it becomes the Make core target."""
        members = getattr(manager, "cluster_members", [])
        try:
            index = int(path.get_indices()[0])
        except (AttributeError, IndexError, ValueError):
            return
        if 0 <= index < len(members):
            manager.cluster_selected = members[index]
            _update_actions(manager)

    table(box, ("Member", "Role", "Corosync", "Arch", "Overlay", "Features"),
          [[row.get("name", ""), row.get("role", ""),
            "core" if row.get("core") else "edge",
            row.get("arch", ""), row.get("overlay_addr", ""),
            ", ".join(str(item) for item in row.get("caps") or ())]
           for row in manager.cluster_members],
          select=pick)
    if manager.cluster_managed is not None:
        box.pack_start(Gtk.Label(label=(
            "Nodelist managed by supermox-join: {}.".format(
                "yes" if manager.cluster_managed else
                "no, so the Upgrade button below repairs it")), wrap=True),
            False, False, 4)


def _members_answer(manager, box, text):
    """Members: the table when the answer parses, its raw text when it does not.

    A command that failed is exactly when the raw text is the answer, so it is
    shown as is; the member state is left as it was rather than guessed at, and
    the buttons keep the state they had.
    """
    rows = cluster.parse_members(text)
    if rows is None:
        _output_rows(manager, box, text)
        _update_actions(manager)
        return
    clear(box)
    manager.cluster_members = rows
    manager.cluster_selected = None
    _draw_members(manager, box)
    box.show_all()
    _update_actions(manager)
    if manager.cluster_members and manager.cluster_managed is None:
        _shell(manager, cluster.managed_command(), _probe_rows, "Members")


def _probe_rows(manager, box, answer):
    """The nodelist probe: it only decides whether Upgrade is offered."""
    manager.cluster_managed = "yes" in (answer or "")
    clear(box)
    _draw_members(manager, box)
    box.show_all()
    _update_actions(manager)


def _pending_answer(manager, box, text):
    """Join requests: the table when the answer parses, its raw text when not."""
    rows = cluster.parse_pending(text)
    if rows is None:
        _output_rows(manager, box, text)
        _update_actions(manager)
        return
    clear(box)
    manager.cluster_pending = rows
    manager.cluster_selected_request = None
    if not manager.cluster_pending:
        box.pack_start(Gtk.Label(label=(
            "No join request is waiting: nothing has asked to join this cluster "
            "in the time its invite was alive."), wrap=True), False, False, 6)
        _update_actions(manager)
        return
    box.pack_start(Gtk.Label(label=(
        "{} request(s). Double-click a row to select it, then Approve or Deny "
        "it. A request that is not answered expires with its invite.".format(
            len(manager.cluster_pending))), wrap=True), False, False, 4)
    def pick(view, path, _column):
        """Double-click a request row: it becomes the one Approve and Deny act on."""
        requests = getattr(manager, "cluster_pending", [])
        try:
            index = int(path.get_indices()[0])
        except (AttributeError, IndexError, ValueError):
            return
        if 0 <= index < len(requests):
            manager.cluster_selected_request = requests[index]
            _update_actions(manager)

    table(box, ("Node", "Arch", "Age", "Request"),
          [[row.get("name", ""), row.get("arch", ""),
            cluster.age_text(row.get("age_s")), row.get("id", "")]
           for row in manager.cluster_pending],
          select=pick)
    _update_actions(manager)


def _update_actions(manager):
    """Grey out what this state does not allow; the buttons never disappear."""
    buttons = getattr(manager, "cluster_buttons", {})
    members = getattr(manager, "cluster_members", None)
    managed = getattr(manager, "cluster_managed", None)
    # Unknown state is treated as "already managed": the repair is not offered
    # before the probe has answered, so a button cannot appear by accident.
    allowed = cluster.page_actions(members, True if managed is None else managed) \
        if members is not None else set()
    for name, widget in buttons.items():
        if name == "core":
            widget.set_sensitive(cluster.core_allowed(
                getattr(manager, "cluster_selected", None)))
        elif name in ("approve", "deny"):
            widget.set_sensitive(bool(getattr(manager, "cluster_pending", None)))
        else:
            widget.set_sensitive(name in allowed)


def _load_members(manager, results):
    _shell(manager, cluster.members_command(), _members_answer, "Members",
           timeout=READ_TIMEOUT)


def _load_pending(manager, results):
    _shell(manager, cluster.pending_command(), _pending_answer, "Join requests",
           timeout=READ_TIMEOUT)


def _make_core(manager):
    """`supermox-join core`, in the selected member's own shell."""
    member = getattr(manager, "cluster_selected", None)
    if not member:
        manager.message("Select a member first",
                        "Open the Members tab and double-click the edge member "
                        "you want to make a corosync core member.")
        return
    if not cluster.core_allowed(member):
        manager.message("Already a core member",
                        "{} is in the corosync nodelist already; there is nothing "
                        "to add.".format(member.get("name", "that member")))
        return
    name = member.get("name")
    if not name:
        manager.message("This member has no name",
                        "The answer came back with a member without a name; reload "
                        "the Members tab.")
        return
    if not manager.confirm(
            "Make {} a core member?".format(name),
            "supermox-join core runs on {}, not here: only that node can write its "
            "own keys. It needs {} to be on the same LAN as this node and to have "
            "no guests running on it, because the nodelist is copied, not merged."
            .format(name, name, name)):
        return
    _shell(manager, cluster.core_command(), _output_rows, "Members",
           timeout=WRITE_TIMEOUT, node=name)


def _upgrade(manager):
    """`supermox-join cluster-init`: write this cluster's corosync nodelist."""
    if not manager.confirm(
            "Upgrade to a corosync cluster?",
            "supermox-join cluster-init writes /etc/pve/corosync.conf's nodelist "
            "from the members this node already knows, so cluster-wide failover and "
            "HA start working between them. Nothing joins and no key changes."):
        return
    _shell(manager, cluster.cluster_init_command(), _output_rows, "Members",
           timeout=WRITE_TIMEOUT)


def _decide(manager, action):
    """Approve or Deny the selected join request."""
    request = getattr(manager, "cluster_selected_request", None)
    if not request:
        manager.message("Select a join request first",
                        "Open the Join requests tab and double-click the request "
                        "you want to answer.")
        return
    command = cluster.decide_command(action, request.get("id"))
    if not manager.confirm(
            "{} {}?".format("Approve" if action == "approve" else "Deny",
                            request.get("name") or "this request"),
            "{} runs on this node. An approved request joins the cluster now; "
            "a denied one is dropped and the node has to be invited again."
            .format(command)):
        return
    _shell(manager, command, _pending_answer, "Join requests", timeout=WRITE_TIMEOUT)


def _create(manager):
    """Create a cluster with this node as its first member."""
    node = _local_node(manager)
    if not node:
        return
    if manager.demo:
        manager.message("Preview mode",
                        "Restart without --demo to create a cluster.")
        return
    if getattr(manager, "cluster_members", None):
        manager.message("This node is already in a cluster",
                        "The Members tab lists its members. Creating a second cluster "
                        "here would leave the first one without this node.")
        return
    client = manager.client
    manager.work(lambda: network.interfaces(client, node),
                 lambda rows: _create_form(manager, node, rows))


def _create_form(manager, node, rows):
    """Ask for this node's endpoint, prefilled from its own interfaces."""
    prefill = cluster.endpoint_from_interfaces(rows)
    values = manager.form(
        "Create a cluster on {}".format(node),
        [("endpoint", "This node's endpoint", prefill, False)],
        submit="Create",
        note="The endpoint is where the other nodes reach this node's join daemon: "
             "an address, optionally with a port (8743 is used when you leave it "
             "off). It was prefilled from this node's own interfaces; type over it "
             "if that is not the address you want.")
    if values is None:
        return
    endpoint = values["endpoint"].strip()
    if not endpoint:
        manager.message("No endpoint given",
                        "Type the address the other nodes should reach this node "
                        "on, or press Cancel.")
        return
    command = cluster.create_command(node, endpoint)
    client = manager.client
    manager.work(lambda: cluster.run_shell(client, node, command,
                                          timeout=WRITE_TIMEOUT),
                 deliver(manager, "cluster_results", TITLE, "Add a node",
                         _created_rows))


def _invite(manager):
    """`supermox-join invite --ttl 900`: a single-use invite for a new node."""
    _shell(manager, cluster.invite_command(), _output_rows, "Add a node",
           timeout=WRITE_TIMEOUT)


def _join_note(manager, box, rows):
    """What the node that wants to join has to run, and why not here.

    That node is not in the cluster yet, so the Manager has no shell on it:
    its part of the join stays text. Everything this node does for the join
    is a button.
    """
    clear(box)
    del rows
    box.pack_start(Gtk.Label(label=(
        "SuperMox does not use pvesh create /cluster/config/join: that call needs a "
        "fingerprint and a shared secret, and on a node that is already in a cluster the "
        "node answers \u201cCheck if node may join a cluster failed!\u201d. Nodes join with "
        "supermox-join, which carries a 12-word phrase (128 bits plus a checksum) through "
        "the QR invite or the terminal."), wrap=True), False, False, 6)
    box.pack_start(Gtk.Label(label=(
        "The node that wants to join runs this, on its own console:"), wrap=True),
        False, False, 0)
    command = Gtk.Label(label="supermox-join join --name <name> --endpoint <host> "
                               "--words <12 words>", xalign=0, yalign=0, wrap=True)
    command.get_style_context().add_class("preview")
    box.pack_start(command, False, False, 6)
    box.pack_start(Gtk.Label(label=(
        "or scans the QR invite the Invite button prints. The 12-word phrase is typed by "
        "hand on that node: this page never stores or shows it. Create and Invite below run "
        "in this node's shell instead, because this node is the one that already belongs to "
        "the cluster."), wrap=True), False, False, 0)
    box.show_all()


def _open_shell(manager):
    """Open the t70 node shell with SHELL_COMMAND typed at the prompt, not run."""
    node = _local_node(manager)
    if not node:
        return
    if manager.demo:
        manager.message("Preview mode", "Restart without --demo to open a node shell.")
        return
    client = manager.client
    manager.work(lambda: terminal.open_session(client, node),
                 lambda session: _shell_window(manager, session, node))


def render(manager, content):
    from ..app import button
    clear(content)
    manager.cluster_results = {}
    manager.cluster_options = {}
    manager.cluster_log_size = 0
    # The cluster's own state, and the buttons that depend on it. Nothing is
    # known until a command has answered, so every state-dependent button starts
    # greyed out and ops.cluster.page_actions lights it.
    manager.cluster_members = None
    manager.cluster_managed = None
    manager.cluster_pending = None
    manager.cluster_selected = None
    manager.cluster_selected_request = None
    manager.cluster_buttons = {}
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)

    def add(bar, name, text, callback, primary=False):
        """A button, remembered under its action name when it has one."""
        widget = button(text, callback, primary)
        if name:
            manager.cluster_buttons[name] = widget
        bar.pack_start(widget, False, False, 0)

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
            add(actions, "", "Reload", lambda *_: _load_status(manager, results))
        elif name == "Log":
            add(actions, "", "Reload", lambda *_: _load_log(manager, results))
        elif name == "Options":
            add(actions, "", "Reload", lambda *_: _load_options(manager, results))
            add(actions, "", "Change", lambda *_: _change_options(manager))
            add(actions, "", "Reset to defaults", lambda *_: _reset_options(manager))
        elif name == "Members":
            add(actions, "", "Reload", lambda *_: _load_members(manager, results))
            add(actions, "core", "Make core", lambda *_: _make_core(manager))
            add(actions, "upgrade", "Upgrade to corosync cluster",
                lambda *_: _upgrade(manager))
        elif name == "Join requests":
            add(actions, "", "Reload", lambda *_: _load_pending(manager, results))
            add(actions, "approve", "Approve", lambda *_: _decide(manager, "approve"))
            add(actions, "deny", "Deny", lambda *_: _decide(manager, "deny"))
        else:
            _join_note(manager, results, None)
            add(actions, "create", "Create cluster", lambda *_: _create(manager), True)
            add(actions, "invite", "Invite a node", lambda *_: _invite(manager))
            add(actions, "", "Open node shell", lambda *_: _open_shell(manager))
        page.pack_start(actions, False, False, 0)
        page.pack_start(results, True, True, 0)
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
    _update_actions(manager)
