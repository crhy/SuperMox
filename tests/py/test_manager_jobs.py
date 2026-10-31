"""Unit tests for scheduled backup jobs: exact paths, params and validation.

The recording client proves each call hits the endpoint and parameter names
the running node advertises (see .strata/notes-t75-manager-backup-jobs-ha.md).
No server and no GTK needed.
"""

import unittest

from supermox_manager.ops import jobs


class Recorder:
    def __init__(self):
        self.calls = []

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        return "ok"


class BackupJobs(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_list(self):
        jobs.backup_jobs(self.client)
        self.assertEqual(self.client.calls, [("GET", "/cluster/backup", None)])

    def test_create_one_machine(self):
        jobs.create_backup_job(self.client, "sun 03:00", vmid=100, storage="local")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/cluster/backup"))
        self.assertEqual(params, {"schedule": "sun 03:00", "mode": "snapshot",
                                   "compress": 0, "enabled": 1, "vmid": "100",
                                   "storage": "local"})

    def test_create_all_machines(self):
        jobs.create_backup_job(self.client, "daily", all=True, storage="local",
                               prune_backups={"keep-daily": 7, "keep-all": 1},
                               notes_template="{{guestname}}", comment="nightly",
                               job_id="nightly")
        params = self.client.calls[-1][2]
        self.assertEqual(params["all"], 1)
        self.assertNotIn("vmid", params)
        self.assertEqual(params["prune-backups"], "keep-all=1,keep-daily=7")
        self.assertEqual(params["notes-template"], "{{guestname}}")
        self.assertEqual((params["id"], params["comment"]), ("nightly", "nightly"))

    def test_create_requires_a_target(self):
        with self.assertRaises(ValueError):
            jobs.create_backup_job(self.client, "daily")

    def test_schedule_validation(self):
        for bad in ("", "   ", "sun;rm -rf /", "sun 03:00\nrm", "sun\t03:00"):
            with self.assertRaises(ValueError):
                jobs.create_backup_job(self.client, bad, vmid=100)
        for good in ("daily", "sun 03:00", "*-*-* 03:00:00", "Mon 22:00",
                     "Sat, May 3 03:00"):
            self.assertEqual(jobs.validate_schedule(good), good)
        # Surrounding whitespace is not part of a schedule.
        self.assertEqual(jobs.validate_schedule("  daily  "), "daily")

    def test_update_maps_underscores_to_hyphens(self):
        jobs.update_backup_job(self.client, "nightly", schedule="Mon 01:00",
                               prune_backups={"keep-all": 0}, enabled=False,
                               notes_template="{{node}}")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/cluster/backup/nightly"))
        self.assertEqual(params, {"schedule": "Mon 01:00", "prune-backups": "keep-all=0",
                                   "enabled": 0, "notes-template": "{{node}}"})

    def test_update_rejects_empty_and_bad(self):
        with self.assertRaises(ValueError):
            jobs.update_backup_job(self.client, "nightly")
        with self.assertRaises(ValueError):
            jobs.update_backup_job(self.client, "nightly", schedule="")

    def test_delete_encodes_the_id(self):
        jobs.delete_backup_job(self.client, "night job")
        self.assertEqual(self.client.calls[-1][1], "/cluster/backup/night%20job")
        with self.assertRaises(ValueError):
            jobs.delete_backup_job(self.client, "")
        with self.assertRaises(ValueError):
            jobs.delete_backup_job(self.client, "a/b")

    def test_run_now_replays_the_job(self):
        job = {"id": "nightly", "schedule": "sun 03:00", "vmid": "100",
               "storage": "local", "mode": "stop", "compress": "gzip",
               "prune-backups": {"keep-daily": 7}, "notes-template": "{{guestname}}",
               "enabled": 1, "comment": "nightly"}
        jobs.run_now(self.client, "atlas", job)
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/nodes/atlas/vzdump"))
        self.assertEqual(params, {"storage": "local", "mode": "stop",
                                   "compress": "gzip", "vmid": 100,
                                   "prune-backups": "keep-daily=7",
                                   "notes-template": "{{guestname}}",
                                   "notification-mode": "legacy-sendmail"})
        # The schedule, id, comment and enabled flag belong to the job, not
        # to a single run, so they must not travel.
        for name in ("schedule", "id", "comment", "enabled"):
            self.assertNotIn(name, params)

    def test_run_now_all_job(self):
        jobs.run_now(self.client, "atlas", {"id": "x", "all": 1, "storage": "local"})
        self.assertEqual(self.client.calls[-1][2],
                         {"storage": "local", "all": 1, "mode": "snapshot",
                          "notification-mode": "legacy-sendmail"})

    def test_run_now_needs_a_target(self):
        with self.assertRaises(ValueError):
            jobs.run_now(self.client, "atlas", {"id": "x"})


if __name__ == "__main__":
    unittest.main()
