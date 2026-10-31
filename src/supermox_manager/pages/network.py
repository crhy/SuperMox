"""Network: list, add, change, remove and reload a node's interfaces.

The page lists the committed interfaces, then offers actions that edit the
pending configuration. Every change (add, change, remove) is followed by the
apply call (PUT /nodes/{node}/network) which commits and reloads networking as
a task; the page waits on that task and re-reads the list. Nothing is guessed:
the parameter set comes from `pvesh usage` (see .strata/notes-t73-manager-network-disks.md).
"""

from .. import api
from ..ops import network, tasks

TITLE = "Network"
SUBTITLE = "Interfaces on this node."


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _list(manager):
    """Read the committed interfaces (off the GTK thread)."""
    return network.interfaces(manager.client, _node(manager))


def _show(manager, rows):
    """Show the interface list and let a row be selected (GTK thread)."""
    from ..app import label
    manager.iface_map = {row["iface"]: row for row in rows}
    manager.selected_iface = None
    manager.content.pack_start(
        label("{} interfaces · double-click a row to select it".format(len(rows)), "brand"),
        False, False, 6)
    tree = manager.table(("Interface", "Type", "State", "Address", "Autostart"),
                         [(row.get("iface", ""), row.get("type", ""),
                           "up" if row.get("active") else "down",
                           row.get("address", ""),
                           "yes" if row.get("autostart") else "no")
                          for row in rows])

    def activated(view, path, _column):
        model = view.get_model()
        manager.selected_iface = manager.iface_map.get(model[path][0])
    tree.connect("row-activated", activated)


def _selected_iface(manager):
    iface = getattr(manager, "selected_iface", None)
    if not iface:
        manager.message("Select an interface first",
                        "Open the interface list and double-click the one you want to change.")
    return iface


def _commit(manager, node, mutate, done_text):
    """Run a pending edit, then apply (reload) and wait, then re-read the list."""
    def run():
        mutate()
        upid = network.apply(manager.client, node)
        tasks.wait_task(manager.client, node, upid, timeout=120, allow_warnings=True)
        return network.interfaces(manager.client, node)
    manager.work(run, lambda rows: (manager.status.set_text(done_text), _show(manager, rows)))


def _add(manager):
    node = _node(manager)
    values = manager.form(
        "Add an interface",
        [("iface", "Interface name (e.g. vmbr0)", "vmbr98", False),
         ("type", "Type (eth, bridge, vlan, tunnel, ...)", "eth", False),
         ("cidr", "IPv4 CIDR for a bridge (e.g. 10.98.98.1/24)", "", False),
         ("address", "Static address (e.g. 10.98.98.1)", "", False),
         ("autostart", "Start at boot (1 or 0)", "1", False)],
        "Add",
        "Adds the interface to the pending configuration, then commits and reloads "
        "networking. A bridge needs a CIDR; a static interface needs an address.")
    if values is None:
        return
    if not values["iface"].strip() or not values["type"].strip():
        manager.message("Check the fields", "Give at least the interface name and type.")
        return
    options = {}
    for key in ("cidr", "address"):
        if values[key].strip():
            options[key] = values[key].strip()
    options["autostart"] = 1 if values["autostart"].strip() in ("1", "yes", "true") else 0

    def mutate():
        network.create(manager.client, node, values["iface"].strip(),
                       values["type"].strip(), **options)
    _commit(manager, node, mutate, "Added " + values["iface"].strip())


def _change(manager):
    iface = _selected_iface(manager)
    if not iface:
        return
    node = _node(manager)
    values = manager.form(
        "Change {}".format(iface["iface"]),
        [("autostart", "Start at boot (1 or 0)",
          "1" if iface.get("autostart") else "0", False)],
        "Change",
        "Updates this interface in the pending configuration, then commits and reloads "
        "networking.")
    if values is None:
        return
    options = {"type": iface.get("type") or "eth",
               "autostart": 1 if values["autostart"].strip() in ("1", "yes", "true") else 0}

    def mutate():
        network.update(manager.client, node, iface["iface"], **options)
    _commit(manager, node, mutate, "Updated " + iface["iface"])


def _remove(manager):
    iface = _selected_iface(manager)
    if not iface:
        return
    node = _node(manager)
    if not manager.confirm("Remove {}?".format(iface["iface"]),
                           "Drop this interface from the configuration and reload networking. "
                           "This cannot be undone."):
        return

    def mutate():
        network.delete(manager.client, node, iface["iface"])
    _commit(manager, node, mutate, "Removed " + iface["iface"])


def _reload(manager):
    node = _node(manager)
    if not manager.confirm("Reload the network?",
                           "Commit the pending configuration and reload every interface on "
                           "node {}. This briefly interrupts networking.".format(node)):
        return

    def run():
        upid = network.apply(manager.client, node)
        tasks.wait_task(manager.client, node, upid, timeout=120, allow_warnings=True)
        return network.interfaces(manager.client, node)
    manager.work(run, lambda rows: (manager.status.set_text("Reloaded networking"), _show(manager, rows)))


def render(manager, content):
    from ..app import button, label
    content.pack_start(label(
        "List this node's interfaces, then add, change, remove or reload them. Changes edit the "
        "pending configuration and are committed by a reload task. Open the interface list with "
        "the Interfaces button, then double-click a row to select it for change or remove.", "subtitle"), False, False, 18)
    manager.content.pack_start(label("Interfaces", "brand"), False, False, 6)
    for text, callback in (("Interfaces", lambda *_: manager.work(
                               lambda: _list(manager), lambda rows: _show(manager, rows))),
                           ("Add interface", lambda *_: _add(manager)),
                           ("Change interface", lambda *_: _change(manager)),
                           ("Remove interface", lambda *_: _remove(manager)),
                           ("Reload network", lambda *_: _reload(manager))):
        content.pack_start(button(text, callback), False, False, 0)
