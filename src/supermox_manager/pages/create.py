"""Create a virtual machine.

Opening the page offers one action. It first reads the node's real options
(the next free VMID, the storages, the ISOs, the bridges) so the form can
prefill sensible answers, then creates the machine and waits for the task.
"""

from ..ops import create as create_ops
from ..ops import guests, tasks

TITLE = "Create"
SUBTITLE = "Build a new virtual machine, step by step."


def _options(manager):
    """Read the node's create-time options (runs off the GTK thread)."""
    node = next((r["node"] for r in manager.resources if r["type"] == "node"), None)
    if not node:
        raise ValueError("No node is available to create a machine on.")
    storages = create_ops.storages(manager.client, node)
    isos = create_ops.isos(manager.client, node, storages[0]) if storages else []
    bridges = create_ops.bridges(manager.client, node)
    return {"node": node,
            "nextid": guests.next_id(manager.client),
            "storage": storages[0] if storages else "",
            "iso": isos[0] if isos else "",
            "bridge": bridges[0] if bridges else ""}


def _create(manager, options):
    """Show the prefilled form, then create the machine (GTK thread)."""
    fields = [
        ("vmid", "VMID", options["nextid"], False),
        ("name", "Name", "", False),
        ("memory", "Memory (MB)", 512, False),
        ("cores", "Cores", 1, False),
        ("disk_gb", "Disk size (GB)", 8, False),
        ("storage", "Storage", options["storage"], False),
        ("iso", "ISO (optional)", options["iso"], False),
        ("bridge", "Bridge (optional)", options["bridge"], False),
    ]
    values = manager.form("Create a virtual machine", fields, "Create",
                          "A fresh machine on node {}. Leave the ISO empty for an "
                          "empty machine you will install into later.".format(options["node"]))
    if values is None:
        return
    try:
        params = create_ops.vm_params(
            values["name"], values["memory"], values["cores"], values["storage"],
            values["disk_gb"], values["iso"], values["bridge"])
    except ValueError as exc:
        manager.message("Check the fields", str(exc))
        return
    node = options["node"]
    vmid = int(values["vmid"]) if values["vmid"].strip() else options["nextid"]
    manager.work(lambda: create_ops.create(manager.client, node, vmid, params),
                 lambda task: manager.submitted(task, node))


def render(manager, content):
    from ..app import button, label
    content.pack_start(label("Choose a name, size and storage, then create the machine. "
                             "The form starts with this node's next free VMID, first storage "
                             "and first ISO.", "subtitle"), False, False, 18)
    content.pack_start(button("Create virtual machine",
                              lambda *_: manager.work(_options, lambda result: _create(manager, result))),
                       False, False, 0)
