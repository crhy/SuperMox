#!/usr/bin/env python3
"""Unit tests for the home sync layer (src/supermox/sync.py).

The cluster's signed membership list is the only input: it decides which
devices this node's Syncthing instance has and which folders exist. Syncthing
itself is stood in by FakeApi, which remembers what was written to it, so
the tests can check both the first reconcile and the second one, which
must write nothing.
"""

import base64
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src"))

from supermox import secret, sync as sync_mod


# The join daemon's derived state: the cluster /48 and the 16 entropy bytes
# a node address is derived from (see state.py and secret.node_address).
DERIVED = {"overlay_prefix": "fd00:1234:5678::/48", "entropy": b"\x9f" * 16}


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
    """Stands in for Syncthing's REST API over the paths sync.py uses.

    Every write is recorded, so a test can ask whether a reconcile changed
    anything at all.
    """

    def __init__(self):
        self.devices = []
        self.folders = []
        self.options = {}
        self.ignores = {}
        self.writes = []

    def _folder_id(self, path: str) -> str:
        return path[len(sync_mod.API_ROOT) + len("/config/folders/"):-len("/ignore")]

    def get(self, path: str):
        if path == "%s/config/devices" % sync_mod.API_ROOT:
            return [dict(d) for d in self.devices]
        if path == "%s/config/folders" % sync_mod.API_ROOT:
            return [dict(f) for f in self.folders]
        if path.endswith("/ignore"):
            fid = self._folder_id(path)
            return list(self.ignores[fid]) if fid in self.ignores else None
        if path == "%s/config/" % sync_mod.API_ROOT:
            return {"options": dict(self.options)}
        return None

    def put(self, path, obj):
        self.writes.append((path, obj))
        if path.endswith("/config/devices"):
            self.devices = [dict(d) for d in obj]
        elif path.endswith("/config/folders"):
            self.folders = [dict(f) for f in obj]
        elif path.endswith("/ignore"):
            self.ignores[self._folder_id(path)] = list(obj)
        else:
            self.options.update(obj.get("options") or {})

    def post(self, path, obj):
        raise AssertionError("sync.py must not POST: .stignore is written "
                             "through the folder's ignore endpoint")


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
        self.assertEqual(self.api.devices[0]["address"],
                         "tcp://[%s]:%d" % (self.phone["overlay_addr"],
                                            sync_mod.DEFAULT_PORT))

    def test_the_local_node_is_never_a_device_of_itself(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        self.assertEqual([d["name"] for d in self.api.devices],
                         ["cccc-dddd"])
        sync_mod.reconcile(self.members, "starlte", None, self.api)
        self.assertEqual([d["name"] for d in self.api.devices], ["aaaa-bbbb"])

    def test_a_member_without_a_device_id_is_skipped_and_says_so(self):
        # Backwards compatible: an entry written before Syncthing existed
        # carries no syncthing_id, so there is nothing to add, and the
        # operator is told which member that was.
        late = _member("late-joiner")
        summary = sync_mod.reconcile(self.members + [late],
                                     "home-server", None, self.api)
        self.assertEqual([d["name"] for d in self.api.devices], ["cccc-dddd"])
        self.assertEqual(summary["skipped"], ["late-joiner"])

    def test_a_new_member_becomes_a_device(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        before = len(self.api.writes)
        joined = _member("vps", "eeee-ffff")
        sync_mod.reconcile(self.members + [joined], "home-server", None, self.api)
        self.assertEqual(sorted(d["name"] for d in self.api.devices),
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
        self.assertEqual([d["name"] for d in self.api.devices], ["zzzz-zzzz"])
        self.assertGreater(len(self.api.writes), before)

    def test_a_member_leaving_removes_the_device(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        sync_mod.reconcile([self.home], "home-server", None, self.api)
        self.assertEqual(self.api.devices, [])

    def test_reconcile_is_idempotent(self):
        # Boot runs it every time; a second run against an already-correct
        # instance must cost reads only.
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
        self.assertEqual([d["name"] for d in self.api.devices],
                         ["aaaa-2222", "cccc-dddd", "zzzz-1111"])


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
            self.assertEqual(folder["share_devices"], ["aaaa-bbbb", "cccc-dddd"])

    def test_a_selective_member_is_not_offered_the_whole_home(self):
        # docs/shared-home.md: a phone that opted out of the full copy gets
        # folders it picked itself, never the home folder of another member.
        selective = _member("starlte", "cccc-dddd", sync_mode="selective")
        sync_mod.reconcile([self.home, selective], "home-server", None, self.api)
        for folder in self.api.folders:
            self.assertEqual(folder["share_devices"], ["aaaa-bbbb"])

    def test_file_versioning_is_on(self):
        # A deleted or overwritten file stays recoverable.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        for folder in self.api.folders:
            self.assertEqual(folder["versioning"], sync_mod.VERSIONING)

    def test_stignore_is_written_for_every_folder(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        for folder in sync_mod.home_folders(self.members):
            self.assertEqual(self.api.ignores[folder["id"]],
                             sync_mod.DEFAULT_IGNORES)

    def test_an_edited_ignore_list_is_rewritten(self):
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        writes = len(self.api.writes)
        folders = sync_mod.home_folders(self.members)
        folders[0] = dict(folders[0], ignore=[".cache", "secrets/"])
        sync_mod.reconcile(self.members, "home-server", folders, self.api)
        self.assertGreater(len(self.api.writes), writes)
        self.assertEqual(self.api.ignores["home-home-server"],
                         [".cache", "secrets/"])

    def test_a_renamed_folder_is_a_new_folder(self):
        # The old one disappears from the configuration; its files stay on
        # disk, as the doc says.
        sync_mod.reconcile(self.members, "home-server", None, self.api)
        old_ids = {f["id"] for f in self.api.folders}
        folders = sync_mod.home_folders(self.members)
        folders[0] = dict(folders[0], id="home-photos", path="/home/rhy/photos")
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


class HomeFoldersTest(unittest.TestCase):
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
