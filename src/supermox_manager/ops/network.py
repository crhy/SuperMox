"""Native network configuration (no GTK).

Every path and parameter name below was read from the running node with
`pvesh usage /nodes/{node}/network` (recorded in .strata/notes-t73-manager-network-disks.md);
nothing is guessed. Creating, updating or deleting an interface edits the pending
/etc/network/interfaces.new; the change only becomes live after the apply call
(PUT /nodes/{node}/network), which returns a task UPID to wait on. On Devuan the
upstream ifupdown2 version gate is relaxed by patches/pve-manager/0005-network-ifupdown2-devuan.patch
so the apply succeeds.
"""

from .. import api


def interfaces(client, node):
    """GET /nodes/{node}/network: the committed interfaces on a node."""
    return client.request("GET", "/nodes/{}/network".format(api.segment(node)))


def _params(iface=None, type=None, cidr=None, bridge_ports=None, bridge_fd=None,
            bridge_stp=None, autostart=None, comments=None, address=None, netmask=None,
            families=None, method=None, method6=None, priority=None):
    params = {}
    if iface is not None:
        params["iface"] = iface
    if type is not None:
        params["type"] = type
    if cidr is not None:
        params["cidr"] = cidr
    if bridge_ports is not None:
        params["bridge_ports"] = bridge_ports
    if bridge_fd is not None:
        params["bridge_fd"] = bridge_fd
    if bridge_stp is not None:
        params["bridge_stp"] = bridge_stp
    if autostart is not None:
        params["autostart"] = int(autostart)
    if comments is not None:
        params["comments"] = int(comments)
    if address is not None:
        params["address"] = address
    if netmask is not None:
        params["netmask"] = netmask
    if families is not None:
        params["families"] = families
    if method is not None:
        params["method"] = method
    if method6 is not None:
        params["method6"] = method6
    if priority is not None:
        params["priority"] = priority
    return params


def create(client, node, iface, type, **options):
    """POST /nodes/{node}/network: add an interface to the pending config.

    ``iface`` and ``type`` are required. ``type`` is one of the ifupdown2 kinds
    (manual, bridge, eth, vlan, tunnel, ...). Optional options (cidr, bridge_ports,
    bridge_fd, bridge_stp, autostart, comments, address, netmask, families, method,
    method6, priority) are passed straight through. Returns the created interface
    (this build returns null; read it back with interfaces() after apply()).
    """
    if not iface:
        raise ValueError("Give an interface name.")
    if not type:
        raise ValueError("Give an interface type.")
    params = _params(iface=iface, type=type, **options)
    return client.request("POST", "/nodes/{}/network".format(api.segment(node)), params)


def update(client, node, iface, **options):
    """PUT /nodes/{node}/network/{iface}: change a stored interface's config.

    The interface is named in the path, not the body. The API still requires
    the interface ``type`` in the body, so pass it (e.g. type="eth") alongside
    the settings being changed. Edits the pending config; call apply() to make
    it live. Returns null on success.
    """
    if not iface:
        raise ValueError("Give an interface name.")
    params = _params(**options)
    path = "/nodes/{}/network/{}".format(api.segment(node), api.segment(iface))
    return client.request("PUT", path, params)


def delete(client, node, iface):
    """DELETE /nodes/{node}/network/{iface}: drop the interface from the config."""
    if not iface:
        raise ValueError("Give an interface name.")
    path = "/nodes/{}/network/{}".format(api.segment(node), api.segment(iface))
    return client.request("DELETE", path, {})


def apply(client, node, regenerate_frr=False):
    """PUT /nodes/{node}/network: commit interfaces.new and reload networking.

    Returns a task UPID; wait on it with ops.tasks.wait_task(). ``regenerate_frr``
    (default 0) controls whether firewall rules (FRR) are regenerated.
    """
    params = {"regenerate-frr": int(bool(regenerate_frr))}
    return client.request("PUT", "/nodes/{}/network".format(api.segment(node)), params)
