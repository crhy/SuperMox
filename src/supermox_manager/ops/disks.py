"""Disk inventory and SMART health (no GTK).

Paths and parameter names were read from the running node with `pvesh usage`
(recorded in .strata/notes-t73-manager-network-disks.md); nothing is guessed.
These endpoints are read-only: the Manager never writes partition tables or
formats disks. ``disk`` is a block device path such as /dev/vda.
"""

from .. import api


def disks(client, node):
    """GET /nodes/{node}/disks/list: the physical disks on a node.

    Fields include devpath, type, health, model, vendor, serial, size, used,
    mounted, rpm, wearout, wwn, gpt, osdid.
    """
    return client.request("GET", "/nodes/{}/disks/list".format(api.segment(node)))


def smart(client, node, disk, healthonly=False):
    """GET /nodes/{node}/disks/smart: SMART health for one block device.

    ``disk`` is a block device path (e.g. /dev/vda). ``healthonly`` returns just
    the health status instead of the full SMART report.
    """
    if not disk:
        raise ValueError("Give a block device such as /dev/vda.")
    params = {"disk": disk}
    if healthonly:
        params["healthonly"] = 1
    return client.request("GET", "/nodes/{}/disks/smart".format(api.segment(node)),
                          params)


def directories(client, node):
    """GET /nodes/{node}/disks/directory: per-mount usage of data directories.

    Returns a list of {devpath, fstype, label, mountpoint, size, used,
    used_on_mnt, used_percent, type}; empty when the node has no extra data
    mounts.
    """
    return client.request("GET", "/nodes/{}/disks/directory".format(api.segment(node)))
