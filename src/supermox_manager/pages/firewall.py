"""Firewall: native rules, options, aliases and IP sets.

The firewall exists at three scopes and the same operations apply to all of
them; only the base path changes (see .strata/notes-t76-manager-firewall.md,
where every path and parameter name was read from the running node with
`pvesh usage`). A scope picker at the top of the page chooses the Datacenter
(/cluster/firewall), a node (/nodes/{node}/firewall) or one guest
(/nodes/{node}/{kind}/{vmid}/firewall); every tab then works on that scope.

Enabling the *datacenter* firewall is dangerous: it applies every rule to every
host, so the page warns that an incoming rule allowing the management ports
(8006 web, 22 ssh) should exist first, otherwise the administrator can be
locked out.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from ._view import deliver, table
from ._view import selected as _selected
from ..ops import firewall

TITLE = "Firewall"
SUBTITLE = "Rules, options, aliases and IP sets for the datacenter, a node or one guest."

TABS = ("Rules", "Options", "Aliases", "IP sets")


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _base(manager):
    """Return the firewall base path for the currently selected scope."""
    scope = getattr(manager, "fw_scope", "datacenter")
    if scope == "datacenter":
        return firewall.base_for()
    if scope == "node":
        return firewall.base_for(node=_node(manager))
    return firewall.base_for(node=_node(manager), kind=manager.fw_kind,
                             vmid=manager.fw_vmid)


def _scope_text(manager):
    scope = getattr(manager, "fw_scope", "datacenter")
    if scope == "datacenter":
        return "Datacenter (/cluster/firewall)"
    if scope == "node":
        return "Node {} (/nodes/{}/firewall)".format(_node(manager), _node(manager))
    return "Guest {} on {} (/nodes/{}/{}/firewall)".format(
        manager.fw_vmid, _node(manager), _node(manager), manager.fw_kind)


def _pick_datacenter(manager):
    manager.fw_scope = "datacenter"
    manager.status.set_text("Scope: Datacenter")


def _pick_node(manager):
    manager.fw_scope = "node"
    manager.status.set_text("Scope: node " + _node(manager))


def _pick_guest(manager):
    values = manager.form(
        "Choose a guest firewall",
        [("vmid", "Machine id (number)", "100", False)],
        "Choose",
        "Works on one machine's own firewall (/nodes/{node}/{kind}/{vmid}/firewall). "
        "The machine must already exist; its node and kind are read from the inventory.")
    if values is None:
        return
    vmid = values["vmid"].strip()
    guest = next((r for r in manager.resources
                  if r["type"] in ("qemu", "lxc") and str(r.get("vmid")) == vmid), None)
    if not guest:
        manager.message("Machine not found",
                        "No guest with id {} is in the inventory.".format(vmid))
        return
    manager.fw_scope = "guest"
    manager.fw_vmid = int(guest["vmid"])
    manager.fw_kind = guest["type"]
    manager.status.set_text("Scope: guest {} on {}".format(vmid, guest["node"]))


# --- Rules ----------------------------------------------------------------

def _rules_rows(manager, box, rows):
    manager.fw_rule_map = {index: row for index, row in enumerate(rows)}
    manager.sel_rule = None
    if not rows:
        box.pack_start(Gtk.Label(label="No rules on this firewall scope."),
                       False, False, 6)
        return

    def pick(view, path, _c):
        model = view.get_model()
        pos = int(model[path][0])
        manager.sel_rule = (pos, manager.fw_rule_map.get(pos))

    table(box, ("Pos", "Action", "Type", "On", "Source", "Dest", "Proto",
                "Ports", "Comment"),
          [(index, row.get("action", ""), row.get("type", ""),
            "on" if row.get("enable", 1) else "off",
            row.get("source", ""), row.get("dest", ""), row.get("proto", ""),
            _ports(row), row.get("comment", ""))
           for index, row in enumerate(rows)],
          select=pick)


def _ports(row):
    parts = []
    if row.get("dport"):
        parts.append("dport " + str(row["dport"]))
    if row.get("sport"):
        parts.append("sport " + str(row["sport"]))
    return ", ".join(parts)


def _load_rules(manager):
    manager.work(lambda: firewall.rules(manager.client, _base(manager)),
                 deliver(manager, "fw_results", TITLE, "Rules", _rules_rows))


def _selected_rule(manager):
    rule = _selected(manager, "sel_rule", "rule", "Rules")
    if not rule:
        return None
    pos, row = rule
    if row is None:
        manager.message("Select a rule again",
                        "The selected rule is no longer in the list; double-click a row again.")
        return None
    return pos, row


def _rule_form(manager, title, rule):
    return manager.form(
        title,
        [("action", "Action (ACCEPT, DROP, REJECT or a group name)",
          rule.get("action", "ACCEPT") if rule else "ACCEPT", False),
         ("type", "Type (in, out, forward, group)",
          rule.get("type", "in") if rule else "in", False),
         ("source", "Source (IP/CIDR or alias)",
          rule.get("source", "") if rule else "", False),
         ("dest", "Destination (IP/CIDR or alias)",
          rule.get("dest", "") if rule else "", False),
         ("proto", "Protocol (tcp, udp, icmp, ...)",
          rule.get("proto", "") if rule else "", False),
         ("dport", "Destination port",
          str(rule.get("dport", "")) if rule else "", False),
         ("sport", "Source port",
          str(rule.get("sport", "")) if rule else "", False),
         ("comment", "Comment",
          rule.get("comment", "") if rule else "", False)],
        "Save",
        "A rule matches traffic and ACCEPTs, DROPs or REJECTs it. The type picks "
        "which traffic: 'in' is traffic coming in, 'out' going out, 'forward' "
        "traffic forwarded to a guest, 'group' applies a security group. Match "
        "it with source/dest (an IP, network or alias name), a protocol and/or "
        "ports. Leave a field empty to leave it unset.")


def _rule_options(values):
    options = {"action": values["action"].strip(), "type": values["type"].strip()}
    for key in ("source", "dest", "proto", "dport", "sport", "comment"):
        if values[key].strip():
            options[key] = values[key].strip()
    return options


def _add_rule(manager):
    values = manager.form(
        "Add a firewall rule",
        [("action", "Action (ACCEPT, DROP, REJECT or a group name)", "ACCEPT", False),
         ("type", "Type (in, out, forward, group)", "in", False),
         ("source", "Source (IP/CIDR or alias)", "", False),
         ("dest", "Destination (IP/CIDR or alias)", "", False),
         ("proto", "Protocol (tcp, udp, icmp, ...)", "", False),
         ("dport", "Destination port", "", False),
         ("sport", "Source port", "", False),
         ("comment", "Comment", "", False),
         ("pos", "Position (optional)", "", False)],
        "Add",
        "Creates a rule on the current scope. The type picks which traffic to "
        "match (in, out, forward or a group); match it with source/dest, a "
        "protocol and/or ports. Leave position empty to append the rule at the "
        "bottom.")
    if values is None:
        return
    options = _rule_options(values)
    if values["pos"].strip():
        options["pos"] = int(values["pos"].strip())
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.add_rule(client, base, **options),
                 lambda _r: (manager.status.set_text("Added rule"),
                             _load_rules(manager)))


def _edit_rule(manager):
    selected = _selected_rule(manager)
    if not selected:
        return
    pos, rule = selected
    values = _rule_form(manager, "Edit rule {}".format(pos), rule)
    if values is None:
        return
    options = _rule_options(values)
    if len(options) <= 2:
        manager.message("Nothing to change", "Give at least an action and type.")
        return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.update_rule(client, base, pos, **options),
                 lambda _r: (manager.status.set_text("Updated rule {}".format(pos)),
                             _load_rules(manager)))


def _move_rule(manager, direction):
    selected = _selected_rule(manager)
    if not selected:
        return
    pos, _rule = selected
    moveto = pos - 1 if direction == "up" else pos + 1
    if moveto < 0:
        manager.message("Already at the top", "This rule is first; it cannot move up.")
        return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.move_rule(client, base, pos, moveto),
                 lambda _r: (manager.status.set_text("Moved rule to {}".format(moveto)),
                             _load_rules(manager)))


def _enable_rule(manager):
    selected = _selected_rule(manager)
    if not selected:
        return
    pos, rule = selected
    enable = 0 if rule.get("enable", 1) else 1
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.update_rule(client, base, pos, enable=enable),
                 lambda _r: (manager.status.set_text(
                     "Rule {} {}".format(pos, "enabled" if enable else "disabled")),
                     _load_rules(manager)))


def _delete_rule(manager):
    selected = _selected_rule(manager)
    if not selected:
        return
    pos, rule = selected
    if not manager.confirm("Delete rule {}?".format(pos),
                           "Remove this {} {} rule from the {} firewall. This cannot be undone."
                           .format(rule.get("action", ""), rule.get("type", ""),
                                   _scope_text(manager))):
        return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.delete_rule(client, base, pos),
                 lambda _r: (manager.status.set_text("Deleted rule {}".format(pos)),
                             _load_rules(manager)))


# --- Options ---------------------------------------------------------------

def _options_rows(manager, box, options):
    if not options:
        box.pack_start(Gtk.Label(label="No options set on this firewall scope."),
                       False, False, 6)
        return
    table(box, ("Option", "Value"),
          [(key, value) for key, value in sorted(options.items()) if key != "digest"])


def _load_options(manager):
    manager.work(lambda: firewall.options(manager.client, _base(manager)),
                 deliver(manager, "fw_results", TITLE, "Options", _options_rows))


def _set_enable(manager, enable):
    scope = getattr(manager, "fw_scope", "datacenter")
    if enable and scope == "datacenter":
        if not manager.confirm(
                "Enable the datacenter firewall?",
                "Enabling the firewall cluster wide applies every rule to every host. "
                "Make sure an incoming rule already allows the management ports first: "
                "port 8006 (the web API) and port 22 (ssh). Without those allow rules "
                "you can lock yourself out of the administrator."):
            return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.set_options(client, base, enable=enable),
                 lambda _r: (manager.status.set_text(
                     "Firewall {}".format("enabled" if enable else "disabled")),
                     _load_options(manager)))


def _change_options(manager):
    values = manager.form(
        "Change firewall options",
        [("policy_in", "Default incoming policy (ACCEPT, DROP, REJECT)", "ACCEPT", False),
         ("policy_out", "Default outgoing policy (ACCEPT, DROP, REJECT)", "ACCEPT", False),
         ("policy_forward", "Default forward policy (ACCEPT, DROP)", "ACCEPT", False)],
        "Change",
        "Sets the default policies for traffic no rule matches. These apply to the "
        "datacenter and guest scopes; a node scope has no policy options (use the "
        "Rules and Enable controls there).")
    if values is None:
        return
    options = {}
    for key in ("policy_in", "policy_out", "policy_forward"):
        if values[key].strip():
            options[key] = values[key].strip()
    if not options:
        manager.message("Nothing to change", "Set at least one policy.")
        return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.set_options(client, base, **options),
                 lambda _r: (manager.status.set_text("Updated options"),
                             _load_options(manager)))


# --- Aliases -------------------------------------------------------------

def _aliases_rows(manager, box, rows):
    manager.fw_alias_map = {row["name"]: row for row in rows}
    manager.sel_alias = None
    if not rows:
        box.pack_start(Gtk.Label(label="No aliases on this firewall scope."),
                       False, False, 6)
        return

    def pick(view, path, _c):
        manager.sel_alias = manager.fw_alias_map.get(view.get_model()[path][0])

    table(box, ("Name", "CIDR", "Comment"),
          [(row.get("name", ""), row.get("cidr", ""), row.get("comment", ""))
           for row in rows],
          select=pick)


def _load_aliases(manager):
    manager.work(lambda: firewall.aliases(manager.client, _base(manager)),
                 deliver(manager, "fw_results", TITLE, "Aliases", _aliases_rows))


def _add_alias(manager):
    values = manager.form(
        "Add an alias",
        [("name", "Name (letters, digits, - _)", "t76a", False),
         ("cidr", "CIDR (e.g. 10.0.0.7 or 10.0.0.0/24)", "", False),
         ("comment", "Comment", "", False)],
        "Add",
        "An alias gives a name to an IP or network so rules can refer to it. "
        "The name must start with a letter and use only letters, digits, dashes "
        "and underscores.")
    if values is None:
        return
    if not values["cidr"].strip():
        manager.message("Check the fields", "Give the alias CIDR.")
        return
    options = {"name": values["name"].strip(), "cidr": values["cidr"].strip()}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.add_alias(client, base, **options),
                 lambda _r: (manager.status.set_text("Added alias " + options["name"]),
                             _load_aliases(manager)))


def _delete_alias(manager):
    alias = _selected(manager, "sel_alias", "alias", "Aliases")
    if not alias:
        return
    if not manager.confirm("Delete alias {}?".format(alias["name"]),
                           "Remove this alias from the {} firewall. Rules that use it "
                           "will stop matching. This cannot be undone."
                           .format(_scope_text(manager))):
        return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.delete_alias(client, base, alias["name"]),
                 lambda _r: (manager.status.set_text("Deleted alias " + alias["name"]),
                             _load_aliases(manager)))


# --- IP sets -------------------------------------------------------------

def _ipsets_rows(manager, box, rows):
    manager.fw_ipset_map = {row["name"]: row for row in rows}
    manager.sel_ipset = None
    if not rows:
        box.pack_start(Gtk.Label(label="No IP sets on this firewall scope."),
                       False, False, 6)
        return

    def pick(view, path, _c):
        manager.sel_ipset = manager.fw_ipset_map.get(view.get_model()[path][0])

    table(box, ("Name", "Comment"),
          [(row.get("name", ""), row.get("comment", "")) for row in rows],
          select=pick)


def _load_ipsets(manager):
    manager.work(lambda: firewall.ipsets(manager.client, _base(manager)),
                 deliver(manager, "fw_results", TITLE, "IP sets", _ipsets_rows))


def _add_ipset(manager):
    values = manager.form(
        "Add an IP set",
        [("name", "Name (letters, digits, - _)", "t76s", False),
         ("comment", "Comment", "", False)],
        "Add",
        "An IP set is a named list of addresses a rule can match against. Create "
        "the set here, then add members to it.")
    if values is None:
        return
    options = {"name": values["name"].strip()}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.add_ipset(client, base, **options),
                 lambda _r: (manager.status.set_text("Added IP set " + options["name"]),
                             _load_ipsets(manager)))


def _add_cidr(manager):
    ipset = _selected(manager, "sel_ipset", "IP set", "IP sets")
    if not ipset:
        return
    values = manager.form(
        "Add a member to {}".format(ipset["name"]),
        [("cidr", "CIDR (e.g. 10.0.0.7)", "", False),
         ("comment", "Comment", "", False),
         ("nomatch", "No-match (1 or 0)", "0", False)],
        "Add",
        "Adds an address to this IP set. A no-match entry excludes an address from "
        "the set.")
    if values is None:
        return
    if not values["cidr"].strip():
        manager.message("Check the fields", "Give the CIDR to add.")
        return
    options = {"cidr": values["cidr"].strip()}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    if values["nomatch"].strip() in ("1", "yes", "true"):
        options["nomatch"] = True
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.add_cidr(client, base, ipset["name"], **options),
                 lambda _r: (manager.status.set_text("Added member to " + ipset["name"]),
                             _load_ipsets(manager)))


def _delete_ipset(manager):
    ipset = _selected(manager, "sel_ipset", "IP set", "IP sets")
    if not ipset:
        return
    if not manager.confirm("Delete IP set {}?".format(ipset["name"]),
                           "Remove this IP set and its members from the {} firewall. "
                           "This cannot be undone.".format(_scope_text(manager))):
        return
    client, base = manager.client, _base(manager)
    manager.work(lambda: firewall.delete_ipset(client, base, ipset["name"], force=True),
                 lambda _r: (manager.status.set_text("Deleted IP set " + ipset["name"]),
                             _load_ipsets(manager)))


DESCRIPTIONS = {
    "Rules": "Add, edit, enable, move (Up/Down) and delete rules. Double-click a row to "
             "select it.",
    "Options": "Enable or disable this firewall and set its default policies. Enabling the "
               "datacenter firewall warns about the management ports first.",
    "Aliases": "Named IPs and networks rules can refer to. Add and delete aliases; double-click "
               "a row to select it.",
    "IP sets": "Named lists of addresses. Add a set, add members to a selected set, or delete "
               "a set; double-click a row to select it.",
}

ACTIONS = {
    "Rules": (("Rules", lambda m: _load_rules(m)),
              ("Add rule", _add_rule),
              ("Edit rule", _edit_rule),
              ("Enable rule", _enable_rule),
              ("Move up", lambda m: _move_rule(m, "up")),
              ("Move down", lambda m: _move_rule(m, "down")),
              ("Delete rule", _delete_rule)),
    "Options": (("Options", lambda m: _load_options(m)),
                ("Enable firewall", lambda m: _set_enable(m, 1)),
                ("Disable firewall", lambda m: _set_enable(m, 0)),
                ("Change options", _change_options)),
    "Aliases": (("Aliases", lambda m: _load_aliases(m)),
                ("Add alias", _add_alias),
                ("Delete alias", _delete_alias)),
    "IP sets": (("IP sets", lambda m: _load_ipsets(m)),
                ("Add IP set", _add_ipset),
                ("Add member", _add_cidr),
                ("Delete IP set", _delete_ipset)),
}


def render(manager, content):
    from ..app import label, button, box
    if not hasattr(manager, "fw_scope"):
        manager.fw_scope = "datacenter"
    manager.fw_results = {}

    picker = box(False, 8)
    for text, callback in (("Datacenter", lambda *_: _pick_datacenter(manager)),
                           ("Node", lambda *_: _pick_node(manager)),
                           ("Guest…", lambda *_: _pick_guest(manager))):
        picker.pack_start(button(text, callback,
                                 primary=(getattr(manager, "fw_scope", "datacenter") ==
                                          {"Datacenter": "datacenter",
                                           "Node": "node",
                                           "Guest…": "guest"}[text])),
                          False, False, 0)
    content.pack_start(picker, False, False, 0)
    content.pack_start(label("Scope: " + _scope_text(manager), "brand"), False, False, 0)

    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
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
        manager.fw_results[name] = results
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
