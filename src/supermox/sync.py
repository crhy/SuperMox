"""SuperMox home sync: the signed membership list -> Syncthing configuration.

Implements step 1 of the build order in docs/shared-home.md.  One Syncthing
instance runs per SuperMox user on every node (init.d/supermox-sync);
``reconcile`` turns that node's signed membership list into the instance's
configuration through Syncthing's REST API on 127.0.0.1:

  * one device per member, addressed over the WireGuard overlay only
    (``tcp://[<overlay_addr>]:22000``), so no member ever needs a human
    clicking "accept host";
  * one folder per person (``home-<user>``, path ``/home/<user>``) shared with
    every full-copy member;
  * global discovery, local announcement, relays and NAT traversal off:
    nothing may leave the encrypted SuperMox network;
  * staggered file versioning, so deleted and overwritten files stay
    recoverable;
  * the built-in ignore list, written to the folder's ``.stignore``.

``api`` is any object with ``get(path)`` / ``put(path, json)`` / ``post(path,
json)``, so tests can pass a fake and the CLI can pass an HTTP client.
Members carry their Syncthing device id in the membership entry under
``syncthing_id`` (see state.NodeState.set_syncthing_id); an entry without
one is a member whose Syncthing has not been enrolled yet and is skipped,
with a log line.  Everything here is idempotent: a second run against an
already-correct configuration performs no writes.
"""

import logging

log = logging.getLogger("supermox.sync")

# Syncthing's default listen port; the overlay carries it unfiltered.
DEFAULT_PORT = 22000

# Syncthing's REST API root (served on 127.0.0.1 by --gui-address).
API_ROOT = "/api/v1"

# Network options: the SuperMox overlay is the only transport.  Written to
# the "options" section of Syncthing's global config.
NETWORK_OFF = {
    "globalAnnounceEnabled": False,
    "relaysEnabled": False,
    "natEnabled": False,
    "localAnnounceEnabled": False,
}

# Staggered versioning: the newest 5 versions of every changed file are kept,
# older ones age out (90 s, 5 versions per step).
VERSIONING = {
    "type": "staggered",
    "max_versions": 5,
    "min_age": 90,
    "min_version": 5,
}

# Built-in ignore list from docs/shared-home.md.  Patterns are Syncthing
# .stignore patterns: they match at any depth, "*" spans path elements.
DEFAULT_IGNORES = [
    ".cache",
    ".local/share/Trash",
    ".var/app/*/cache",
    "build",
    "build-*/",
    "*.iso",
    ".thumbnails",
]

# Syncthing marks a file both sides changed with this marker in its name.
CONFLICT_MARKER = ".sync-conflict-"


def device_address(member: dict) -> str:
    """Overlay address of a member as Syncthing wants it.

    The member's overlay_addr is a full IPv6 address, so it goes inside
    brackets: tcp://[fd00:...]:22000.
    """
    return "tcp://[%s]:%d" % (member["overlay_addr"], DEFAULT_PORT)


def is_full_copy(member: dict) -> bool:
    """True unless the member opted out of holding a full home copy.

    Full copy is the default for PCs and servers (docs/shared-home.md);
    phones and small devices set sync_mode "selective" in their membership
    entry, encrypted backup holders "untrusted".  Step 3 of the build order
    adds those modes; until then every member is a full copy.
    """
    return member.get("sync_mode", "full") == "full"


def synced_members(membership: list) -> list:
    """Members that carry a Syncthing device id (the rest are skipped)."""
    out = []
    for m in membership:
        if not m.get("syncthing_id"):
            log.info("member %s has no syncthing_id: not synced yet",
                     m.get("name", "?"))
            continue
        out.append(m)
    return out


def home_folders(membership: list) -> list:
    """The default folder set: home-<user> for every member.

    Each folder is shared with every full-copy member that has a device id.
    Returns folder specs as reconcile() understands them.
    """
    folders = []
    for m in synced_members(membership):
        folders.append({
            "id": "home-%s" % m["name"],
            "path": "/home/%s" % m["name"],
            "users": [m["name"]],
            "ignore": list(DEFAULT_IGNORES),
        })
    return folders


def desired_devices(membership: list, local_node: str) -> list:
    """Syncthing device entries for every member but this node.

    A node never lists itself as a device.  Entries are sorted by device id
    so reconcile can compare configurations without caring about order.
    """
    out = []
    for m in synced_members(membership):
        if m["name"] == local_node:
            continue
        out.append({
            "name": m["syncthing_id"],
            "address": device_address(m),
            "encryption": "plain",
            "port": DEFAULT_PORT,
            "disabled": False,
        })
    out.sort(key=lambda d: d["name"])
    return out


def desired_folders(membership: list, folders: list) -> list:
    """Syncthing folder entries for the requested folders.

    ``folders`` is a list of specs: {"id", "path", "users", "ignore"}.
    ``users`` names the membership entries whose home this is; the folder
    is shared with every full-copy member that has a device id.
    """
    synced = synced_members(membership)
    share = sorted({m["syncthing_id"] for m in synced if is_full_copy(m)})
    out = []
    for spec in folders:
        fid = spec.get("id") or "home-%s" % spec["users"][0]
        path = spec.get("path") or "/home/%s" % spec["users"][0]
        ignore = list(spec.get("ignore", DEFAULT_IGNORES))
        out.append({
            "id": fid,
            "label": fid,
            "path": path,
            "type": "rw",
            "read_only": False,
            "shared": True,
            "share_mode": "custom",
            "share_devices": share,
            "ignore_list": ignore,
            "ignore_permissions": True,
            "ignore_modification_time": False,
            "ignore_symlinks": False,
            "ignore_delete": False,
            "log_version_changes": True,
            "versioning": dict(VERSIONING),
            # A node that was offline must never overwrite newer files.
            "send_larger_than_sent_version": True,
        })
    out.sort(key=lambda f: f["id"])
    return out


def stignore_lines(ignores: list) -> str:
    """The .stignore file content for an ignore list (one pattern per line)."""
    return "\n".join(ignores) + "\n"


def reconcile(membership: list, local_node: str, folders: list, api) -> dict:
    """Apply the membership list to one node's Syncthing configuration.

    Writes only what differs, so running it again after a membership change
    costs three reads and no writes.  Returns a summary of what is configured
    and what was skipped.
    """
    if folders is None:
        folders = home_folders(membership)

    want_devices = desired_devices(membership, local_node)
    want_folders = desired_folders(membership, folders)

    have_devices = api.get("%s/config/devices" % API_ROOT) or []
    have_devices = sorted(have_devices, key=lambda d: d.get("name", ""))
    changed_devices = _devices_changed(have_devices, want_devices)

    cfg = api.get("%s/config/" % API_ROOT) or {}
    options = dict(cfg.get("options") or {})
    changed_options = any(options.get(k) is not False for k in NETWORK_OFF)
    if changed_options:
        options.update(NETWORK_OFF)
        cfg = dict(cfg)
        cfg["options"] = options

    have_folders = api.get("%s/config/folders" % API_ROOT) or []
    have_folders = sorted(have_folders, key=lambda f: f.get("id", ""))
    changed_folders = _folders_changed(have_folders, want_folders)

    summary = {
        "devices": [d["name"] for d in want_devices],
        "folders": [f["id"] for f in want_folders],
        "skipped": [m.get("name", "?") for m in membership
                    if not m.get("syncthing_id")],
        "wrote": [],
    }

    if changed_devices:
        api.put("%s/config/devices" % API_ROOT, want_devices)
        summary["wrote"].append("devices")
    if changed_options:
        api.put("%s/config/" % API_ROOT, cfg)
        summary["wrote"].append("options")
    if changed_folders:
        api.put("%s/config/folders" % API_ROOT, want_folders)
        summary["wrote"].append("folders")

    # .stignore is owned by Syncthing: write it through the folder's ignore
    # endpoint, never by touching the file under the state dir.
    for want in want_folders:
        path = "%s/config/folders/%s/ignore" % (API_ROOT, want["id"])
        have = sorted(api.get(path) or [])
        if have != sorted(want["ignore_list"]):
            api.put(path, want["ignore_list"])
            summary["wrote"].append("ignore:%s" % want["id"])

    log.info("reconciled %d device(s), %d folder(s); wrote %s",
             len(want_devices), len(want_folders),
             ",".join(summary["wrote"]) or "nothing")
    return summary


def _devices_changed(have: list, want: list) -> bool:
    """True if the device list needs writing."""
    if len(have) != len(want):
        return True
    for got, goal in zip(have, want):
        if (got.get("name") != goal["name"]
                or got.get("address") != goal["address"]
                or got.get("disabled") != goal["disabled"]):
            return True
    return False


def _folders_changed(have: list, want: list) -> bool:
    """True if the folder list needs writing."""
    if len(have) != len(want):
        return True
    for got, goal in zip(have, want):
        if (got.get("id") != goal["id"]
                or got.get("path") != goal["path"]
                or got.get("shared") != goal["shared"]
                or got.get("share_devices") != goal["share_devices"]
                or got.get("versioning") != goal["versioning"]):
            return True
    return False
