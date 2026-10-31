"""Storage content, uploads, downloads, backups and restores (no GTK).

Every path and parameter name below was read from the running node with
`pvesh usage` (recorded in .strata/notes-t69-manager-storage.md); nothing is
guessed. Volume ids travel in the URL path with ':' and '/' intact, so they
use api.volume(), not api.segment(). Uploads stream through client.upload().
"""

from .. import api


def storages(client, node):
    """GET /nodes/{node}/storage: the storages on a node and their content types."""
    return client.request("GET", "/nodes/{}/storage".format(api.segment(node)))


def content(client, node, storage, content_type=None, vmid=None):
    """GET /nodes/{node}/storage/{storage}/content: list stored files.

    ``content_type`` filters by type (iso, vztmpl, backup, images, ...);
    ``vmid`` lists only the images owned by that guest.
    """
    params = {}
    if content_type:
        params["content"] = content_type
    if vmid is not None:
        params["vmid"] = int(vmid)
    path = "/nodes/{}/storage/{}/content".format(api.segment(node),
                                                 api.segment(storage))
    return client.request("GET", path, params or None)


def delete_volume(client, node, storage, volume):
    """DELETE /nodes/{node}/storage/{storage}/content/{volume}: remove one volume.

    ``volume`` is the volid (e.g. local:iso/t69.iso). ``delay`` asks the node
    to wait up to that many seconds and return null if the delete finished.
    """
    if not volume:
        raise ValueError("Pick a volume to delete.")
    path = "/nodes/{}/storage/{}/content/{}".format(
        api.segment(node), api.segment(storage), api.volume(volume))
    return client.request("DELETE", path, {"delay": 1})


def upload(client, node, storage, filename, fileobj, size, content_type=None):
    """POST a file to /nodes/{node}/storage/{storage}/upload; returns its UPID.

    The file bytes stream through client.upload(); ``size`` must be the exact
    byte length. ``content_type`` (iso, vztmpl, import) is optional.
    """
    fields = {}
    if content_type:
        fields["content"] = content_type
    path = "/nodes/{}/storage/{}/upload".format(api.segment(node),
                                                api.segment(storage))
    return client.upload(path, fields, filename, fileobj, size)


def download_url(client, node, storage, url, filename, content_type=None):
    """POST /nodes/{node}/storage/{storage}/download-url; returns its UPID."""
    if not url:
        raise ValueError("Give a URL to download from.")
    params = {"url": url, "filename": filename}
    if content_type:
        params["content"] = content_type
    path = "/nodes/{}/storage/{}/download-url".format(api.segment(node),
                                                      api.segment(storage))
    return client.request("POST", path, params)


def backup(client, node, vmid, storage=None, mode="snapshot", compress=0):
    """POST /nodes/{node}/vzdump: back up one guest; returns its task UPID.

    ``mode`` is snapshot, stop or suspend; ``compress`` is 0, 1, gzip, lzo or
    zstd. ``storage`` chooses where the backup file is written.
    """
    if mode not in ("snapshot", "stop", "suspend"):
        raise ValueError("Backup mode must be snapshot, stop or suspend.")
    params = {"vmid": int(vmid), "mode": mode, "compress": compress}
    if storage:
        params["storage"] = storage
    path = "/nodes/{}/vzdump".format(api.segment(node))
    return client.request("POST", path, params)


def restore(client, node, kind, vmid, volume):
    """Restore a guest from a backup volume; returns its task UPID.

    VM: POST /nodes/{node}/qemu with archive=<volume>.
    CT: POST /nodes/{node}/lxc with restore=1 and ostemplate=<volume>.
    ``volume`` is the backup volid (e.g. local:backup/.../vm-100.tar.zst).
    """
    if kind not in ("qemu", "lxc"):
        raise ValueError("Select a virtual machine or container.")
    if not volume:
        raise ValueError("Pick a backup to restore.")
    vmid = int(vmid)
    if vmid < 100 or vmid > 999999999:
        raise ValueError("The VMID must be between 100 and 999999999.")
    if kind == "qemu":
        path = "/nodes/{}/qemu".format(api.segment(node))
        return client.request("POST", path, {"vmid": vmid, "archive": volume})
    path = "/nodes/{}/lxc".format(api.segment(node))
    return client.request("POST", path,
                          {"vmid": vmid, "restore": 1, "ostemplate": volume})
