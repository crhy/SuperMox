"""Container templates and container creation (no GTK).

Every path and parameter name below was read from the running node with
`pvesh usage /nodes/{node}/lxc --verbose` and `pvesh usage /nodes/{node}/aplinfo
--verbose`; nothing is guessed. ct_params() is pure so the unit tests can check
the exact POST body without a server. The root password only ever travels in
that body - never in a note, a log or a status line.
"""

import re

from .. import api

# A single DNS label (the server's dns-name format, one label): alphanumerics
# and hyphens, not starting or ending with a hyphen, at most 63 characters.
_LABEL_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$")
# A storage id or bridge name: a simple token, so it cannot be confused with
# the volid / rootfs / net0 syntax we build around it.
_TOKEN_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9-_]*$")

# An appliance name from the aplinfo index, e.g. alpine-3.24-default_20260714_amd64.tar.xz
_TEMPLATE_RE = re.compile(r"^[A-Za-z0-9._-]+$")
# An ostemplate is either a vztmpl volid in a storage or an absolute path.
_VZTMPL_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9-_]*:vztmpl/[A-Za-z0-9._/-]+$")
_ABS_PATH_RE = re.compile(r"^/[A-Za-z0-9._/-]+$")

# pvesh: --memory <integer> (16 - N), --cores <integer> (1 - 8192).
MEMORY_MIN = 16
CORES_MAX = 8192


def template_storages(client, node):
    """Return the storage ids on a node that may hold templates (vztmpl)."""
    items = client.request("GET", "/nodes/{}/storage".format(api.segment(node)))
    allowed = []
    for item in items:
        storage = item.get("storage")
        content = (item.get("content") or "").split(",")
        if storage and "vztmpl" in [part.strip() for part in content]:
            allowed.append(storage)
    return allowed


def available_templates(client, node):
    """GET /nodes/{node}/aplinfo: the appliance index pveam can download."""
    items = client.request("GET", "/nodes/{}/aplinfo".format(api.segment(node)))
    out = []
    for item in items:
        template = item.get("template")
        if template:
            out.append({
                "template": template,
                "os": item.get("os", ""),
                "architecture": item.get("architecture", ""),
                "section": item.get("section", ""),
                "headline": item.get("headline", ""),
                "package": item.get("package", ""),
            })
    return out


def download_template(client, node, storage, template):
    """POST /nodes/{node}/aplinfo: download one template; returns its UPID."""
    if not template or not _TEMPLATE_RE.match(template) or not _TOKEN_RE.match(storage or ""):
        raise ValueError("Pick a template and a storage that exist on this node.")
    path = "/nodes/{}/aplinfo".format(api.segment(node))
    return client.request("POST", path, {"storage": storage, "template": template})


def templates(client, node):
    """Return the template volids already downloaded on this node.

    Reads every storage whose content list allows vztmpl, so the answer covers
    all the places a template can legally live.
    """
    found = []
    for storage in template_storages(client, node):
        path = "/nodes/{}/storage/{}/content".format(api.segment(node),
                                                     api.segment(storage))
        items = client.request("GET", path, {"content": "vztmpl"})
        for item in items:
            if item.get("volid"):
                found.append(item["volid"])
    return sorted(found)


def ct_params(values):
    """Turn the wizard's answers into the exact create-ct parameter set.

    Expected keys: hostname, template (a volid), storage, size (GB), memory,
    cores, bridge, password, ssh_keys. Raises ValueError with a plain-language
    message for anything the server would reject.
    """
    values = values or {}

    hostname = (values.get("hostname") or "").strip()
    if not hostname:
        raise ValueError("A container needs a host name.")
    if not _LABEL_RE.match(hostname):
        raise ValueError(
            "The host name must be one label: letters and digits, hyphens only "
            "in the middle, at most 63 characters.")
    if len(hostname) > 63:
        raise ValueError("The host name must be at most 63 characters.")

    template = (values.get("template") or "").strip()
    if not (_VZTMPL_RE.match(template) or _ABS_PATH_RE.match(template)):
        raise ValueError("Pick a template that is downloaded in a storage.")

    storage = (values.get("storage") or "").strip()
    if not storage or not _TOKEN_RE.match(storage):
        raise ValueError("Pick a storage that exists on this node.")

    size = int(values.get("size") or 0)
    if size < 1:
        raise ValueError("The root filesystem must be at least 1 GB.")

    memory = int(values.get("memory") or 0)
    if memory < MEMORY_MIN:
        raise ValueError("Memory must be at least {} MB.".format(MEMORY_MIN))

    cores = int(values.get("cores") or 0)
    if cores < 1 or cores > CORES_MAX:
        raise ValueError("Choose between 1 and {} cores.".format(CORES_MAX))

    params = {
        "hostname": hostname,
        "ostemplate": template,
        "rootfs": "{}:{}".format(storage, size),
        "memory": memory,
        "cores": cores,
        "unprivileged": 1,
    }

    bridge = (values.get("bridge") or "").strip()
    if bridge and not _TOKEN_RE.match(bridge):
        raise ValueError("The bridge name is not valid.")
    if bridge:
        # pvesh: --net[n] name=<string>[,bridge=<bridge>][,ip=<(IPv4/CIDR|dhcp|manual)>]
        params["net0"] = "name=eth0,bridge={},ip=dhcp".format(bridge)

    password = values.get("password")
    if password:
        params["password"] = password
    ssh_keys = (values.get("ssh_keys") or "").strip()
    if ssh_keys:
        params["ssh-public-keys"] = ssh_keys
    return params


def create_ct(client, node, vmid, params):
    """POST /nodes/{node}/lxc: create a container; returns its task UPID."""
    vmid = int(vmid)
    if vmid < 100 or vmid > 999999999:
        raise ValueError("The VMID must be between 100 and 999999999.")
    path = "/nodes/{}/lxc".format(api.segment(node))
    return client.request("POST", path, dict(params, vmid=vmid))


def start_ct(client, node, vmid):
    """POST /nodes/{node}/lxc/{vmid}/status/start; returns its task UPID."""
    path = "/nodes/{}/lxc/{}/status/start".format(api.segment(node), int(vmid))
    return client.request("POST", path, {})


def stop_ct(client, node, vmid):
    """POST /nodes/{node}/lxc/{vmid}/status/stop; returns its task UPID."""
    path = "/nodes/{}/lxc/{}/status/stop".format(api.segment(node), int(vmid))
    return client.request("POST", path, {})
