"""Storage: capacity, content, uploads, downloads, backups and restores.

The page shows each storage's capacity from the inventory already in hand, then
offers actions that read or change stored files. Content listings are fetched
from the node before they are shown, and destructive actions (delete, restore)
ask for confirmation first. Volume ids travel in the URL path with ':' and '/'
intact, so the ops layer uses api.volume(); nothing here is guessed.
"""

import os

from .. import api
from ..ops import storage

TITLE = "Storage"
SUBTITLE = "Capacity and content across your cluster."


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _storages(manager):
    return [r for r in manager.resources if r["type"] == "storage"]


def _content(manager):
    """List every stored file across this node's storages (off the GTK thread)."""
    node = _node(manager)
    rows = []
    for entry in _storages(manager):
        for volume in storage.content(manager.client, node, entry["storage"]):
            row = dict(volume)
            row["node"] = node
            row["storage"] = entry["storage"]
            rows.append(row)
    return rows


def _show_content(manager, rows):
    """Show the content list and let a row be selected (GTK thread)."""
    from ..app import label
    manager.volume_map = {row["volid"]: row for row in rows}
    manager.selected_volume = None
    manager.content.pack_start(
        label("{} stored files · double-click a row to select it".format(len(rows)), "brand"),
        False, False, 6)
    tree = manager.table(("Storage", "Type", "Volume", "Size", "Used"),
                         [(row["storage"], row.get("type", ""), row.get("volid", ""),
                           api.human_bytes(row.get("size", 0)), row.get("used", ""))
                          for row in rows])

    def activated(view, path, _column):
        model = view.get_model()
        manager.selected_volume = manager.volume_map.get(model[path][2])
    tree.connect("row-activated", activated)


def _selected_volume(manager):
    volume = getattr(manager, "selected_volume", None)
    if not volume:
        manager.message("Select a volume first",
                        "Open the content list and double-click the volume you want to act on.")
    return volume


def _delete(manager):
    volume = _selected_volume(manager)
    if not volume:
        return
    if not manager.confirm("Delete {}?".format(volume["volid"]),
                           "Remove this stored file from {}. This cannot be undone."
                           .format(volume["storage"])):
        return
    node = volume["node"]
    manager.work(lambda: storage.delete_volume(manager.client, node, volume["storage"],
                                               volume["volid"]),
                 lambda _result: manager.status.set_text("Deleted " + volume["volid"]))


def _upload(manager):
    from gi.repository import Gtk
    chooser = Gtk.FileChooserDialog(title="Choose a file to upload", transient_for=manager.window,
                                    modal=True, action=Gtk.FileChooserAction.OPEN)
    chooser.add_button("Cancel", Gtk.ResponseType.CANCEL)
    chooser.add_button("Upload", Gtk.ResponseType.OK)
    chooser.set_default_size(640, 420)
    path = chooser.run_simple()
    chooser.destroy()
    if not path:
        return
    names = [entry["storage"] for entry in _storages(manager)]
    values = manager.form(
        "Upload a file",
        [("storage", "Storage", names[0] if names else "", False),
         ("content", "Content type (iso, vztmpl, import)", "iso", False)],
        "Upload",
        "The file streams to node {}'s storage in 1 MiB chunks. Pick a content type "
        "the storage accepts.".format(_node(manager)))
    if values is None:
        return
    node = _node(manager)
    content_type = values["content"].strip() or None

    def send():
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            return storage.upload(manager.client, node, values["storage"],
                                  os.path.basename(path), handle, size,
                                  content_type=content_type)
    manager.work(send, lambda task: manager.submitted(task, node))


def _download(manager):
    names = [entry["storage"] for entry in _storages(manager)]
    values = manager.form(
        "Download a URL into storage",
        [("url", "URL (https://...)", "", False),
         ("storage", "Storage", names[0] if names else "", False),
         ("filename", "File name", "", False),
         ("content", "Content type (iso, vztmpl, import)", "iso", False)],
        "Download",
        "The node fetches the URL into its storage as a task. Give the exact file name "
        "to store it under.")
    if values is None:
        return
    if not values["url"].strip() or not values["filename"].strip():
        manager.message("Check the fields", "Give both the URL and the file name.")
        return
    node = _node(manager)
    manager.work(lambda: storage.download_url(
        manager.client, node, values["storage"], values["url"].strip(),
        values["filename"].strip(), content_type=values["content"].strip() or None),
                 lambda task: manager.submitted(task, node))


def _backup(manager):
    guests = [r for r in manager.resources if r["type"] in ("qemu", "lxc")]
    if not guests:
        manager.message("No machines to back up", "This node has no guests to back up.")
        return
    names = [entry["storage"] for entry in _storages(manager)]
    values = manager.form(
        "Back up a machine",
        [("vmid", "Machine ID", guests[0]["vmid"], False),
         ("storage", "Backup storage", names[0] if names else "", False),
         ("mode", "Mode (snapshot, stop, suspend)", "snapshot", False)],
        "Back up",
        "Creates a backup of the machine on the chosen storage. snapshot uses disk "
        "snapshots where supported.")
    if values is None:
        return
    node = _node(manager)
    manager.work(lambda: storage.backup(manager.client, node, int(values["vmid"]),
                                        storage=values["storage"], mode=values["mode"].strip()),
                 lambda task: manager.submitted(task, node))


def _restore(manager):
    volume = _selected_volume(manager)
    if not volume:
        return
    values = manager.form(
        "Restore a machine from a backup",
        [("vmid", "Machine ID to restore into", "", False),
         ("kind", "Kind (vm or ct)", "ct", False),
         ("volume", "Backup volume", volume["volid"], False)],
        "Restore",
        "Restores the backup into a machine on node {}. For a container the backup is "
        "used as a template; for a VM the whole disk image is restored. The target ID "
        "must be free."
        .format(_node(manager)))
    if values is None:
        return
    kind = {"vm": "qemu", "ct": "lxc"}.get(values["kind"].strip().lower())
    if kind is None:
        manager.message("Check the fields", "Kind must be vm or ct.")
        return
    node = _node(manager)
    manager.work(lambda: storage.restore(manager.client, node, kind, int(values["vmid"]),
                                         values["volume"].strip()),
                 lambda task: manager.submitted(task, node))


def render(manager, content):
    from ..app import button, label
    content.pack_start(label(
        "See each storage's capacity, list its files, upload or download files, and back up "
        "or restore a machine. Double-click a content row to select that volume for delete "
        "or restore.", "subtitle"), False, False, 18)
    entries = _storages(manager)
    if not entries:
        content.pack_start(label("No storage is available on this node."), False, False, 0)
        return
    manager.content.pack_start(label("Storage capacity", "brand"), False, False, 6)
    manager.table(("Storage", "Node", "State", "Used", "Capacity", "Content"),
                  [(entry["storage"], entry["node"], entry.get("status", ""),
                    api.human_bytes(entry.get("disk", 0)),
                    api.human_bytes(entry.get("maxdisk", 0)), entry.get("content", ""))
                   for entry in entries])
    for text, callback in (("List content", lambda *_: manager.work(
                                lambda: _content(manager), lambda rows: _show_content(manager, rows))),
                           ("Upload file", lambda *_: _upload(manager)),
                           ("Download URL", lambda *_: _download(manager)),
                           ("Delete volume", lambda *_: _delete(manager)),
                           ("Back up now", lambda *_: _backup(manager)),
                           ("Restore", lambda *_: _restore(manager))):
        content.pack_start(button(text, callback), False, False, 0)
