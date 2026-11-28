"""Shared fixture for the live tests.

Every live test owns its own objects: guest ids in 9900-9999, names
``t-<task>-*``, created at the start of the test and destroyed at the end.
Nothing here may depend on a guest left over from an earlier run - an
earlier version of these tests read whatever guests the node happened to
have, which both broke once the node was cleaned and left the leftovers
behind in the first place.

Not a test module (unittest discover only collects ``test*.py``).
"""

import unittest

from supermox_manager import api
from supermox_manager.ops import containers as ct_ops
from supermox_manager.ops import create as create_ops
from supermox_manager.ops import guests, tasks

# Newest Alpine system image; the exact name comes from the node's own index.
APPLIANCE_OS = "alpine"


def create_vm(client, node, vmid, name, memory=512, cores=1):
    """Create a VM we own and wait for the task to finish."""
    params = create_ops.vm_params(name, memory, cores, "local", 1)
    upid = create_ops.create(client, node, vmid, params)
    tasks.wait_task(client, node, upid, timeout=240)


def create_ct(client, node, vmid, name, password):
    """Create a container we own and wait for the task to finish.

    Snapshot-mode vzdump needs no guest agent, so a container is the
    reliable thing to back up on this VM.
    """
    params = ct_ops.ct_params({
        "hostname": name, "template": template(client, node),
        "storage": "local", "size": 1, "memory": 64, "cores": 1,
        "bridge": (create_ops.bridges(client, node) or [""])[0],
        "password": password})
    upid = ct_ops.create_ct(client, node, vmid, params)
    tasks.wait_task(client, node, upid, timeout=300)


def template(client, node):
    """Return a downloaded template volid, downloading Alpine if needed."""
    downloaded = ct_ops.templates(client, node)
    if downloaded:
        return sorted(downloaded)[0]
    rows = [row for row in ct_ops.available_templates(client, node)
            if row["os"] == APPLIANCE_OS]
    if not rows:
        raise unittest.SkipTest("no {} appliance in this node's index".format(
            APPLIANCE_OS))
    name = rows[-1]["template"]
    upid = ct_ops.download_template(client, node, "local", name)
    tasks.wait_task(client, node, upid, timeout=600)
    return "local:vztmpl/" + name


def destroy(client, node, kind, vmid):
    """Remove a guest we own; a guest that is not there is not an error."""
    try:
        upid = guests.destroy(client, node, kind, vmid)
        tasks.wait_task(client, node, upid, timeout=180)
    except api.APIError:
        pass
