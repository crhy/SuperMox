"""Native GTK desktop management. Network work never runs on the GTK thread."""

import threading

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from . import api, logic, pages
from .ops import create as create_ops, guests, tasks

CSS = b"""
window, dialog { background: #092b32; color: #eef5ef; }
headerbar { background: #07252c; border-bottom: 1px solid #24474c; color: #eef5ef; }
.sidebar { background: #07252c; padding: 18px 12px; border-right: 1px solid #24474c; }
.brand { font-size: 23px; font-weight: bold; color: #35d8b0; }
.title { font-size: 28px; font-weight: bold; }
.subtitle { color: #a4bcb9; }
.metric { background: #12373b; border: 1px solid #295157; border-radius: 12px; padding: 22px; }
.number { font-size: 30px; font-weight: bold; color: #35d8b0; }
button { background-image: none; background-color: #12373b; color: #eef5ef; border: 1px solid #315459; border-radius: 7px; padding: 9px 14px; }
button:hover { background-color: #24545b; }
button.suggested-action { background-color: #35d8b0; color: #07252c; }
.sidebar button { border: none; background: transparent; box-shadow: none; padding: 13px 18px; }
.sidebar button:checked { background: #15474b; color: #35d8b0; }
entry, combobox button, textview text { background: #07252c; color: #eef5ef; }
treeview { background: #0d323a; color: #eef5ef; padding: 10px; }
treeview:selected { background: #205a60; color: white; }
treeview header button { background: #12373b; border-radius: 0; font-weight: bold; }
.status { padding: 9px 18px; background: #07252c; color: #a4bcb9; }
.preview { background: #624c24; color: #ffdfa4; padding: 8px; }
"""


def label(text, style=None):
    widget = Gtk.Label(label=text, xalign=0)
    if style:
        widget.get_style_context().add_class(style)
    return widget


def button(text, callback, primary=False):
    widget = Gtk.Button(label=text)
    widget.connect("clicked", callback)
    if primary:
        widget.get_style_context().add_class("suggested-action")
    return widget


def box(vertical=True, spacing=12, margin=0):
    widget = Gtk.Box(orientation=Gtk.Orientation.VERTICAL if vertical else Gtk.Orientation.HORIZONTAL,
                     spacing=spacing)
    widget.set_border_width(margin)
    return widget


class Manager:
    def __init__(self, url, pin=None, demo=False, nodes=None):
        self.url, self.pin, self.demo = url, pin, demo
        self.client = api.DemoClient() if demo else None
        self.nodes = nodes or []
        self.resources = []
        self.current = "Overview"
        self.navigating = False
        self.selected = None
        self.closed = False
        self.busy = False
        self.generation = 0
        self.full_windows = []
        self.settings = logic.load_settings()
        self.window = Gtk.Window(title="SuperMox Manager")
        self.window.set_wmclass("supermox-manager", "SuperMox Manager")
        self.window.set_icon_name("supermox-manager")
        self.window.set_default_size(max(1200, self.settings["width"]), max(800, self.settings["height"]))
        self.window.connect("destroy", self.close)
        css = Gtk.CssProvider()
        css.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.window.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        header = Gtk.HeaderBar(title="SuperMox Manager", subtitle="One OS. All yours.")
        header.set_show_close_button(True)
        self.connect_button = button("Connection", lambda *_: self.connect_dialog())
        header.pack_start(self.connect_button)
        header.pack_end(button("About", lambda *_: self.about()))
        header.pack_end(button("Refresh", lambda *_: self.refresh()))
        header.pack_end(button("Sign out", lambda *_: self.sign_out()))
        self.window.set_titlebar(header)
        root = box(spacing=0)
        self.window.add(root)
        if demo:
            root.pack_start(label("PREVIEW  ·  Sample data. Actions are simulated; no host is connected.", "preview"), False, False, 0)
        body = box(False, 0)
        root.pack_start(body, True, True, 0)
        sidebar = box(spacing=6)
        sidebar.set_size_request(215, -1)
        sidebar.get_style_context().add_class("sidebar")
        sidebar.pack_start(label("SuperMox", "brand"), False, False, 8)
        sidebar.pack_start(label("MANAGER", "subtitle"), False, False, 12)
        self.nav = {}
        self.pages = {page.TITLE: page for page in pages.load()}
        for name in dict.fromkeys(("Overview", "Machines", "Nodes", "Storage", "Tasks",
                                   *self.pages, "Full management")):
            nav = Gtk.ToggleButton(label=name)
            nav.set_halign(Gtk.Align.FILL)
            nav.connect("clicked", self.navigate, name)
            sidebar.pack_start(nav, False, False, 0)
            self.nav[name] = nav
        sidebar.pack_end(label("Your infrastructure.\nYour control.", "subtitle"), False, False, 12)
        body.pack_start(sidebar, False, False, 0)
        self.content = box(margin=28, spacing=18)
        body.pack_start(self.content, True, True, 0)
        self.status = label("Ready", "status")
        self.status.set_ellipsize(3)
        root.pack_end(self.status, False, False, 0)
        self.nav["Overview"].set_active(True)
        self.render()
        self.window.show_all()
        if demo:
            self.refresh()
        else:
            GLib.idle_add(self.connect_dialog)
        self.timer = GLib.timeout_add_seconds(15, self.auto_refresh)

    def work(self, operation, done):
        if self.busy:
            self.status.set_text("An operation is already in progress.")
            return
        self.busy = True
        generation = self.generation
        self.status.set_text("Working…")

        def worker():
            try:
                result, error = operation(), None
            except Exception as exc:
                result = None
                error = str(exc) if isinstance(exc, (api.APIError, ValueError)) else "The operation failed. Check the node and try again."
            GLib.idle_add(deliver, result, error)

        def deliver(result, error):
            if self.closed or generation != self.generation:
                return False
            self.busy = False
            if error:
                self.status.set_text(error)
                self.message("Could not complete the operation", error)
            else:
                self.status.set_text("Preview · sample data" if self.demo else "Connected · " + self.url)
                done(result)
            return False

        threading.Thread(target=worker, daemon=True).start()

    def message(self, title, text):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                   message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.CLOSE, text=title)
        dialog.format_secondary_text(str(text))
        dialog.run()
        dialog.destroy()

    def form(self, title, fields, submit="Continue", note=None):
        dialog = Gtk.Dialog(title=title, transient_for=self.window, modal=True)
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, submit, Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        area = dialog.get_content_area()
        area.set_border_width(24)
        area.set_spacing(10)
        if note:
            description = label(note, "subtitle")
            description.set_line_wrap(True)
            description.set_max_width_chars(65)
            area.pack_start(description, False, False, 6)
        entries = {}
        for key, title, default, secret in fields:
            area.pack_start(label(title), False, False, 0)
            entry = Gtk.Entry()
            entry.set_text(str(default))
            entry.set_visibility(not secret)
            entry.set_activates_default(True)
            entry.set_width_chars(48)
            area.pack_start(entry, False, False, 0)
            entries[key] = entry
        dialog.show_all()
        answer = dialog.run()
        values = {k: e.get_text() for k, e in entries.items()} if answer == Gtk.ResponseType.OK else None
        for entry in entries.values():
            entry.set_text("")
        dialog.destroy()
        return values

    def connect_dialog(self):
        if self.demo:
            self.message("Preview mode", "Restart without --demo to connect to a real SuperMox node.")
            return False
        if self.busy:
            return False
        if self.nodes:
            # The picker reads root-controlled public membership, never private keys.
            dialog = Gtk.Dialog(title="Choose a cluster node", transient_for=self.window, modal=True)
            dialog.add_buttons("Manual connection", 2, "Use node", Gtk.ResponseType.OK)
            picker = Gtk.ComboBoxText()
            for name, url, pin in self.nodes:
                picker.append_text(name + " — " + url)
            picker.set_active(0)
            dialog.get_content_area().pack_start(picker, False, False, 18)
            dialog.show_all()
            response = dialog.run()
            index = picker.get_active()
            dialog.destroy()
            if response == Gtk.ResponseType.OK and index >= 0:
                _, self.url, self.pin = self.nodes[index]
            elif response != 2:
                return False
        values = self.form("Connect to SuperMox", [
            ("url", "Node address", self.url, False),
            ("pin", "Certificate SHA256 fingerprint", self.pin or "", False),
            ("username", "Username and realm", "root@pam", False),
            ("password", "Password", "", True),
            ("otp", "One-time code (if required)", "", True),
        ], "Sign in", "Use a fingerprint from the node administrator or its local certificate. Credentials are held in memory for this session.")
        if values:
            try:
                client = api.Client(values["url"].strip(), values["pin"])
            except ValueError as exc:
                self.message("Check connection details", str(exc))
                return False

            # Retain the validated target for interactive login through Full management.
            # Disconnect the previous account before switching origins.
            self.sign_out()
            self.url, self.pin = client.url, client.pin

            def login():
                try:
                    client.login(values["username"].strip(), values["password"], values["otp"])
                    return client, client.resources()
                finally:
                    values.clear()

            def connected(result):
                if self.client:
                    self.client.logout()
                self.close_full_windows()
                self.client, self.resources = result
                self.url, self.pin = client.url, client.pin
                self.render()
            self.work(login, connected)
        return False

    def sign_out(self):
        # Discard pending replies and close browser sessions, including their cookies.
        self.generation += 1
        self.busy = False
        if self.client:
            self.client.logout()
        self.client = None
        self.resources = []
        self.close_full_windows()
        self.status.set_text("Signed out")
        self.render()

    def navigate(self, _button, name):
        if self.navigating or name == self.current:
            return
        self.current = name
        self.navigating = True
        for key, nav in self.nav.items():
            nav.set_active(key == name)
        self.navigating = False
        self.render()
        if name == "Tasks" and self.client:
            self.refresh()

    def refresh(self):
        if self.busy or not self.client:
            return
        client = self.client
        if self.current == "Tasks":
            self.work(client.tasks, self.show_tasks)
        else:
            self.work(client.resources, self.received)

    def received(self, rows):
        self.resources = rows
        self.render()

    def auto_refresh(self):
        if not self.closed and self.client and self.current == "Overview":
            self.refresh()
        return not self.closed

    def render(self):
        for child in self.content.get_children():
            self.content.remove(child)
            child.destroy()
        self.selected = None
        self.content.pack_start(label(self.current, "title"), False, False, 0)
        subtitles = {
            "Overview": "A clear view of your cluster, from desktop to edge.",
            "Machines": "Virtual machines and containers, together in one place.",
            "Nodes": "The devices powering your infrastructure.",
            "Storage": "Capacity and content across your cluster.",
            "Tasks": "Recent operations and their results.",
            "Full management": "Complete server interface, inside the desktop app.",
        }
        page = self.pages.get(self.current)
        subtitle = page.SUBTITLE if page else subtitles[self.current]
        self.content.pack_start(label(subtitle, "subtitle"), False, False, 0)
        if self.current == "Full management":
            self.full_page()
        elif not self.client:
            self.content.pack_start(label("Connect to a node to see live resources."), False, False, 28)
            self.content.pack_start(button("Connect to a node", lambda *_: self.connect_dialog(), True), False, False, 0)
        elif page:
            page.render(self, self.content)
        elif self.current == "Overview":
            self.overview()
        elif self.current == "Tasks":
            self.task_table([])
        else:
            self.resource_table()
        self.content.show_all()

    def overview(self):
        nodes = [r for r in self.resources if r["type"] == "node"]
        guests = [r for r in self.resources if r["type"] in ("qemu", "lxc")]
        metrics = box(False, 14)
        used = sum(r.get("mem", 0) for r in nodes)
        total = sum(r.get("maxmem", 0) for r in nodes)
        for name, value, detail in (
                ("NODES ONLINE", str(sum(r.get("status") == "online" for r in nodes)), "{} nodes in this view".format(len(nodes))),
                ("MACHINES RUNNING", str(sum(r.get("status") == "running" for r in guests)), "{} machines in total".format(len(guests))),
                ("MEMORY IN USE", api.human_bytes(used), "of " + api.human_bytes(total))):
            card = box(spacing=10)
            card.get_style_context().add_class("metric")
            for text, style in ((name, "subtitle"), (value, "number"), (detail, "subtitle")):
                card.pack_start(label(text, style), False, False, 0)
            metrics.pack_start(card, True, True, 0)
        self.content.pack_start(metrics, False, False, 8)
        self.content.pack_start(label("Your machines", "brand"), False, False, 10)
        self.machine_table(guests)

    def table(self, columns, rows, select=None):
        model = Gtk.ListStore(*([str] * len(columns)))
        for row in rows:
            model.append([str(v) for v in row])
        tree = Gtk.TreeView(model=model)
        tree.set_headers_visible(True)
        tree.set_enable_search(True)
        for index, name in enumerate(columns):
            renderer = Gtk.CellRendererText()
            renderer.set_property("ypad", 13)
            renderer.set_property("xpad", 8)
            column = Gtk.TreeViewColumn(name, renderer, text=index)
            column.set_expand(True)
            column.set_resizable(True)
            column.set_sort_column_id(index)
            tree.append_column(column)
        if select:
            tree.get_selection().connect("changed", select)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(tree)
        self.content.pack_start(scroll, True, True, 0)
        return tree

    def machine_table(self, guests):
        self.guest_map = {str(g["vmid"]): g for g in guests}
        search = Gtk.SearchEntry(placeholder_text="Search machines by name, ID or node")
        self.content.pack_start(search, False, False, 0)
        rows = [(g["vmid"], g.get("name", "Unnamed"), "VM" if g["type"] == "qemu" else "Container",
                 g["node"], g.get("status", "unknown"),
                 "{:.0%}".format(g.get("cpu", 0)), api.human_bytes(g.get("mem", 0))) for g in guests]
        tree = self.table(("ID", "Name", "Kind", "Node", "State", "CPU", "Memory"), rows)
        source = tree.get_model()
        filtered = source.filter_new()
        filtered.set_visible_func(lambda model, iterator, _data: search.get_text().casefold() in
                                  " ".join(model[iterator]).casefold())
        tree.set_model(Gtk.TreeModelSort(model=filtered))
        search.connect("search-changed", lambda *_: filtered.refilter())
        tree.get_selection().connect("changed", self.select_guest)
        tree.connect("row-activated", lambda *_: self.details())
        actions = box(False, 8)
        self.action_buttons = []
        for title, callback in (("Details", lambda *_: self.details()),
                                ("Start", lambda *_: self.power("start")),
                                ("Shut down", lambda *_: self.power("shutdown")),
                                ("More actions", lambda *_: self.more_actions())):
            widget = button(title, callback, title == "Start")
            widget.set_sensitive(False)
            self.action_buttons.append(widget)
            actions.pack_start(widget, False, False, 0)
        self.content.pack_start(actions, False, False, 0)

    def select_guest(self, selection):
        model, iterator = selection.get_selected()
        self.selected = self.guest_map.get(model[iterator][0]) if iterator else None
        for widget in self.action_buttons:
            widget.set_sensitive(self.selected is not None and not self.busy)

    def resource_table(self):
        if self.current == "Machines":
            self.machine_table([g for g in self.resources if g["type"] in ("qemu", "lxc")])
            return
        if self.current == "Nodes":
            rows = [(r["node"], r.get("status", "unknown"), "{:.0%}".format(r.get("cpu", 0)),
                     api.human_bytes(r.get("mem", 0)), api.human_bytes(r.get("maxmem", 0)))
                    for r in self.resources if r["type"] == "node"]
            self.table(("Node", "State", "CPU", "Memory used", "Memory total"), rows)
        else:
            rows = [(r["storage"], r["node"], r.get("status", "unknown"),
                     api.human_bytes(r.get("disk", 0)), api.human_bytes(r.get("maxdisk", 0)), r.get("content", ""))
                    for r in self.resources if r["type"] == "storage"]
            self.table(("Storage", "Node", "State", "Used", "Capacity", "Content"), rows)

    def details(self):
        if not self.selected:
            return
        guest = dict(self.selected)
        client = self.client
        self.work(lambda: client.request("GET", api.guest_path(guest) + "/config"),
                  lambda config: self.text_window("Machine {} · configuration".format(guest["vmid"]),
                                                  "\n".join("{}: {}".format(k, v) for k, v in sorted(config.items()))))

    def text_window(self, title, text):
        dialog = Gtk.Dialog(title=title, transient_for=self.window, modal=True)
        dialog.set_default_size(760, 480)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        scroll = Gtk.ScrolledWindow()
        view = Gtk.TextView(editable=False, monospace=True)
        view.set_left_margin(18)
        view.set_top_margin(18)
        view.get_buffer().set_text(text)
        scroll.add(view)
        dialog.get_content_area().pack_start(scroll, True, True, 0)
        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def confirm(self, title, detail):
        dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                                   message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.OK_CANCEL, text=title)
        dialog.format_secondary_text(detail)
        answer = dialog.run() == Gtk.ResponseType.OK
        dialog.destroy()
        return answer

    def power(self, action):
        if not self.selected or self.busy:
            return
        guest = dict(self.selected)
        if action != "start" and not self.confirm("{} machine {}?".format(action.capitalize(), guest["vmid"]),
                                                  "{} on {}.{}".format(guest.get("name", ""), guest["node"],
                                                   " A forced stop can lose unsaved data." if action == "stop" else "")):
            return
        client = self.client
        self.work(lambda: client.action(guest, action),
                  lambda task: self.submitted(task, guest["node"]))

    def submitted(self, task, node):
        self.status.set_text("Operation submitted. Check Tasks for completion.")
        if isinstance(task, str) and task.startswith("UPID:"):
            self.task_detail({"upid": task, "node": node})
        else:
            self.message("Operation submitted", task or "Check Tasks for completion.")
        self.refresh()

    def clone(self):
        if not self.selected or self.busy:
            return
        guest = dict(self.selected)
        client = self.client
        self.work(lambda: create_ops.clone(client, guest["node"], guest["vmid"],
                                           guests.next_id(client)),
                  lambda task: self.submitted(task, guest["node"]))

    def make_template(self):
        if not self.selected or self.busy:
            return
        guest = dict(self.selected)
        if not self.confirm("Convert to template?", "{} on {}. The machine must be stopped first."
                            .format(guest.get("name", ""), guest["node"])):
            return
        client = self.client
        self.work(lambda: create_ops.make_template(client, guest["node"], guest["vmid"]),
                  lambda task: self.submitted(task, guest["node"]))

    def delete_guest(self):
        if not self.selected or self.busy:
            return
        guest = dict(self.selected)
        if not self.confirm("Delete machine {}?".format(guest["vmid"]),
                            "Remove {} and its disks. This cannot be undone."
                            .format(guest.get("name", ""))):
            return
        client = self.client
        self.work(lambda: guests.destroy(client, guest["node"], guest["type"], guest["vmid"]),
                  lambda task: self.submitted(task, guest["node"]))

    def more_actions(self):
        if not self.selected:
            return
        menu = Gtk.Menu()
        for title, action in (("Reboot", "reboot"), ("Force stop…", "stop"),
                              ("Suspend", "suspend"), ("Resume", "resume")):
            item = Gtk.MenuItem(label=title)
            item.connect("activate", lambda _item, value=action: self.power(value))
            menu.append(item)
        for title, callback in (("Migrate…", self.migrate), ("Create snapshot…", self.snapshot),
                                ("Back up now…", self.backup), ("Clone…", self.clone),
                                ("Convert to template…", self.make_template), ("Delete…", self.delete_guest),
                                ("Console / hardware / full settings", self.open_full)):
            item = Gtk.MenuItem(label=title)
            item.connect("activate", lambda _item, cb=callback: cb())
            menu.append(item)
        menu.show_all()
        menu.popup_at_pointer(None)

    def guest_operation(self, title, suffix, fields, note):
        if not self.selected or self.busy:
            return
        guest = dict(self.selected)
        values = self.form(title + " · machine " + str(guest["vmid"]), fields, title, note)
        if values is None:
            return
        if any(not value.strip() for value in values.values()):
            self.message("Check the fields", "Complete all fields before submitting.")
            return
        client = self.client
        self.work(lambda: client.request("POST", api.guest_path(guest) + suffix, values),
                  lambda task: self.submitted(task, guest["node"]))

    def migrate(self):
        nodes = ", ".join(r["node"] for r in self.resources if r["type"] == "node")
        self.guest_operation("Migrate", "/migrate", [("target", "Destination node", "", False)],
                             "Available nodes: {}. Uses server defaults; use Full management for live migration and storage options.".format(nodes))

    def snapshot(self):
        self.guest_operation("Create snapshot", "/snapshot", [("snapname", "Snapshot name", "", False)],
                             "Creates a disk snapshot where supported. Use Full management for memory snapshots and rollback.")

    def backup(self):
        if not self.selected or self.busy:
            return
        guest = dict(self.selected)
        values = self.form("Back up machine " + str(guest["vmid"]), [("storage", "Backup storage ID", "", False)],
                           "Start backup", "Creates a snapshot-mode backup on the selected storage. Check available space first.")
        if not values or not values["storage"].strip():
            return
        values.update({"vmid": guest["vmid"], "mode": "snapshot"})
        client = self.client
        self.work(lambda: client.request("POST", "/nodes/" + api.segment(guest["node"]) + "/vzdump", values),
                  lambda task: self.submitted(task, guest["node"]))

    def task_table(self, rows):
        self.task_map = {r["upid"]: r for r in rows if "upid" in r}
        tree = self.table(("Node", "Operation", "Guest", "Result", "User", "Task ID"), [
            (r.get("node", ""), r.get("type", ""), r.get("id", ""), r.get("status", "Running"),
             r.get("user", ""), r.get("upid", "")) for r in rows])

        def activated(view, path, _column):
            model = view.get_model()
            task = self.task_map.get(model[path][5])
            if task:
                self.task_detail(task)
        tree.connect("row-activated", activated)
        self.content.pack_start(label("Double-click a task to read its current status and log.", "subtitle"), False, False, 0)

    def show_tasks(self, rows):
        if self.current != "Tasks":
            return
        for child in self.content.get_children()[2:]:
            self.content.remove(child)
            child.destroy()
        self.task_table(rows)
        self.content.show_all()

    def task_detail(self, task):
        client = self.client
        path = "/nodes/{}/tasks/{}".format(api.segment(task["node"]), api.segment(task["upid"]))

        def read():
            status = client.request("GET", path + "/status")
            log = client.request("GET", path + "/log", {"limit": 500})
            return "Status: {}\nResult: {}\n\n{}".format(status.get("status", "unknown"),
                    status.get("exitstatus", "pending"), "\n".join(row.get("t", "") for row in log))
        self.work(read, lambda text: self.text_window("Task · " + task["upid"], text))

    def full_page(self):
        description = label(
            "Open the complete management interface in an app window. This includes machine creation, "
            "consoles, hardware, networking, storage configuration, restores, replication, HA, firewall, "
            "users and permissions.\n\n"
            "These tools currently use the server's existing interface. The native screens cover the "
            "dashboard, inventory, power actions, migration, snapshots, backups and task logs. "
            "A separate sign-in is required in the full interface.", "subtitle")
        description.set_line_wrap(True)
        description.set_max_width_chars(85)
        self.content.pack_start(description, False, False, 16)
        self.content.pack_start(button("Open full management", lambda *_: self.open_full(), True), False, False, 0)

    def open_full(self):
        if self.demo:
            self.message("Full management needs a real node", "Preview mode contains only sample native screens. Connect to a node to use the complete server interface.")
            return
        if not self.pin:
            self.connect_dialog()
            return
        # WebKit is loaded only for compatibility tools, never for native screens.
        try:
            from .advanced import open_window
        except (ImportError, ValueError):
            self.message("Install the full management component", "Install gir1.2-webkit2-4.1 to use the complete server interface.")
            return
        self.work(lambda: logic.fetch_peer_cert(api.endpoint(self.url)[1], api.endpoint(self.url)[2]),
                  lambda peer: self.full_verified(peer, open_window))

    def full_verified(self, peer, opener):
        if not peer or peer[2] != api.fingerprint(self.pin):
            self.message("Connection refused", "The node certificate does not match the pinned fingerprint.")
            return
        self.full_windows.append(opener(self.window, self.url, self.pin, peer[1]))

    def close_full_windows(self):
        for window in self.full_windows:
            window.destroy()
        self.full_windows.clear()

    def about(self):
        dialog = Gtk.AboutDialog(transient_for=self.window, modal=True,
                                program_name="SuperMox Manager", version="10.26.1",
                                logo_icon_name="supermox-manager",
                                comments="Native desktop management for SuperMox.\nBased on the Proxmox VE / PXVIRT ecosystem (AGPL-3.0).",
                                website="https://supermox.me", license_type=Gtk.License.AGPL_3_0)
        dialog.run()
        dialog.destroy()

    def close(self, *_args):
        self.closed = True
        self.generation += 1
        if hasattr(self, "timer"):
            GLib.source_remove(self.timer)
        self.close_full_windows()
        if self.client:
            self.client.logout()
        width, height = self.window.get_size()
        self.settings.update(width=width, height=height)
        logic.save_settings(self.settings)
        Gtk.main_quit()


def run(args):
    url = args.url or logic.node_url(logic.LOCAL_HOST)
    pin = args.fingerprint or (logic.pin_local() if not args.url else None)
    nodes = []
    # A standalone remote client does not depend on supermox-ve or private keys.
    if not args.url and not args.demo:
        nodes = logic.discover_nodes()
        chosen = next((node for node in nodes if node[0] == args.node), None)
        if chosen:
            _, url, pin = chosen
    Manager(url, pin, args.demo, nodes)
    Gtk.main()
    return 0
