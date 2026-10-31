"""Disks: physical disk inventory, SMART health and data-directory usage.

All read-only: the Manager reports disk state but never writes partition tables
or formats anything. The disk list and directory usage are shown as tables;
double-clicking a disk row selects it so its SMART health can be fetched.
Parameter names come from `pvesh usage` (see .strata/notes-t73-manager-network-disks.md).
"""

from .. import api
from ..ops import disks

TITLE = "Disks"
SUBTITLE = "Physical disks and their health."


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _list(manager):
    return disks.disks(manager.client, _node(manager))


def _directories(manager):
    return disks.directories(manager.client, _node(manager))


def _show_disks(manager, rows):
    """Show the disk table and let a row be selected (GTK thread)."""
    from ..app import label
    manager.disk_map = {row["devpath"]: row for row in rows}
    manager.selected_disk = None
    manager.content.pack_start(
        label("{} disks · double-click a row to select it".format(len(rows)), "brand"),
        False, False, 6)
    tree = manager.table(("Device", "Type", "Health", "Model", "Size", "Used"),
                         [(row.get("devpath", ""), row.get("type", ""),
                           row.get("health", ""), row.get("model", ""),
                           api.human_bytes(row.get("size", 0)),
                           api.human_bytes(row.get("used", 0)) if isinstance(row.get("used"), (int, float)) else row.get("used", ""))
                          for row in rows])

    def activated(view, path, _column):
        model = view.get_model()
        manager.selected_disk = manager.disk_map.get(model[path][0])
    tree.connect("row-activated", activated)


def _show_directories(manager, rows):
    """Show per-mount data-directory usage (GTK thread)."""
    from ..app import label
    if not rows:
        manager.content.pack_start(label("No extra data mounts on this node."), False, False, 6)
        return
    manager.content.pack_start(label("{} data mounts".format(len(rows)), "brand"), False, False, 6)
    manager.table(("Device", "Mount", "Filesystem", "Used", "Capacity", "%"),
                  [(row.get("devpath", ""), row.get("mountpoint", ""),
                    row.get("fstype", ""), api.human_bytes(row.get("used_on_mnt", 0)),
                    api.human_bytes(row.get("size", 0)),
                    "{}%".format(row.get("used_percent", "")))
                   for row in rows])


def _smart(manager):
    disk = getattr(manager, "selected_disk", None)
    if not disk:
        manager.message("Select a disk first",
                        "Open the disk list and double-click the device you want the health of.")
        return
    node = _node(manager)
    manager.work(lambda: disks.smart(manager.client, node, disk["devpath"]),
                 lambda result: manager.text_window(
                     "SMART · {}".format(disk["devpath"]),
                     "Health: {}".format((result or {}).get("health", "unknown"))))


def render(manager, content):
    from ..app import button, label
    content.pack_start(label(
        "See this node's physical disks, their SMART health and data-directory usage. "
        "Open the disk list with the Disks button, double-click a device to select it, then read "
        "its SMART health. Nothing here changes a disk.", "subtitle"), False, False, 18)
    manager.content.pack_start(label("Physical disks", "brand"), False, False, 6)
    for text, callback in (("Disks", lambda *_: manager.work(
                               lambda: _list(manager), lambda rows: _show_disks(manager, rows))),
                           ("SMART health", lambda *_: _smart(manager)),
                           ("Data directories", lambda *_: manager.work(
                               lambda: _directories(manager),
                               lambda rows: _show_directories(manager, rows)))):
        content.pack_start(button(text, callback), False, False, 0)
