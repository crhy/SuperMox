"""Container templates.

Opening the page offers three actions: list the images this node already has
and the ones it could fetch, download one, and create a container from a
downloaded image. Every list is read from the node before the form is shown,
so the answers the form starts with are real.
"""

from ..ops import containers as ct_ops
from ..ops import create as create_ops
from ..ops import guests, tasks

TITLE = "Templates"
SUBTITLE = "Container images this node can build from."


def _node(manager):
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available on this cluster.")
    return node


def _index(manager):
    """Read the node's template state (runs off the GTK thread)."""
    node = _node(manager)
    return {"node": node,
            "downloaded": ct_ops.templates(manager.client, node),
            "available": ct_ops.available_templates(manager.client, node),
            "storages": ct_ops.template_storages(manager.client, node)}


def _options(manager):
    """Read what a new container can use (runs off the GTK thread)."""
    node = _node(manager)
    bridges = create_ops.bridges(manager.client, node)
    return {"node": node,
            "nextid": guests.next_id(manager.client),
            "downloaded": ct_ops.templates(manager.client, node),
            "storages": ct_ops.template_storages(manager.client, node),
            "bridge": bridges[0] if bridges else ""}


def _show(manager, index):
    """Show both lists as tables (GTK thread)."""
    from ..app import label
    manager.content.pack_start(
        label("Downloaded on node {} ({}) · storages: {}".format(
            index["node"], len(index["downloaded"]),
            ", ".join(index["storages"]) or "none"), "brand"), False, False, 6)
    manager.table(("Template",), [(volid,) for volid in index["downloaded"]])
    manager.content.pack_start(
        label("Available to download ({} images)".format(len(index["available"])), "brand"),
        False, False, 6)
    manager.table(("System", "Architecture", "Image", "Headline"),
                  [(row["os"], row["architecture"], row["template"], row["headline"])
                   for row in index["available"]])


def _download(manager, index):
    """Pick one image and fetch it into a storage (GTK thread)."""
    if not index["available"]:
        manager.message("Nothing to download",
                        "This node's image index is empty. Ask the node to refresh it, then list again.")
        return
    if not index["storages"]:
        manager.message("No storage for images",
                        "No storage on this node accepts container images.")
        return
    names = [row["template"] for row in index["available"]]
    fields = [("image", "Image", names[0], False),
              ("storage", "Storage", index["storages"][0], False)]
    values = manager.form(
        "Download a container template", fields, "Download",
        "The node fetches the image into its storage. Type the exact name of one of the "
        "{} images listed; the download runs as a task on the node.".format(len(names)))
    if values is None:
        return
    node = index["node"]
    manager.work(lambda: ct_ops.download_template(manager.client, node,
                                                  values["storage"], values["image"]),
                 lambda task: manager.submitted(task, node))


def _create(manager, options):
    """Show the prefilled form, then create the container (GTK thread)."""
    if not options["downloaded"]:
        manager.message("No image downloaded",
                        "A container is built from a downloaded image. Download one first.")
        return
    fields = [
        ("vmid", "VMID", options["nextid"], False),
        ("hostname", "Host name", "", False),
        ("template", "Template", options["downloaded"][0], False),
        ("storage", "Storage", options["storages"][0] if options["storages"] else "", False),
        ("size", "Root size (GB)", 1, False),
        ("memory", "Memory (MB)", 64, False),
        ("cores", "Cores", 1, False),
        ("bridge", "Bridge (optional)", options["bridge"], False),
        ("password", "Password (optional)", "", True),
        ("ssh_keys", "Public SSH keys (optional)", "", True),
    ]
    values = manager.form(
        "New container", fields, "Create",
        "The container is created on node {} from an image already in its storage. "
        "Leave the bridge empty on a node with no bridge interfaces.".format(options["node"]))
    if values is None:
        return
    try:
        params = ct_ops.ct_params(values)
    except ValueError as exc:
        manager.message("Check the fields", str(exc))
        return
    node = options["node"]
    vmid = int(values["vmid"]) if values["vmid"].strip() else options["nextid"]
    manager.work(lambda: ct_ops.create_ct(manager.client, node, vmid, params),
                 lambda task: manager.submitted(task, node))


def render(manager, content):
    from ..app import button, label
    content.pack_start(label("A container is built from an image in a storage. List what this "
                             "node has, download one, or create a container from it.", "subtitle"),
                       False, False, 18)
    content.pack_start(button("List templates",
                              lambda *_: manager.work(_index, lambda result: _show(manager, result))),
                       False, False, 0)
    content.pack_start(button("Download template",
                              lambda *_: manager.work(_index, lambda result: _download(manager, result))),
                       False, False, 0)
    content.pack_start(button("New container",
                              lambda *_: manager.work(_options, lambda result: _create(manager, result))),
                       False, False, 0)
