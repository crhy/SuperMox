"""Pools: resource pools and the machines inside them.

Pools live under /pools. Every endpoint and parameter name was read from the
running node with `pvesh usage` (see .strata/notes-t75-manager-backup-jobs-
ha.md); nothing is guessed. A pool is identified by ``poolid``. The list
endpoint GET /pools returns only the name and comment; the members come from
GET /pools/{poolid} as a ``members`` list of full objects (a guest carries
``vmid``, a storage carries ``storage``). A pool cannot be deleted while it
still has members, so detach them first; the node enforces this and the form
here says so. The Members tab shows the members of the pool selected on the
Pools tab.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from ._view import deliver, table
from ._view import selected as _selected
from ..ops import pools

TITLE = "Pools"
SUBTITLE = "Resource pools and the machines inside them."

TABS = ("Pools", "Members")


def _pools_rows(manager, box, rows):
    manager.pool_map = {row["poolid"]: row for row in rows}
    manager.sel_pool = None

    def pick(view, path, _c):
        manager.sel_pool = manager.pool_map.get(view.get_model()[path][0])

    if not rows:
        box.pack_start(Gtk.Label(label="No resource pools. Create one below."),
                       False, False, 6)
        return
    table(box, ("Pool", "Comment"),
          [(row["poolid"], row.get("comment", "")) for row in rows],
          select=pick)


def _load_pools(manager):
    manager.work(lambda: pools.pools(manager.client),
                 deliver(manager, "pool_results", TITLE, "Pools", _pools_rows))


def _members_rows(manager, box, rows):
    if not rows:
        box.pack_start(Gtk.Label(label="This pool has no members."), False, False, 6)
        return
    table(box, ("Kind", "Id"), [(kind, ident) for kind, ident in rows])


def _load_members(manager):
    pool = _selected(manager, "sel_pool", "pool", "Pools")
    if not pool:
        return
    manager.work(lambda: pools.pool(manager.client, pool["poolid"]),
                 deliver(manager, "pool_results", TITLE, "Members",
                         lambda m, box, record: _members_rows(
                             m, box, pools.pool_members(record or {}))))


def _create_pool(manager):
    values = manager.form(
        "Create a pool",
        [("poolid", "Pool name (letters, digits, . _ -)", "team", False),
         ("comment", "Comment", "", False)],
        "Create",
        "Creates a new resource pool. The name may only contain letters, digits, "
        "dots, dashes and underscores.")
    if values is None:
        return
    if not values["poolid"].strip():
        manager.message("Check the fields", "Give the pool a name.")
        return
    options = {}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    client = manager.client
    manager.work(lambda: pools.create_pool(client, values["poolid"].strip(), **options),
                 lambda _r: (manager.status.set_text("Created pool " + values["poolid"].strip()),
                             _load_pools(manager)))


def _add_members(manager):
    pool = _selected(manager, "sel_pool", "pool", "Pools")
    if not pool:
        return
    values = manager.form(
        "Add members to {}".format(pool["poolid"]),
        [("vms", "Machine IDs (comma separated)", "", False)],
        "Add",
        "Adds the listed guests to this pool. Give guest ids separated by commas.")
    if values is None:
        return
    if not values["vms"].strip():
        manager.message("Check the fields", "Give at least one machine id.")
        return
    client = manager.client
    manager.work(lambda: pools.add_members(client, pool["poolid"], vms=values["vms"]),
                 lambda _r: (manager.status.set_text("Added members to " + pool["poolid"]),
                             _load_pools(manager)))


def _remove_members(manager):
    pool = _selected(manager, "sel_pool", "pool", "Pools")
    if not pool:
        return
    values = manager.form(
        "Remove members from {}".format(pool["poolid"]),
        [("vms", "Machine IDs (comma separated)", "", False)],
        "Remove",
        "Detaches the listed guests from this pool. The guests themselves are kept.")
    if values is None:
        return
    if not values["vms"].strip():
        manager.message("Check the fields", "Give at least one machine id.")
        return
    client = manager.client
    manager.work(lambda: pools.remove_members(client, pool["poolid"], vms=values["vms"]),
                 lambda _r: (manager.status.set_text("Removed members from " + pool["poolid"]),
                             _load_pools(manager)))


def _delete_pool(manager):
    pool = _selected(manager, "sel_pool", "pool", "Pools")
    if not pool:
        return
    if not manager.confirm("Delete pool {}?".format(pool["poolid"]),
                           "Remove this pool. It must have no members left. This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: pools.delete_pool(client, pool["poolid"]),
                 lambda _r: (manager.status.set_text("Deleted pool " + pool["poolid"]),
                             _load_pools(manager)))


DESCRIPTIONS = {
    "Pools": "Create, change membership and delete pools. Double-click a row to "
             "select it for add, remove, delete or to show its members.",
    "Members": "The members inside the pool selected on the Pools tab.",
}

ACTIONS = {
    "Pools": (("Pools", lambda m: _load_pools(m)),
              ("Create pool", _create_pool),
              ("Add members", _add_members),
              ("Remove members", _remove_members),
              ("Delete pool", _delete_pool)),
    "Members": (("Members", lambda m: _load_members(m)),),
}


def render(manager, content):
    from ..app import label
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
    manager.pool_results = {}
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
        manager.pool_results[name] = results
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
