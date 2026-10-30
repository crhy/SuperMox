"""Guest (virtual machine / container) operations (no GTK).

Paths and parameter names follow the running node's own API (pvesh usage);
never guessed. Every call goes through client.request, which pins TLS.
"""

from .. import api


def next_id(client):
    """GET /cluster/nextid: the next free guest id."""
    return client.request("GET", "/cluster/nextid")


def create_vm(client, node, vmid, name, memory=512, cores=1, extra=None):
    """POST /nodes/{node}/qemu: create a virtual machine; returns its UPID."""
    params = {"vmid": vmid, "name": name, "memory": memory, "cores": cores}
    if extra:
        params.update(extra)
    return client.request("POST", "/nodes/{}/qemu".format(api.segment(node)), params)


def destroy(client, node, kind, vmid):
    """DELETE /nodes/{node}/{kind}/{vmid} with purge=1; returns its UPID."""
    if kind not in ("qemu", "lxc"):
        raise ValueError("Select a virtual machine or container.")
    return client.request(
        "DELETE",
        "/nodes/{}/{}/{}".format(api.segment(node), kind, int(vmid)),
        {"purge": 1})


def status(client, node, kind, vmid):
    """GET /nodes/{node}/{kind}/{vmid}/status/current: the guest's live state."""
    if kind not in ("qemu", "lxc"):
        raise ValueError("Select a virtual machine or container.")
    return client.request(
        "GET",
        "/nodes/{}/{}/{}/status/current".format(api.segment(node), kind, int(vmid)))
