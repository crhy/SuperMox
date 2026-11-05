#!/usr/bin/env python3
"""Unit tests for the home sync layer (src/supermox/sync.py).

The cluster's signed membership list is the only input: it decides which
devices this node's Syncthing instance has and which folders exist. Syncthing
itself is stood in by FakeApi, which speaks Syncthing 1.29.x's real REST
shape (paths under /rest, deviceID/addresses device entries, a devices list
on each folder, versioning params as strings) and remembers what was written
to it, so the tests can check both the first reconcile and the second one,
which must write nothing.
"""

import base64
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))

from supermox import secret, sync as sync_mod


# The join daemon's derived state: the cluster /48 and the 16 entropy bytes
# a node address is derived from (see state.py and secret.node_address).
DERIVED = {"overlay_prefix": "fd00:1234:5678::/48", "entropy": b"\x9f" * 16}

# This fake instance's own device id: Syncthing always keeps it in its
# device list and always adds it to every folder, whatever we PUT.
MY_ID = "0000-local-0000"


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _member(name: str, syncthing_id: str = None, sync_mode: str = None) -> dict:
    """A membership entry as joind would store it for this name."""
    wg = bytes((i * 7 + len(name)) & 0xFF for i in range(32))
    ed = bytes((i * 3 + len(name) + 1) & 0xFF for i in range(32))
    entry = {
        "name": name,
        "wg_pub": _b64(wg),
        "ed_pub": _b64(ed),
        "overlay_addr": secret.node_address(DERIVED, wg),
        "endpoints": [],
        "arch": "amd64",
        "caps": [],
        "role": "core",
    }
    if syncthing_id:
        entry["syncthing_id"] = syncthing_id
    if sync_mode:
        entry["sync_mode"] = sync_mode
    return entry


class FakeApi:
    """Stands in for Syncthing 1.29.x's REST API over the paths sync.py uses.

    Every write is recorded, so a test can ask whether a reconcile changed
    anything at all.  The instance also behaves the way the real one does:
    it keeps its own device in the device list, adds itself to every folder,
    fills in the versioning and folder defaults SuperMox never sends, and
    has no endpoint at all for the ignore list.
    """

    def __init__(self):
        self.devices = []
        self.folders = []
        self.options = {}
        self.ignores = {}      # folder path -> patterns
        self.db_status = {}    # folder id -> status body
        self.writes = []
        self.my_id = MY_ID

    def remote_devices(self) -> list:
        """The device list as sync.py sees it: without this instance itself."""
        return [d for d in self.devices if d["deviceID"] != self.my_id]

    def get(self, path: str):
        if path == "%s/config/devices" % sync_mod.API_ROOT:
            return [dict(d) for d in self.devices]
        if path == "%s/config/folders" % sync_mod.API_ROOT:
            return [dict(f) for f in self.folders]
        if path == "%s/config/options" % sync_mod.API_ROOT:
            return dict(self.options)
        if path == "%s/system/status" % sync_mod.API_ROOT:
            return {"myID": self.my_id, "pendingChanges": 0}
        if path.startswith("%s/db/status?folder=" % sync_mod.API_ROOT):
            fid = path.split("=", 1)[1]
            return dict(self.db_status[fid]) if fid in self.db_status else None
        return None

    def put(self, path, obj):
        self.writes.append((path, obj))
        if path.endswith("/config/devices"):
            # Syncthing keeps its own device: the local entry survives a
            # write that does not mention it.
            self.devices = ([dict(d) for d in obj]
                            + [{"deviceID": self.my_id, "name": "this-node",
                               "addresses": [], "port_forwarded": False}])
        elif path.endswith("/config/folders"):
            self.folders = []
            for f in obj:
                f = dict(f)
                # The instance offers the folder to itself as well.
                f["devices"] = ([dict(d) for d in f["devices"]]
                                + [{"deviceID": self.my_id}])
                v = dict(f["versioning"])
                # Syncthing parses the params as numbers, whatever type they
                # were sent as, and fills in defaults we never send.
                v["params"] = {k: int(x) for k, x in v["params"].items()}
                v.update({"cleanupIntervalS": 3600, "fsPath": "",
                          "fsType": "basic"})
                f["versioning"] = v
                f.setdefault("type", "sendreceive")
                f["paused"] = False
                self.folders.append(f)
        elif path.endswith("/config/options"):
            self.options.update(obj)

    def read_stignore(self, folder_path: str):
        return list(self.ignores[folder_path]) if folder_path in self.ignores \
            else None

    def write_stignore(self, folder_path: str, patterns) -> bool:
        self.writes.append((".stignore:%s" % folder_path, list(patterns)))
        self.ignores[folder_path] = list(patterns)
        return True

    def post(self, path, obj):
        raise AssertionError(
            "sync.py must not POST: the ignore list is the shared folder's "
            ".stignore file, everything else is a PUT under /rest/config/")


class ApiShapeTest(unittest.TestCase):
    """The endpoints are the ones Syncthing 1.29.5 actually serves.

    A /api/v1 path is not a thing in this build: every path is under /rest,
    and the ignore list has no endpoint at all.
    """

    def test_the_api_root_is_rest(self):
        self.assertEqual(sync_mod.API_ROOT, "/rest")

    def test_the_folder_state_path_is_the_db_view(self):
        api = FakeApi()
        api.db_status["home-home-server"] = {"state": "idle",
                                             "needTotalItems": 0}
        self.assertEqual(
            sync_mod.folder_state(api, "home-home-server")["state"],
            "idle")

    def test_the_ignore_list_is_a_file_not_an_endpoint(self):
        # PUT /rest/db/ignores answers "Method Not Allowed" on a real instance;
        # the file inside the shared folder is the only way in.
        api = FakeApi()
        self.assertIsNone(api.get("%s/db/ignores" % sync_mod.API_ROOT))
        api.write_stignore("/home/home-server", [".cache"])
        self.assertEqual(api.read_stignore("/home/home-server"), [".cache"])
        self.assertIsNone(api.read_stignore("/home/never-created"))


class HomeRootTest(unittest.TestCase):
    """Folder paths come from a root an operator can override.

    Without the override a live test would point Syncthing at a real user's
    home directory, which is exactly what must never happen by accident.
    """

    def setUp(self):
        os.environ.pop("SUPERMOX_SYNC_HOME_ROOT", None)

    def tearDown(self):
        os.environ.pop("SUPERMOX_SYNC_HOME_ROOT", None)

    def test_the_default_root_is_home(self):
        self.assertEqual(sync_mod.home_root(), "/home")
        self.assertEqual(sync_mod.home_folders([_member("vps", "e-f")])[0]["path"],
                         "/home/vps")

    def test_the_override_moves_every_folder(self):
        os.environ["SUPERMOX_SYNC_HOME_ROOT"] = "/srv/build/f15b/homes"
        self.assertEqual(sync_mod.home_root(), "/srv/build/f15b/homes")
        folders = sync_mod.home_folders([_member("alice", "a-1"),
                                         _member("bob", "b-2")])
        self.assertEqual([f["path"] for f in folders],
                         ["/srv/build/f15b/homes/alice",
                          "/srv/build/f15b/homes/bob"])
        # The id does not move with the root: both ends must agree on it.
        self.assertEqual([f["id"] for f in folders], ["home-alice", "home-bob"])

    def test_the_override_reaches_the_reconcile_write(self):
        os.environ["SUPERMOX_SYNC_HOME_ROOT"] = "/srv/build/f15b/homes"
        api = FakeApi()
        members = [_member("home-server", "aaaa-bbbb"), _member("starlte",
                                                               "cccc-dddd")]
        sync_mod.reconcile(members, "home-server", None, api)
        self.assertEqual([f["path"] for f in api.folders],
                         ["/srv/build/f15b/homes/home-server",
                          "/srv/build/f15b/homes/starlte"])
        self.assertEqual(sorted(api.ignores),
                         ["/srv/build/f15b/homes/home-server",
                          "/srv/build/f15b/homes/starlte"])


class DevicesTest(unittest.TestCase):
    def setUp(self):
        self.home = _member("home-server", "aaaa-bbbb")
        self.phone = _member("starlte", "cccc-dddd")
        self.members = [self.home, self.phone]
        self.api = FakeApi()

    def test_devices_come_from_membership_and_nowhere_else(self):
        # Nothing is read from Syncthing's own peer list: the members are
        # the ones the cluster signed, and their addresses are the overlay
        # addresses the join daemon computed.
        summary = sync_mod.reconcile(self.members, "home-server", None, self.api)
        self.assertEqual(summary["devices"], ["cccc-dddd"])
        self.assertEqual(self.api.remote_devices()[0]["addresses"],
                         ["tcp://[%s]:%d" % (self.phone["overlay_addr"],
                                             sync_mod.DEFAULT_PORT)])

    def test_an_entry_may_name_the_whole_address_instead_of_the_overlay(self):
        # One host cannot bind one port twice, so a cluster that runs on a
        # single machine (a test, or a lab) pins each member's endpoint.
        # The entry says so by carrying the scheme; nothing else changes.
        pinned = _member("lab-bench", "eeee-ffff")
        pinned["overlay_addr"] = "tcp://[::1]:22011"
        summary = sync_mod.reconcile([self.home, pinned],
                                     "home-server", None, self.api)
        self.assertEqual(summary["devices"], ["eeee-ffff"])
        self.assertEqual(self.api.remote_devices()[0]["addresses"],
                         ["tcp://[::1]:22011"])

    def test_the_local_node_is_never_a_device_of_itself(self):
        # Syncthing keeps its own entry; sync.py never writes one.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        self.assertEqual([d["deviceID"] for d in self.api.remote_devices()],
                         ["cccc-dddd"])
        sync_mod.reconcile(self.members, "starlte", None, self.api)
        self.assertEqual([d["deviceID"] for d in self.api.remote_devices()],
                         ["aaaa-bbbb"])
        self.assertEqual(self.api.my_id, MY_ID)

    def test_a_member_without_a_device_id_is_skipped_and_says_so(self):
        # Backwards compatible: an entry written before Syncthing existed
        # carries no syncthing_id, so there is nothing to add, and the
        # operator is told which member that was.
        late = _member("late-joiner")
        summary = sync_mod.reconcile(self.members + [late],
                                     "home-server", None, self.api)
        self.assertEqual([d["deviceID"] for d in self.api.remote_devices()],
                         ["cccc-dddd"])
        self.assertEqual(summary["skipped"], ["late-joiner"])

    def test_a_new_member_becomes_a_device(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        before = len(self.api.writes)
        joined = _member("vps", "eeee-ffff")
        sync_mod.reconcile(self.members + [joined], "home-server", None, self.api)
        self.assertEqual(sorted(d["deviceID"]
                                for d in self.api.remote_devices()),
                         ["cccc-dddd", "eeee-ffff"])
        self.assertGreater(len(self.api.writes), before)

    def test_a_changed_device_id_updates_the_entry(self):
        # A reinstalled Syncthing generates a new device id; the membership
        # list is the only place it is written down, so it is what has to
        # change the configuration.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        before = len(self.api.writes)
        reinstalled = _member("starlte", "zzzz-zzzz")
        sync_mod.reconcile([self.home, reinstalled], "home-server", None, self.api)
        self.assertEqual([d["deviceID"] for d in self.api.remote_devices()],
                         ["zzzz-zzzz"])
        self.assertGreater(len(self.api.writes), before)

    def test_a_member_leaving_removes_the_device(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        sync_mod.reconcile([self.home], "home-server", None, self.api)
        self.assertEqual(self.api.remote_devices(), [])

    def test_reconcile_is_idempotent(self):
        # Boot runs it every time; a second run against an already-correct
        # instance must cost reads only.  The fake adds this instance's own
        # device and folder entry and fills in defaults, so a comparison
        # that ignored those would fail here rather than on a live node.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        writes = len(self.api.writes)
        summary = sync_mod.reconcile(self.members, "home-server", None, self.api)
        self.assertEqual(len(self.api.writes), writes)
        self.assertEqual(summary["wrote"], [])

    def test_the_overlay_is_the_only_transport(self):
        # Global discovery, local announcement, relays and NAT traversal
        # off: nothing may leave the encrypted SuperMox network.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        for key, value in sync_mod.NETWORK_OFF.items():
            self.assertIs(self.api.options[key], value, "%s must be off" % key)

    def test_the_device_list_is_sorted(self):
        # So a reconcile can compare configurations without caring about
        # the order members happen to be listed in.
        members = [_member("zulu", "zzzz-1111"), self.phone,
                   _member("alpha", "aaaa-2222")]
        sync_mod.reconcile(members, "home-server", None, self.api)
        self.assertEqual([d["deviceID"] for d in self.api.remote_devices()],
                         ["aaaa-2222", "cccc-dddd", "zzzz-1111"])

    def test_a_renamed_member_reaches_the_device_entry(self):
        # Syncthing shows ``name`` to an operator; a member that arrives
        # under a different friendly name has to be rewritten even though
        # its device id is unchanged.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        before = len(self.api.writes)
        renamed = _member("galaxy-s9", "cccc-dddd")
        sync_mod.reconcile([self.home, renamed], "home-server", None, self.api)
        self.assertGreater(len(self.api.writes), before)
        self.assertEqual([d["name"] for d in self.api.remote_devices()],
                         ["galaxy-s9"])


class FoldersTest(unittest.TestCase):
    def setUp(self):
        self.home = _member("home-server", "aaaa-bbbb")
        self.phone = _member("starlte", "cccc-dddd")
        self.members = [self.home, self.phone]
        self.api = FakeApi()

    def test_one_folder_per_person(self):
        folders = sync_mod.home_folders(self.members)
        self.assertEqual([f["id"] for f in folders],
                         ["home-home-server", "home-starlte"])
        self.assertEqual([f["path"] for f in folders],
                         ["/home/home-server", "/home/starlte"])

    def test_folder_ids_are_stable_across_reconciles(self):
        # The id is what both nodes write into their own instance; it has
        # to be the same string there, or the two ends are different folders.
        self.assertEqual([f["id"] for f in sync_mod.home_folders(self.members)],
                         [f["id"] for f in sync_mod.home_folders(self.members)])

    def test_a_folder_is_shared_with_every_full_copy_member(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        for folder in self.api.folders:
            self.assertEqual(
                sorted(d["deviceID"] for d in folder["devices"]
                       if d["deviceID"] != self.api.my_id),
                ["cccc-dddd"])

    def test_this_node_is_never_written_as_a_folder_device(self):
        # A real instance adds its own id to every folder it is offered.  If
        # we write that id back, the next compare sees a change that is never
        # there, and reconcile rewrites the same folders on every run.
        api = FakeApi()
        api.my_id = "aaaa-bbbb"      # this instance is home-server
        sync_mod.reconcile(self.members, "home-server", None, api)
        sent = [body for path, body in api.writes
                if path.endswith("/config/folders")][-1]
        for folder in sent:
            self.assertNotIn("aaaa-bbbb",
                             [d["deviceID"] for d in folder["devices"]])
        self.assertEqual(sorted(d["deviceID"] for d in api.folders[0]["devices"]
                                 if d["deviceID"] != api.my_id),
                         ["cccc-dddd"])
        writes = len(api.writes)
        sync_mod.reconcile(self.members, "home-server", None, api)
        self.assertEqual(len(api.writes), writes)

    def test_a_selective_member_is_not_offered_the_whole_home(self):
        # docs/shared-home.md: a phone that opted out of the full copy gets
        # folders it picked itself, never the home folder of another member.
        selective = _member("starlte", "cccc-dddd", sync_mode="selective")
        sync_mod.reconcile([self.home, selective], "home-server", None, self.api)
        for folder in self.api.folders:
            self.assertEqual(
                sorted(d["deviceID"] for d in folder["devices"]
                       if d["deviceID"] != self.api.my_id),
                [])

    def test_the_folder_body_carries_only_fields_the_api_takes(self):
        # A field Syncthing has never heard of is how this layer drifted
        # from the real API in the first place: the ignore list is a file,
        # and the folder object is not allowed to pretend otherwise.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        for path, body in self.api.writes:
            if not path.endswith("/config/folders"):
                continue
            for folder in body:
                self.assertEqual(
                    sorted(folder),
                    ["devices", "id", "ignorePerms", "label", "path",
                     "type", "versioning"])

    def test_file_versioning_is_on(self):
        # A deleted or overwritten file stays recoverable.  The params are
        # sent as strings -- a real instance rejects an integer with
        # "cannot unmarshal number ... of type string" -- and come back as
        # numbers, which reconcile must not read as a change.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        sent = [body for path, body in self.api.writes
                if path.endswith("/config/folders")][-1]
        for folder in sent:
            self.assertEqual(folder["versioning"]["type"], "staggered")
            for value in folder["versioning"]["params"].values():
                self.assertIsInstance(value, str)
        for folder in self.api.folders:
            self.assertEqual(folder["versioning"]["type"], "staggered")
            self.assertEqual(
                {k: str(v) for k, v in
                 folder["versioning"]["params"].items()},
                sync_mod.VERSIONING["params"])

    def test_versioning_defaults_the_api_adds_do_not_force_a_rewrite(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        writes = len(self.api.writes)
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        self.assertEqual(len(self.api.writes), writes)

    def test_stignore_is_written_for_every_folder(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        for folder in sync_mod.home_folders(self.members):
            self.assertEqual(self.api.ignores[folder["path"]],
                             sync_mod.DEFAULT_IGNORES)

    def test_an_edited_ignore_list_is_rewritten(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        writes = len(self.api.writes)
        folders = sync_mod.home_folders(self.members)
        folders[0] = dict(folders[0], ignore=[".cache", "secrets/"])
        sync_mod.reconcile(self.members, "home-server", folders, self.api)
        self.assertGreater(len(self.api.writes), writes)
        self.assertEqual(self.api.ignores["/home/home-server"],
                         [".cache", "secrets/"])

    def test_an_unchanged_ignore_list_is_not_rewritten(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        writes = len(self.api.writes)
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        self.assertEqual(len(self.api.writes), writes)

    def test_a_renamed_folder_is_a_new_folder(self):
        # The old one disappears from the configuration; its files stay on
        # disk, as the doc says.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        old_ids = {f["id"] for f in self.api.folders}
        folders = sync_mod.home_folders(self.members)
        folders[0] = dict(folders[0], id="home-photos",
                          path="/home/starlte/photos")
        sync_mod.reconcile(self.members, "home-server", folders, self.api)
        new_ids = {f["id"] for f in self.api.folders}
        self.assertNotIn("home-home-server", new_ids)
        self.assertIn("home-photos", new_ids)
        self.assertTrue(old_ids - new_ids)

    def test_no_folders_configures_nothing(self):
        summary = sync_mod.reconcile([self.home], "home-server", [], self.api)
        self.assertEqual(self.api.folders, [])
        self.assertEqual(summary["folders"], [])

    def test_a_member_with_no_device_id_gets_no_folder(self):
        # Nothing to share a folder with: the folder set follows the device
        # set, both from the same membership list.
        summary = sync_mod.reconcile([_member("no-sid")], "no-sid", None, self.api)
        self.assertEqual(summary["folders"], [])
        self.assertEqual(summary["skipped"], ["no-sid"])


class SyncedStateTest(unittest.TestCase):
    """Reading a folder back: idle, and conflict copies on disk."""

    # Verbatim field names and values from GET /rest/db/status on a real
    # 1.29.5 instance: "idle" is the settled state, and needTotalItems
    # counts what is still queued.  A rename in a later Syncthing shows up
    # here as a failing test rather than a wait that never returns.
    REAL_STATUS = {
        "errors": 0, "pullErrors": 0, "invalid": "",
        "globalFiles": 0, "globalBytes": 0, "globalTotalItems": 0,
        "needFiles": 0, "needTotalItems": 0, "needBytes": 0,
        "inSyncFiles": 0, "inSyncBytes": 0,
        "state": "idle", "error": "", "version": 0, "sequence": 0,
        "ignorePatterns": False, "watchError": "",
    }

    def setUp(self):
        self.api = FakeApi()
        self.build = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "..", "..", "build")
        os.makedirs(self.build, exist_ok=True)
        self.home = tempfile.mkdtemp(prefix="f15b-unit-", dir=self.build)

    def tearDown(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def test_the_real_status_body_reports_a_settled_folder(self):
        self.api.db_status["home-alice"] = dict(self.REAL_STATUS)
        self.assertTrue(sync_mod.wait_until_synced(self.api, "home-alice",
                                                   timeout=0.2))

    def test_wait_blocks_until_the_folder_reports_idle(self):
        self.api.db_status["home-alice"] = {"state": "syncing",
                                            "needTotalItems": 7}
        self.assertFalse(sync_mod.wait_until_synced(self.api, "home-alice",
                                                    timeout=0.2))
        self.api.db_status["home-alice"] = {"state": "idle",
                                            "needTotalItems": 0}
        self.assertTrue(sync_mod.wait_until_synced(self.api, "home-alice",
                                                   timeout=0.2))

    def test_idle_with_work_left_still_waits(self):
        # A folder can report idle while items are still queued;
        # acting on that would read a half-arrived home.
        self.api.db_status["home-alice"] = {"state": "idle",
                                            "needTotalItems": 3}
        self.assertFalse(sync_mod.wait_until_synced(self.api, "home-alice",
                                                   timeout=0.2))

    def test_a_folder_error_is_visible_but_not_fatal(self):
        # /rest/db/status carries the folder's own failure in "error"; a
        # broken folder must not make the whole node's status unreadable.
        self.api.db_status["home-alice"] = {"state": "error",
                                            "error": "no access to /home/alice"}
        st = sync_mod.folder_state(self.api, "home-alice")
        self.assertEqual(st["error"], "no access to /home/alice")
        self.assertFalse(sync_mod.wait_until_synced(self.api, "home-alice",
                                                    timeout=0.2))

    def test_conflict_copies_are_found_but_never_resolved(self):
        os.makedirs(os.path.join(self.home, "photos"))
        for name in ("a.txt.sync-conflict-20261104-AAA-BBB.txt",
                     "normal.txt"):
            open(os.path.join(self.home, name), "w").close()
        open(os.path.join(self.home, "photos",
                          "b.jpg.sync-conflict-20261104-CCC-DDD.jpg"),
             "w").close()
        found = sync_mod.find_conflicts(self.home)
        self.assertEqual(len(found), 2)
        self.assertTrue(all(sync_mod.CONFLICT_MARKER in n for n in found))
        # The scan only reports: the conflict copy is still where it was.
        self.assertEqual(os.listdir(os.path.join(self.home, "photos")),
                         ["b.jpg.sync-conflict-20261104-CCC-DDD.jpg"])

    def test_a_folder_that_cannot_be_read_is_not_an_error(self):
        self.assertEqual(sync_mod.find_conflicts(
            os.path.join(self.home, "no-such-folder")), [])


class DocValuesTest(unittest.TestCase):
    def setUp(self):
        self.home = _member("home-server", "aaaa-bbbb")

    def test_the_folder_set_follows_the_membership_list(self):
        joined = _member("vps", "eeee-ffff")
        self.assertEqual([f["id"] for f in
                          sync_mod.home_folders([self.home, joined])],
                         ["home-home-server", "home-vps"])

    def test_default_ignore_list_is_the_one_in_the_doc(self):
        # Patterns are Syncthing .stignore patterns; the list is the built-in
        # one, so a node that never edits .stignore still ignores them.
        self.assertIn(".cache", sync_mod.DEFAULT_IGNORES)
        self.assertIn("*.iso", sync_mod.DEFAULT_IGNORES)
        self.assertIn(".local/share/Trash", sync_mod.DEFAULT_IGNORES)

    def test_the_conflict_marker_is_what_syncthing_writes(self):
        # supermox-sync status greps file names for this; a conflict is
        # something to tell the operator about, never something to fix up.
        self.assertEqual(sync_mod.CONFLICT_MARKER, ".sync-conflict-")


if __name__ == "__main__":
    unittest.main()
