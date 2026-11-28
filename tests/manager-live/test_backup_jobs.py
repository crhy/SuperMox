#!/usr/bin/env python3
"""Live tests for scheduled backup jobs against a running SuperMox node.

Skipped unless SUPERMOX_LIVE_URL points at a reachable node.  Creates a
job, lists it, changes it, runs it once, and deletes it.  Cleans up
before and after so a partial run never wedges the next one.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))

from supermox_manager import api
from supermox_manager.ops import jobs, storage, tasks

import guestfixture

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASS = os.environ.get("SUPERMOX_LIVE_PASS", "")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

JOB = "t75-job"
VMID = 9950
CTID = 9953
NAME = "t-79-backup"
NODE = "supermox"


class BackupJobsLive(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not LIVE_URL:
            raise unittest.SkipTest("SUPERMOX_LIVE_URL not set")
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASS)

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "client", None):
            try:
                cls._cleanup(cls.client)
            except Exception:
                pass
            cls.client.logout()

    @staticmethod
    def _cleanup(client):
        try:
            jobs.delete_backup_job(client, JOB)
        except api.APIError:
            pass

    def test_schedule_validation(self):
        self.assertTrue(jobs.validate_schedule("sun 03:00"))
        self.assertTrue(jobs.validate_schedule("daily"))
        with self.assertRaises(ValueError):
            jobs.validate_schedule("02 4 * * *; rm -rf /")
        with self.assertRaises(ValueError):
            jobs.validate_schedule("")

    def test_create_list_update_delete(self):
        self._cleanup(self.client)
        jobs.create_backup_job(self.client, "sun 03:00", vmid=VMID,
                               storage="local", mode="snapshot",
                               enabled=1, comment="t75",
                               prune_backups={"keep-last": 8}, job_id=JOB)
        found = [r for r in jobs.backup_jobs(self.client)
                 if r.get("id") == JOB]
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["schedule"], "sun 03:00")
        self.assertEqual(found[0]["storage"], "local")
        self.assertEqual(str(found[0].get("vmid")), str(VMID))

        jobs.update_backup_job(self.client, JOB, schedule="Mon 04:00",
                               storage="local", mode="stop", enabled=0,
                               comment="t75 changed")
        found = [r for r in jobs.backup_jobs(self.client)
                 if r.get("id") == JOB]
        self.assertEqual(found[0]["schedule"], "Mon 04:00")
        self.assertEqual(int(found[0]["enabled"]), 0)

        jobs.delete_backup_job(self.client, JOB)
        self.assertEqual(
            [r for r in jobs.backup_jobs(self.client) if r.get("id") == JOB],
            [])

    def test_run_now(self):
        # A one-off backup run needs a guest, so create one we own. Prefer a
        # container: snapshot mode needs no guest agent, so it is reliable on
        # a shared VM (the qemu here has no agent installed).
        guestfixture.destroy(self.client, NODE, "lxc", CTID)
        try:
            guestfixture.create_ct(self.client, NODE, CTID, NAME, LIVE_PASSWORD)
            self._dump()
        finally:
            guestfixture.destroy(self.client, NODE, "lxc", CTID)

    def _dump(self):
        upid = jobs.run_now(self.client, NODE, {"vmid": CTID, "node": NODE,
                                                "mode": "snapshot",
                                                "compress": "gzip",
                                                "storage": "local"})
        self.assertTrue(upid)
        tasks.wait_task(self.client, NODE, upid)
        backups = [row for row in storage.content(self.client, NODE, "local",
                                                  content_type="backup")]
        self.assertTrue(backups, "the run should have produced a backup volume")
        newest = sorted(b["volid"] for b in backups)[-1]
        storage.delete_volume(self.client, NODE, "local", newest)


if __name__ == "__main__":
    unittest.main()
