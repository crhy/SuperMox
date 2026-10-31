"""Resource pools: named groups of machines and storages.

A pool is a container for members, not a setting: creating it is not enough,
members are attached with PUT /pools/{poolid} (``vms``/``storage`` lists) and
detached with the same call plus ``delete=1``. A pool cannot be deleted while
it still has members, so detach first.

Endpoints (read from `pvesh usage` on the running node):
  GET    /pools                    list pools
  GET    /pools/{poolid}           one pool, with its members
  POST   /pools                    create a pool
  PUT    /pools/{poolid}           add or remove members
  DELETE /pools/{poolid}           delete an empty pool
"""

import re

from .. import api

# The server rejects pool names with characters outside this set; the check
# here only keeps the id safe for the URL.
_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def _poolid(value):
    if not value or not _NAME_RE.fullmatch(str(value)):
        raise ValueError("A pool name may only contain letters, digits, dots, "
                         "dashes and underscores.")
    return str(value)


def _members(value):
    """Members travel as lists of ids, so one id still has to become a list."""
    if value in (None, ""):
        return []
    if isinstance(value, str):
        value = value.split(",")
    elif isinstance(value, int):
        value = [value]
    return [str(part).strip() for part in value if str(part).strip()]


def pools(client):
    """GET /pools: every pool with its members."""
    return client.request("GET", "/pools")


def pool(client, poolid):
    """GET /pools/{poolid}: one pool, with its members."""
    return client.request("GET", "/pools/{}".format(api.segment(poolid)))


def create_pool(client, poolid, comment=None):
    """POST /pools: create a pool. Returns null; read it back with pool()."""
    params = {"poolid": _poolid(poolid)}
    if comment:
        params["comment"] = comment
    return client.request("POST", "/pools", params)


def add_members(client, poolid, vms=None, storage=None, allow_move=False):
    """PUT /pools/{poolid}: attach machines and storages to the pool.

    ``vms`` takes guest ids (9950, or "9950,9951"); ``storage`` takes
    storage ids, which contain colons and slashes and therefore go through
    api.volume() when they are used in a path -- here they are plain
    parameters, so they travel unchanged.
    """
    params = {}
    vms = _members(vms)
    storage = _members(storage)
    if not vms and not storage:
        raise ValueError("Nothing to add to the pool.")
    if vms:
        params["vms"] = vms
    if storage:
        params["storage"] = storage
    if allow_move:
        params["allow-move"] = 1
    return client.request("PUT", "/pools/{}".format(api.segment(poolid)), params)


def remove_members(client, poolid, vms=None, storage=None):
    """PUT /pools/{poolid} with delete=1: detach members from the pool."""
    params = {"delete": 1}
    vms = _members(vms)
    storage = _members(storage)
    if not vms and not storage:
        raise ValueError("Nothing to remove from the pool.")
    if vms:
        params["vms"] = vms
    if storage:
        params["storage"] = storage
    return client.request("PUT", "/pools/{}".format(api.segment(poolid)), params)


def delete_pool(client, poolid):
    """DELETE /pools/{poolid}: delete a pool.

    The server refuses while the pool has members; detach them first.
    """
    return client.request("DELETE", "/pools/{}".format(api.segment(_poolid(poolid))))


def pool_members(record):
    """Members of one pool record, as (kind, id) pairs.

    GET /pools/{poolid} returns a ``members`` list of full objects: a guest
    carries ``vmid`` (and ``type`` qemu/lxc), a storage carries ``storage``
    (and ``type`` storage). The list endpoint GET /pools does not include
    members at all.
    """
    members = []
    for entry in record.get("members") or []:
        if entry.get("type") == "storage":
            members.append(("storage", str(entry.get("storage",
                                                  entry.get("id", "")))))
        else:
            members.append(("guest", str(entry.get("vmid",
                                                 entry.get("id", "")))))
    return members
