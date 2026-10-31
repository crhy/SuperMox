"""Node: this node's health, services, system log, updates and DNS/time settings.

A Gtk.Notebook with five tabs — Summary, Services, System log, Updates, DNS/Time.
Every endpoint and parameter name was read from the running node with `pvesh
usage` (see .strata/notes-t72-manager-node-admin.md); nothing is guessed. The
Services tab drives start/stop/restart/reload through the sysvinit service
scripts (no systemctl). Restarting a service and refreshing the package index
are submitted as tasks; DNS and timezone changes are applied with a PUT and
re-read. Writing /etc/hosts is not exposed here — it would break the node's
own name resolution.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from .. import api
from ..ops import node as nodeops

TITLE = "Node"
SUBTITLE = "This node's health, services, log, updates and settings."

TABS = ("Summary", "Services", "System log", "Updates", "DNS/Time")


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _clear(box):
    for child in box.get_children():
        box.remove(child)
        child.destroy()


def _table(box, columns, rows, select=None):
    """Build a tree view and pack it into a tab's results box (GTK thread)."""
    model = Gtk.ListStore(*([str] * len(columns)))
    for row in rows:
        model.append([str(v) for v in row])
    tree = Gtk.TreeView(model=model)
    tree.set_headers_visible(True)
    for index, name in enumerate(columns):
        renderer = Gtk.CellRendererText()
        renderer.set_property("ypad", 10)
        renderer.set_property("xpad", 8)
        column = Gtk.TreeViewColumn(name, renderer, text=index)
        column.set_expand(True)
        tree.append_column(column)
    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    scroll.add(tree)
    box.pack_start(scroll, True, True, 0)
    if select:
        tree.connect("row-activated", select)
    return tree


def _results(manager, name):
    """Return the live results box for a tab, or None if the page was redrawn."""
    box = getattr(manager, "node_results", {}).get(name)
    if box is None:
        return None
    try:
        if box.get_parent() is None:
            return None
    except Exception:
        return None
    return box


def _deliver(manager, name, builder):
    """Wrap a table builder so it only paints into the current page."""
    def show(rows):
        if manager.current != TITLE:
            return
        box = _results(manager, name)
        if box is None:
            return
        _clear(box)
        builder(manager, box, rows)
        box.show_all()
    return show


def _selected(manager, attr, what, tab):
    found = getattr(manager, attr, None)
    if not found:
        manager.message("Select a {} first".format(what),
                        "Open the {} tab and double-click the {} you want to change."
                        .format(tab, what))
    return found


# --- Summary -----------------------------------------------------------

def _summary_rows(manager, box, result):
    cpu = result.get("cpuinfo", {}) or {}
    load = result.get("loadavg", []) or []
    mem = result.get("memory", {}) or {}
    rootfs = result.get("rootfs", {}) or {}
    _table(box, ("Item", "Value"),
           [("PVE version", result.get("pveversion", "")),
            ("Release", result.get("release", "")),
            ("Kernel", result.get("kernel", "")),
            ("CPU arch", cpu.get("arch", "")),
            ("CPU count", result.get("cpu", "")),
            ("Load average", ", ".join("{:.2f}".format(x) for x in load) if load else ""),
            ("Memory used", api.human_bytes(mem.get("used", 0)) if mem else ""),
            ("Memory total", api.human_bytes(mem.get("total", 0)) if mem else ""),
            ("Root FS used", api.human_bytes(rootfs.get("used_on_mnt", 0)) if rootfs else ""),
            ("Root FS size", api.human_bytes(rootfs.get("size", 0)) if rootfs else "")])


def _load_summary(manager):
    manager.work(lambda: nodeops.summary(manager.client, _node(manager)),
                 _deliver(manager, "Summary", _summary_rows))


# --- Services ----------------------------------------------------------

def _services_rows(manager, box, rows):
    manager.node_service_map = {row["name"]: row for row in rows}
    manager.node_sel_service = None

    def pick(view, path, _c):
        manager.node_sel_service = manager.node_service_map.get(view.get_model()[path][0])

    _table(box, ("Service", "State"),
           [(row.get("name", ""), row.get("state", "")) for row in rows],
           select=pick)


def _load_services(manager):
    manager.work(lambda: nodeops.services(manager.client, _node(manager)),
                 _deliver(manager, "Services", _services_rows))


def _service_action(manager, action):
    service = _selected(manager, "node_sel_service", "service", "Services")
    if not service:
        return
    name = service["name"]
    if not manager.confirm("{} service {}?".format(action.capitalize(), name),
                           "{} {}.{}".format(action.capitalize(), _node(manager), name)
                           + (" A stop can interrupt running work." if action == "stop" else "")):
        return
    client = manager.client
    target = _node(manager)

    def op():
        return nodeops.service_action(client, target, name, action)

    manager.work(op, lambda task: manager.submitted(task, target))


# --- System log --------------------------------------------------------

def _show_syslog(manager, rows):
    lines = ["{}  {}".format(row.get("n", ""), row.get("t", "")) for row in rows]
    manager.text_window("System log · {}".format(_node(manager)),
                        "\n".join(lines) if lines else "No log lines returned.")


def _load_syslog(manager):
    manager.work(lambda: nodeops.syslog(manager.client, _node(manager), limit=200),
                 lambda rows: _show_syslog(manager, rows))


# --- Updates -----------------------------------------------------------

def _updates_rows(manager, box, rows):
    _table(box, ("Package", "Installed", "Available", "Origin"),
           [(row.get("Package", ""), row.get("OldVersion", ""),
             row.get("Version", ""), row.get("Origin", ""))
            for row in rows])


def _load_updates(manager):
    manager.work(lambda: nodeops.updates(manager.client, _node(manager)),
                 _deliver(manager, "Updates", _updates_rows))


def _refresh_updates(manager):
    target = _node(manager)
    client = manager.client
    manager.work(lambda: nodeops.refresh_updates(client, target),
                 lambda task: manager.submitted(task, target))


# --- DNS/Time ----------------------------------------------------------

def _show_dns(manager, result):
    manager.text_window(
        "DNS · {}".format(_node(manager)),
        "dns1: {}\ndns2: {}\ndns3: {}\nsearch: {}".format(
            result.get("dns1", ""), result.get("dns2", ""),
            result.get("dns3", ""), result.get("search", "")))


def _load_dns(manager):
    manager.work(lambda: nodeops.dns(manager.client, _node(manager)),
                 lambda result: _show_dns(manager, result))


def _set_dns(manager):
    target = _node(manager)
    values = manager.form(
        "Set DNS · {}".format(target),
        [("dns1", "First name server", "", False),
         ("dns2", "Second name server", "", False),
         ("dns3", "Third name server", "", False),
         ("search", "Search domains (comma separated)", "", False)],
        "Apply",
        "Writes the node's DNS settings. Leave a field blank to leave it unchanged; "
        "the search field can be cleared. Applied with a PUT, then re-read.")
    if values is None:
        return
    options = {}
    for key in ("dns1", "dns2", "dns3", "search"):
        if values[key].strip():
            options[key] = values[key].strip()
    if not options:
        manager.message("Check the fields", "Give at least one DNS field to change.")
        return
    client = manager.client
    manager.work(lambda: nodeops.set_dns(client, target, **options),
                 lambda _r: (manager.status.set_text("Updated DNS on " + target),
                             _load_dns(manager)))


def _show_time(manager, result):
    manager.text_window(
        "Time · {}".format(_node(manager)),
        "timezone: {}\ntime: {}\nlocaltime: {}".format(
            result.get("timezone", ""), result.get("time", ""),
            result.get("localtime", "")))


def _load_time(manager):
    manager.work(lambda: nodeops.time_info(manager.client, _node(manager)),
                 lambda result: _show_time(manager, result))


def _set_timezone(manager):
    target = _node(manager)
    values = manager.form(
        "Set timezone · {}".format(target),
        [("timezone", "Time zone (from /usr/share/zoneinfo/zone.tab)", "Etc/UTC", False)],
        "Apply",
        "Sets the node's time zone. Applied with a PUT, then re-read.")
    if values is None:
        return
    if not values["timezone"].strip():
        manager.message("Check the fields", "Give a time zone name.")
        return
    client = manager.client
    manager.work(lambda: nodeops.set_timezone(client, target, values["timezone"].strip()),
                 lambda _r: (manager.status.set_text("Set timezone on " + target),
                             _load_time(manager)))


# --- Page ------------------------------------------------------------

DESCRIPTIONS = {
    "Summary": "Version, kernel, CPU, load, memory and root filesystem for this node.",
    "Services": "The sysvinit services and their state. Double-click a row to select it, "
                "then start, stop, restart or reload it.",
    "System log": "The last system log lines, shown in a window.",
    "Updates": "Available package updates; Refresh resynchronises the package index.",
    "DNS/Time": "Read and change the node's DNS servers, search domains and time zone.",
}

ACTIONS = {
    "Summary": (("Summary", lambda m: _load_summary(m)),),
    "Services": (("Services", lambda m: _load_services(m)),
                 ("Start", lambda m: _service_action(m, "start")),
                 ("Stop", lambda m: _service_action(m, "stop")),
                 ("Restart", lambda m: _service_action(m, "restart")),
                 ("Reload", lambda m: _service_action(m, "reload"))),
    "System log": (("System log", lambda m: _load_syslog(m)),),
    "Updates": (("Updates", lambda m: _load_updates(m)),
                ("Refresh index", lambda m: _refresh_updates(m))),
    "DNS/Time": (("DNS", lambda m: _load_dns(m)),
                 ("Set DNS", _set_dns),
                 ("Time", lambda m: _load_time(m)),
                 ("Set timezone", _set_timezone)),
}


def render(manager, content):
    from ..app import label
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
    manager.node_results = {}
    for name in TABS:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        page.set_hexpand(True)
        page.set_vexpand(True)
        page.pack_start(label(DESCRIPTIONS[name], "subtitle"), False, False, 4)
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for text, callback in ACTIONS[name]:
            actions.pack_start(Gtk.Button(label=text), False, False, 0)
        page.pack_start(actions, False, False, 0)
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        results.set_hexpand(True)
        results.set_vexpand(True)
        page.pack_start(results, True, True, 0)
        manager.node_results[name] = results
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
