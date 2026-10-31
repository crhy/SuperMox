"""HA: high availability resources, rules and live status.

HA lives under /cluster/ha. Every endpoint and parameter name was read from
the running node with `pvesh usage` (see .strata/notes-t75-manager-backup-
jobs-ha.md); nothing is guessed. A resource id keeps its colon in the URL path
(vm:100), so the ops layer uses api.volume(). A resource can only be added for
a guest that already exists. This version has replaced the old HA *groups*
with *rules*, and a rule must name the resources it applies to. The Status
tab reads the cluster's current decision (one row per node and quorum check).
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from ._view import deliver, table
from ._view import selected as _selected
from ..ops import ha

TITLE = "HA"
SUBTITLE = "Highly available resources, rules and cluster status."

TABS = ("Resources", "Rules", "Status")


def _resources_rows(manager, box, rows):
    manager.ha_resource_map = {row["sid"]: row for row in rows}
    manager.sel_resource = None

    def pick(view, path, _c):
        manager.sel_resource = manager.ha_resource_map.get(view.get_model()[path][0])

    if not rows:
        box.pack_start(Gtk.Label(label="No resources are under HA management."),
                       False, False, 6)
        return
    table(box, ("Resource", "Node", "State", "Managed", "Weight"),
          [(row["sid"], row.get("node", ""), row.get("state", ""),
           "yes" if row.get("managed") else "no", row.get("weight", ""))
           for row in rows],
          select=pick)


def _load_resources(manager):
    manager.work(lambda: ha.resources(manager.client),
                 deliver(manager, "ha_results", TITLE, "Resources", _resources_rows))


def _join(value):
    if isinstance(value, (list, tuple)):
        return ", ".join(str(v) for v in value)
    return str(value) if value else ""


def _rules_rows(manager, box, rows):
    manager.ha_rule_map = {row["rule"]: row for row in rows}
    manager.sel_rule = None

    def pick(view, path, _c):
        manager.sel_rule = manager.ha_rule_map.get(view.get_model()[path][0])

    if not rows:
        box.pack_start(Gtk.Label(label="No HA rules."), False, False, 6)
        return
    table(box, ("Rule", "Type", "Nodes", "Resources", "Affinity"),
          [(row["rule"], row.get("type", ""),
           _join(row.get("nodes")),
           _join(row.get("resources")),
           row.get("affinity", ""))
           for row in rows],
          select=pick)


def _load_rules(manager):
    manager.work(lambda: ha.rules(manager.client),
                 deliver(manager, "ha_results", TITLE, "Rules", _rules_rows))


def _status_rows(manager, box, rows):
    if not rows:
        box.pack_start(Gtk.Label(label="No HA status yet."), False, False, 6)
        return
    table(box, ("Node", "Check", "Status", "Detail"),
          [(row.get("node", ""), row.get("id", ""), row.get("status", ""),
           row.get("armed-state", ""))
           for row in rows])


def _load_status(manager):
    manager.work(lambda: ha.status(manager.client),
                 deliver(manager, "ha_results", TITLE, "Status", _status_rows))


def _add_resource(manager):
    values = manager.form(
        "Manage a resource for HA",
        [("vmid", "Machine id (number)", "100", False),
         ("kind", "Kind (vm or ct)", "vm", False),
         ("state", "State (enabled, disabled, ignored)", "enabled", False),
         ("comment", "Comment", "", False)],
        "Manage",
        "Puts an existing guest under HA management so the cluster keeps it "
        "running. The guest must already exist. State 'enabled' means the CRM "
        "will try to restart it if it fails.")
    if values is None:
        return
    client = manager.client
    options = {"kind": values["kind"].strip(), "state": values["state"].strip()}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    manager.work(lambda: ha.add_resource(client, values["vmid"].strip(), **options),
                 lambda _r: (manager.status.set_text("Managing " + values["kind"].strip()
                             + ":" + values["vmid"].strip()),
                             _load_resources(manager)))


def _change_resource(manager):
    resource = _selected(manager, "sel_resource", "resource", "Resources")
    if not resource:
        return
    values = manager.form(
        "Change HA for {}".format(resource["sid"]),
        [("state", "State (enabled, disabled, ignored)", resource.get("state", "enabled"), False),
         ("weight", "Weight (0.0 to 1.0, importance)", str(resource.get("weight", 1)), False),
         ("max_restart", "Max restarts", "", False)],
        "Change",
        "Updates this resource's state, importance and restart limit. Lower "
        "weight means the cluster may drop it first when it cannot keep "
        "everything running.")
    if values is None:
        return
    options = {"state": values["state"].strip()}
    if values["weight"].strip():
        options["weight"] = float(values["weight"].strip())
    if values["max_restart"].strip():
        options["max_restart"] = int(values["max_restart"].strip())
    client = manager.client
    manager.work(lambda: ha.update_resource(client, resource["sid"], **options),
                 lambda _r: (manager.status.set_text("Updated " + resource["sid"]),
                             _load_resources(manager)))


def _remove_resource(manager):
    resource = _selected(manager, "sel_resource", "resource", "Resources")
    if not resource:
        return
    if not manager.confirm("Stop managing {} for HA?".format(resource["sid"]),
                           "Take this resource out of HA management. The guest itself is kept. "
                           "This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: ha.remove_resource(client, resource["sid"]),
                 lambda _r: (manager.status.set_text("Stopped managing " + resource["sid"]),
                             _load_resources(manager)))


def _add_rule(manager):
    values = manager.form(
        "Add an HA rule",
        [("rule", "Rule name (letters, digits, . _ -)", "atlas-first", False),
         ("kind", "Type (node-affinity or resource-affinity)", "node-affinity", False),
         ("nodes", "Nodes (comma separated)", "", False),
         ("resources", "Resources (comma separated, e.g. vm:100)", "", False),
         ("affinity", "Affinity (positive or negative)", "positive", False)],
        "Add",
        "Adds a rule saying where resources may run. node-affinity prefers the "
        "listed nodes; resource-affinity pins the listed resources. Positive "
        "affinity means run on those nodes, negative means run anywhere else. "
        "On a single node the cluster cannot manage resources, so rules are "
        "only accepted once a second node is online.")
    if values is None:
        return
    if not values["nodes"].strip() or not values["resources"].strip():
        manager.message("Check the fields",
                        "A rule needs both the nodes and the resources it applies to.")
        return
    client = manager.client
    manager.work(lambda: ha.add_rule(client, values["rule"].strip(),
                                     values["kind"].strip(),
                                     nodes=values["nodes"], resources=values["resources"],
                                     affinity=values["affinity"].strip() or None),
                 lambda _r: (manager.status.set_text("Added rule " + values["rule"].strip()),
                             _load_rules(manager)))


def _remove_rule(manager):
    rule = _selected(manager, "sel_rule", "rule", "Rules")
    if not rule:
        return
    if not manager.confirm("Remove rule {}?".format(rule["rule"]),
                           "Delete this HA rule. This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: ha.remove_rule(client, rule["rule"]),
                 lambda _r: (manager.status.set_text("Removed rule " + rule["rule"]),
                             _load_rules(manager)))


DESCRIPTIONS = {
    "Resources": "Manage, change and unmanage highly available resources. Double-click "
                 "a row to select it for change or unmanage.",
    "Rules": "Rules saying where resources may run. Add and remove rules; double-click "
             "a row to select it.",
    "Status": "The cluster's current high availability decision (read-only).",
}

ACTIONS = {
    "Resources": (("Resources", lambda m: _load_resources(m)),
                  ("Manage", _add_resource),
                  ("Change resource", _change_resource),
                  ("Unmanage", _remove_resource)),
    "Rules": (("Rules", lambda m: _load_rules(m)),
              ("Add rule", _add_rule),
              ("Remove rule", _remove_rule)),
    "Status": (("Status", lambda m: _load_status(m)),),
}


def render(manager, content):
    from ..app import label
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
    manager.ha_results = {}
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
        manager.ha_results[name] = results
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
