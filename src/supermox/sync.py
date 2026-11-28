"""SuperMox home sync: the signed membership list -> Syncthing configuration.

Implements step 1 of the build order in docs/shared-home.md.  One Syncthing
instance runs per SuperMox user on every node (init.d/supermox-sync);
``reconcile`` turns that node's signed membership list into the instance's
configuration through Syncthing's REST API on 127.0.0.1:

  * one device per member, addressed over the WireGuard overlay only
    (``tcp://[<overlay_addr>]:22000``), so no member ever needs a human
    clicking "accept host";
  * one folder per person (``home-<user>``, path ``<home root>/<user>``) shared
    with every full-copy member; the home root is ``/home`` unless
    ``SUPERMOX_SYNC_HOME_ROOT`` overrides it, so a test or a non-standard
    node can never point Syncthing at a real user's home by accident;
  * global discovery, local announcement, relays and NAT traversal off:
    nothing may leave the encrypted SuperMox network;
  * staggered file versioning, so deleted and overwritten files stay
    recoverable;
  * the built-in ignore list, written to the folder's ``.stignore``.

``api`` is any object with ``get(path)`` / ``put(path, json)`` and
``read_stignore(path)`` / ``write_stignore(path, patterns)``, so tests can
pass a fake and the CLI can pass an HTTP client.  There is no ``post``:
Syncthing's API is GET and PUT under ``/rest/config/`` plus the read-only
``/rest/db/`` views, and the ignore list has no endpoint at all.
Members carry their Syncthing device id in the membership entry under
``syncthing_id`` (see state.NodeState.set_syncthing_id); an entry without
one is a member whose Syncthing has not been enrolled yet and is skipped,
with a log line.  Everything here is idempotent: a second run against an
already-correct configuration performs no writes.
"""

import logging
import os
import time
import urllib.parse

log = logging.getLogger("supermox.sync")

# Syncthing's default listen port; the overlay carries it unfiltered.
DEFAULT_PORT = 22000

# Syncthing's REST API root (served on 127.0.0.1 by --gui-address).  Syncthing
# 1.29.x has no /api/v1: every path here is under /rest, authenticated with
# the instance's X-API-Key.
API_ROOT = "/rest"

# Root the per-person folders hang off.  Overridable so a live test can run
# against build/f15b/homes/<member> instead of a real user's home.
HOME_ROOT = "/home"

# Network options: the SuperMox overlay is the only transport.  Written to
# the "options" section of Syncthing's global config.
NETWORK_OFF = {
    "globalAnnounceEnabled": False,
    "relaysEnabled": False,
    "natEnabled": False,
    "localAnnounceEnabled": False,
}

# Staggered versioning: the newest 5 versions of every changed file are kept,
# older ones age out (90 s, 5 versions per step).  The params are strings
# because that is the type of FolderConfiguration.versioning.params in the
# API: an integer is rejected with "cannot unmarshal number ... of type".
VERSIONING = {
    "type": "staggered",
    "params": {"max_versions": "5", "min_age": "90", "min_version": "5"},
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


def home_root() -> str:
    """Root the per-person folders hang off: $SUPERMOX_SYNC_HOME_ROOT."""
    return os.environ.get("SUPERMOX_SYNC_HOME_ROOT") or HOME_ROOT


def home_for(user: str) -> str:
    """Where member <user>'s folder lives on this node.

    One place so the CLI's default and the reconcile's default agree; a
    member's folder path is derived, never typed, so a typo cannot send a
    folder to some other directory.
    """
    return os.path.join(home_root(), user)


def device_address(member: dict) -> str:
    """Where to reach that member's Syncthing, as a BEP address.

    Normally the member's overlay address, wrapped with the port Syncthing
    listens on: on the WireGuard network every member can use the same port,
    because each has its own address.  An entry may instead carry a complete
    address (anything with a scheme), which is what lets several instances
    run on one host, where one port cannot be bound twice.
    """
    addr = member["overlay_addr"]
    if "://" in addr:
        return addr
    return "tcp://[%s]:%d" % (addr, DEFAULT_PORT)


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


def folder_id(user: str) -> str:
    """The folder id for one member's home.

    One place so both ends of the cluster compute the same string: an id
    that differs is a different folder, and nothing reports that.
    """
    return "home-%s" % user


def home_folders(membership: list) -> list:
    """The default folder set: home-<user> for every member.

    Each folder is shared with every full-copy member that has a device id.
    Returns folder specs as reconcile() understands them.
    """
    folders = []
    for m in synced_members(membership):
        folders.append({
            "id": folder_id(m["name"]),
            "path": home_for(m["name"]),
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
            "deviceID": m["syncthing_id"],
            "name": m["name"],
            "addresses": [device_address(m)],
            "port_forwarded": False,
        })
    out.sort(key=lambda d: d["deviceID"])
    return out


def desired_folders(membership: list, folders: list, local_node: str = None) -> list:
    """Syncthing folder entries for the requested folders.

    ``folders`` is a list of specs: {"id", "path", "users", "ignore"}.
    ``users`` names the membership entries whose home this is; the folder
    is shared with every full-copy member that has a device id -- except
    this node, because an instance adds its own id to every folder it is
    offered, and writing it back makes the next compare see a change that
    never ends.
    """
    synced = synced_members(membership)
    share = sorted({m["syncthing_id"] for m in synced
                    if is_full_copy(m) and m["name"] != local_node})
    out = []
    for spec in folders:
        fid = spec.get("id") or folder_id(spec["users"][0])
        path = spec.get("path") or os.path.join(home_root(), spec["users"][0])
        ignore = list(spec.get("ignore", DEFAULT_IGNORES))
        out.append({
            "id": fid,
            "label": fid,
            "path": path,
            "type": "sendreceive",
            "devices": [{"deviceID": d} for d in share],
            "versioning": dict(VERSIONING),
            "ignorePerms": True,
            # Not an API field: carried here so reconcile can write the
            # folder's .stignore.  folder_body() strips it from the PUT.
            "ignore_list": ignore,
        })
    out.sort(key=lambda f: f["id"])
    return out


def folder_body(want: dict) -> dict:
    """The PUT body for a folder spec: everything except our ignore list.

    Syncthing keeps the ignore list in the shared folder's .stignore file,
    not in the folder object, so sending it would be a field the API has
    never heard of.
    """
    return {k: v for k, v in want.items() if k != "ignore_list"}


def stignore_lines(ignores: list) -> str:
    """The .stignore file content for an ignore list (one pattern per line)."""
    return "\n".join(ignores) + "\n"


def stignore_file(path: str) -> str:
    """Where a folder's ignore list lives: inside the shared folder itself."""
    return os.path.join(path, ".stignore")


def read_stignore(path: str):
    """A folder's .stignore as patterns, or None if it has none.

    Read from disk, not from the API: Syncthing keeps the list in the file
    and only shows it back through the read-only /rest/db/ignores view.
    """
    try:
        with open(stignore_file(path), encoding="utf-8") as fh:
            return [line.strip() for line in fh if line.strip()]
    except OSError:
        return None


def write_stignore(path: str, ignores: list) -> bool:
    """Write a folder's .stignore.

    The folder directory is created if Syncthing has not made it yet; the
    path is one reconcile computed from the membership list, so creating it
    is expected, not a surprise.  Patterns go one per line, in the order
    given, so the file is diffable across nodes.
    """
    try:
        os.makedirs(path, exist_ok=True)
        with open(stignore_file(path), "w", encoding="utf-8") as fh:
            fh.write(stignore_lines(ignores))
    except OSError as exc:
        log.warning("cannot write %s: %s", stignore_file(path), exc.strerror)
        return False
    return True


def reconcile(membership: list, local_node: str, folders: list, api,
              record_device_id=None) -> dict:
    """Apply the membership list to one node's Syncthing configuration.

    Writes only what differs, so running it again after a membership change
    costs three reads and no writes.  Returns a summary of what is configured
    and what was skipped.

    ``record_device_id`` is a callback the caller uses to remember this
    instance's own device id (in the membership entry, under ``syncthing_id``):
    every other node needs that id to address this node's Syncthing, and this
    node is the only one that knows it.
    """
    if folders is None:
        folders = home_folders(membership)

    want_devices = desired_devices(membership, local_node)
    want_folders = desired_folders(membership, folders, local_node)

    # Syncthing always keeps its own device in the device list and always
    # adds itself to a folder's devices, whatever we send.  It is not ours
    # to manage, so it is left out of both comparisons.
    local_id = local_device_id(api)
    if local_id and record_device_id:
        record_device_id(local_id)

    have_devices = api.get("%s/config/devices" % API_ROOT) or []
    have_devices = sorted((d for d in have_devices
                           if d.get("deviceID") != local_id),
                          key=lambda d: d.get("deviceID", ""))
    changed_devices = _devices_changed(have_devices, want_devices, local_id)

    options = api.get("%s/config/options" % API_ROOT) or {}
    changed_options = any(options.get(k) is not False for k in NETWORK_OFF)

    have_folders = api.get("%s/config/folders" % API_ROOT) or []
    have_folders = sorted(have_folders, key=lambda f: f.get("id", ""))
    changed_folders = _folders_changed(have_folders, want_folders, local_id)

    summary = {
        "devices": [d["deviceID"] for d in want_devices],
        "folders": [f["id"] for f in want_folders],
        "skipped": [m.get("name", "?") for m in membership
                    if not m.get("syncthing_id")],
        "wrote": [],
    }

    if changed_devices:
        api.put("%s/config/devices" % API_ROOT, want_devices)
        summary["wrote"].append("devices")
    if changed_options:
        api.put("%s/config/options" % API_ROOT, dict(NETWORK_OFF))
        summary["wrote"].append("options")
    if changed_folders:
        api.put("%s/config/folders" % API_ROOT,
                [folder_body(w) for w in want_folders])
        summary["wrote"].append("folders")

    # The ignore list has no endpoint: it is the shared folder's .stignore
    # file, which Syncthing re-reads itself and syncs like any other file,
    # which is what makes one node's edit cluster-wide.  Never touch the
    # copy under Syncthing's state dir.
    for want in want_folders:
        have = api.read_stignore(want["path"])
        if have is None or sorted(have) != sorted(want["ignore_list"]):
            if api.write_stignore(want["path"], want["ignore_list"]):
                summary["wrote"].append("ignore:%s" % want["id"])

    log.info("reconciled %d device(s), %d folder(s); wrote %s",
             len(want_devices), len(want_folders),
             ",".join(summary["wrote"]) or "nothing")
    return summary


def _devices_changed(have: list, want: list, local_id: str = None) -> bool:
    """True if the device list needs writing.

    ``name`` is compared as well as the address: a member whose Syncthing
    was reinstalled keeps its id but may have arrived under a different
    friendly name.
    """
    have = [d for d in have if d.get("deviceID") != local_id]
    if len(have) != len(want):
        return True
    for got, goal in zip(have, want):
        if (got.get("deviceID") != goal["deviceID"]
                or list(got.get("addresses") or []) != goal["addresses"]
                or got.get("name") != goal["name"]):
            return True
    return False


def _folders_changed(have: list, want: list, local_id: str = None) -> bool:
    """True if the folder list needs writing.

    Only the fields SuperMox sets are compared: a folder read back from
    the API carries defaults SuperMox never sends (cleanupIntervalS, fsPath,
    fsType) and always carries this node's own device, so comparing whole
    objects would make every reconcile rewrite every folder.
    """
    if len(have) != len(want):
        return True
    for got, goal in zip(have, want):
        got_devices = sorted(d["deviceID"] for d in got.get("devices") or []
                             if d.get("deviceID") != local_id)
        want_devices = sorted(d["deviceID"] for d in goal["devices"])
        got_versioning = got.get("versioning") or {}
        # Sent as strings because the API rejects numbers, read back as
        # numbers, so compare them as strings.
        got_params = {k: str(v) for k, v in
                      (got_versioning.get("params") or {}).items()}
        want_params = {k: str(v) for k, v in
                       goal["versioning"]["params"].items()}
        if (got.get("id") != goal["id"]
                or got.get("path") != goal["path"]
                or got.get("type") != goal["type"]
                or got_devices != want_devices
                or got_versioning.get("type") != goal["versioning"]["type"]
                or got_params != want_params
                or got.get("ignorePerms") != goal["ignorePerms"]):
            return True
    return False


def local_device_id(api) -> str:
    """This instance's own Syncthing device id.

    Read from the running instance (/rest/system/status' myID) rather than
    parsed out of config.xml: it is the same string Syncthing puts in its
    own device list, and it survives a config rewrite.
    """
    status = api.get("%s/system/status" % API_ROOT)
    if status:
        return status.get("myID")
    return None


def folder_state(api, folder_id: str) -> dict:
    """One folder's sync state, from /rest/db/status?folder=<id>.

    ``state`` is "idle" once the folder has finished scanning and transferring
    ("syncing" and "scan" while it works); ``needTotalItems`` counts what is
    still moving, and ``error`` carries the folder's own
    failure (a path that cannot be read, a folder paused by the operator).
    """
    return api.get("%s/db/status?folder=%s"
                   % (API_ROOT, urllib.parse.quote(folder_id))) or {}


def wait_until_synced(api, folder_id: str, timeout: float = 60.0) -> bool:
    """Block until one folder reports idle with nothing left to transfer.

    Used by ``supermox-sync wait`` and by the live test: a script that acts
    on a synced home has to act on a folder that has actually arrived, not
    on a guess about how long a transfer takes on this link.
    """
    deadline = time.time() + timeout
    while True:
        st = folder_state(api, folder_id)
        if st and st.get("state") == "idle" and not st.get("needTotalItems"):
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.5)


def find_conflicts(path: str, limit: int = 20000) -> list:
    """Conflict copies inside one shared folder, as file names.

    Syncthing renames the losing side of a concurrent edit to
    ``<name>.sync-conflict-<host>-<date>``; those names are on disk, not
    in the API.  The scan stops at ``limit`` entries so a huge home cannot
    turn ``supermox-sync status`` into a hang.
    """
    out = []
    seen = 0
    stack = [path]
    while stack and seen < limit:
        try:
            with os.scandir(stack.pop()) as it:
                for entry in it:
                    seen += 1
                    if seen > limit:
                        return out
                    if CONFLICT_MARKER in entry.name:
                        out.append(entry.name)
                    elif entry.is_dir(follow_symlinks=False):
                        stack.append(entry.path)
        except OSError:
            continue
    return sorted(out)
