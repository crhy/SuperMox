"""VM creation, cloning and template conversion (no GTK).

vm_params() is pure: it turns the wizard's answers into the exact create-vm
parameter set and refuses anything that would make the server reject the call.
The rest are thin API calls shared by the Create page and the live tests.
"""

import re

from .. import api
from . import guests

# A single DNS label: alphanumerics and hyphens, not starting or ending with a
# hyphen, at most 63 characters (the server's dns-name format, one label).
_LABEL_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$")
# A storage id or bridge name: a simple token, no separators we would confuse
# with the volid/bridge syntax we build around it.
_TOKEN_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9-_]*$")

# virtio-scsi-single is the controller we always ask for: it is the lightest
# virtio SCSI controller and the one the wizard's hardware choice maps to.
SCSIHW = "virtio-scsi-single"
# The server's ostype enum (QemuServer.pm). 'other' is the safe default.
OSTYPES = ("other", "wxp", "w2k", "w2k3", "w2k8", "wvista", "win7", "win8",
           "win10", "win11", "l24", "l26", "solaris")


def vm_params(name, memory, cores, disk_storage, disk_gb, iso="", bridge="",
              ostype="other"):
    """Build the create-vm params for a fresh VM.

    Returns a dict ready for guests.create_vm(extra=...). Raises ValueError
    with a plain-language message for anything invalid.
    """
    name = (name or "").strip()
    if not name:
        raise ValueError("A VM needs a name.")
    if len(name) > 63 or not _LABEL_RE.match(name):
        raise ValueError(
            "The name must be one label: letters and digits, hyphens only "
            "in the middle, at most 63 characters.")

    memory = int(memory)
    if memory < 1:
        raise ValueError("Memory must be at least 1 MB.")
    cores = int(cores)
    if cores < 1:
        raise ValueError("A VM needs at least one core.")

    disk_gb = int(disk_gb)
    if disk_gb < 1:
        raise ValueError("The disk must be at least 1 GB.")
    disk_storage = (disk_storage or "").strip()
    if not disk_storage or not _TOKEN_RE.match(disk_storage):
        raise ValueError("Pick a storage that exists on this node.")

    iso = (iso or "").strip()
    if iso and not _is_volid(iso):
        raise ValueError("The ISO must be a volume id from a storage.")

    bridge = (bridge or "").strip()
    if bridge and not _TOKEN_RE.match(bridge):
        raise ValueError("The bridge name is not valid.")

    ostype = (ostype or "other").strip()
    if ostype not in OSTYPES:
        raise ValueError("Unknown operating system type.")

    params = {
        "name": name,
        "memory": memory,
        "cores": cores,
        "ostype": ostype,
        "scsihw": SCSIHW,
        "scsi0": "{}:{}".format(disk_storage, disk_gb),
        "net0": "virtio" + (",bridge={}".format(bridge) if bridge else ""),
    }
    # Boot order: the disk first, then the ISO (only when one is attached) as
    # the removable CD, then the network. This is the order the wizard uses.
    order = ["scsi0"] + (["ide2"] if iso else []) + ["net0"]
    params["boot"] = "order=" + ";".join(order)
    if iso:
        params["ide2"] = "{},media=cdrom".format(iso)
    return params


def _is_volid(value):
    """A volid is either an absolute path or <storage>:<path>."""
    return value.startswith("/") or ":" in value


def create(client, node, vmid, params):
    """Create a VM from a full vm_params() result, reusing guests.create_vm."""
    params = dict(params)
    name = params.pop("name")
    memory = params.pop("memory")
    cores = params.pop("cores")
    return guests.create_vm(client, node, vmid, name, memory, cores, extra=params)


def storages(client, node):
    """Return the storage ids on a node."""
    items = client.request("GET", "/nodes/{}/storage".format(api.segment(node)))
    return [item["storage"] for item in items if item.get("storage")]


def isos(client, node, storage="local"):
    """Return the ISO volume ids available in a storage."""
    path = "/nodes/{}/storage/{}/content".format(api.segment(node),
                                                 api.segment(storage))
    items = client.request("GET", path, {"content": "iso"})
    return [item["volid"] for item in items if item.get("volid")]


def bridges(client, node):
    """Return the bridge names configured on a node."""
    items = client.request("GET", "/nodes/{}/network".format(api.segment(node)))
    return [item["bridge"] for item in items if item.get("bridge")]


def clone(client, node, vmid, newid, name=None, full=1):
    """Clone a VM into a new id; returns the task UPID."""
    params = {"newid": newid, "full": full}
    if name:
        params["name"] = name
    path = "/nodes/{}/qemu/{}/clone".format(api.segment(node), api.segment(vmid))
    return client.request("POST", path, params)


def make_template(client, node, vmid):
    """Convert a stopped VM into a template; returns the task UPID."""
    path = "/nodes/{}/qemu/{}/template".format(api.segment(node), api.segment(vmid))
    return client.request("POST", path, {})
