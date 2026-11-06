#!/usr/bin/env python3
"""Live tests for the RRD history the graphs page draws.

Skipped unless SUPERMOX_LIVE_URL is set (tests/manager-live.sh exports it, with
the SSL fingerprint, only when a VM is up). These call the same ops functions
pages/graphs.py uses, so the four rrddata endpoints, their parameters and the
shape of the rows are proven against a real pvestatd + pmxcfs, not a fake.

The archives are filed by pvestatd, not by these tests, so the tests that need
a sample wait for one instead of accepting an archive that has none.

The last test is the only write: it creates VMID 9990, asks the server to start
it, waits for pvestatd to file the guest in its archive, then destroys it.
"""
import os
import time
import unittest

from supermox_manager import api
from supermox_manager.ops import create as create_ops
from supermox_manager.ops import guests, metrics, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN", "")
LIVE_USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
LIVE_PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD", "supermox")

VMID = 9990


@unittest.skipUnless(LIVE_URL, "SUPERMOX_LIVE_URL is not set (no VM running)")
class MetricsLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = api.Client(LIVE_URL, LIVE_PIN)
        cls.client.login(LIVE_USER, LIVE_PASSWORD)
        cls.node = cls.client.request("GET", "/nodes")[0]["node"]

    @classmethod
    def tearDownClass(cls):
        try:
            cls.client.logout()
        except Exception:  # noqa: BLE001 - best effort
            pass

    def test_node_hour_archive(self):
        rows = metrics.rrd(self.client, self.node, timeframe="hour")
        self.assertIsInstance(rows, list)
        self.assertGreater(len(rows), 10, "hour timeframe should be one row per minute")
        for row in rows:
            self.assertIn("time", row)
        first = rows[0]
        self.assertIn("time", first)
        seen = set()
        for row in rows:
            seen.update(row)
        for field in ("cpu", "iowait", "memtotal", "memused", "netin", "netout",
                      "roottotal", "rootused"):
            self.assertIn(field, seen, "node archive is missing " + field)
        points = metrics.series(rows, "cpu")
        self.assertTrue(points, "pvestatd has not broadcast a node sample yet")
        self.assertLessEqual(len(points), len(rows))
        for _, value in points:
            self.assertGreaterEqual(value, 0.0)
        # cpu is a fraction of one core, so a live sample is far below 1.0.
        self.assertLessEqual(points[-1][1], 1.0, "newest cpu sample is not a fraction")
        used = [value for _, value in metrics.series(rows, "memused")]
        self.assertTrue(used, "memused should be sampled on a live node")
        scaled, unit = metrics.scale(used, "bytes")
        self.assertIn(unit, ("KiB", "MiB", "GiB", "TiB", "PiB"))
        self.assertEqual(len(scaled), len(used))

    def test_node_day_archive_and_max_consolidation(self):
        rows = metrics.rrd(self.client, self.node, timeframe="day")
        self.assertGreater(len(rows), 100, "day timeframe should be one row per minute")
        self.assertLessEqual(len(rows), 1440)
        maximum = metrics.rrd(self.client, self.node, timeframe="hour", cf="MAX")
        self.assertTrue(maximum, "cf=MAX should be accepted")
        self.assertLess(len(maximum), len(rows), "hour samples are finer than day ones")
        peak = [value for _, value in metrics.series(maximum, "loadavg")]
        self.assertTrue(peak, "loadavg should be archived")

    def test_storage_archive(self):
        # pmxcfs creates the storage archive before pvestatd has filed its
        # first sample, so on a node that has only just been installed every
        # bucket in the hour window reads back as NaN and the rows carry
        # nothing but 'time'. Wait for a row that carries 'total' rather
        # than accepting the empty archive; pvestatd runs its cycle every
        # 10 s, so 180 s is many cycles and costs nothing once the field
        # is there.
        deadline = time.time() + 180
        rows, seen = [], set()
        while True:
            try:
                rows = metrics.rrd(self.client, self.node, kind="storage",
                                   storage="local", timeframe="hour")
            except api.APIError:
                # no archive file for this storage yet
                rows = []
            seen = set()
            for row in rows:
                seen.update(row)
            if "total" in seen or time.time() > deadline:
                break
            time.sleep(5)
        self.assertGreater(len(rows), 10)
        self.assertIn("total", seen,
                      "pvestatd never filed a storage sample")
        self.assertIn("used", seen)
        self.assertNotIn("cpu", seen, "storage archive must not carry node fields")
        used = [value for _, value in metrics.series(rows, "used")]
        total = [value for _, value in metrics.series(rows, "total")]
        self.assertTrue(used and total, "storage usage should be archived")
        scaled, unit = metrics.scale(used + total, "bytes")
        self.assertIn(unit, ("KiB", "MiB", "GiB", "TiB", "PiB"))

    def test_guest_archive_of_a_started_machine(self):
        self._destroy(VMID)
        try:
            params = create_ops.vm_params("smoke-history", 512, 1, "local", 1)
            upid = create_ops.create(self.client, self.node, VMID, params)
            tasks.wait_task(self.client, self.node, upid, timeout=240)
            start = self.client.request(
                "POST",
                api.guest_path({"node": self.node, "type": "qemu", "vmid": VMID})
                + "/status/start", {})
            self.assertTrue(start, "start request should be accepted")
            # pvestatd files every guest once per cycle (10 s), but the hour
            # view averages 60 s steps, so the first point needs a whole step
            # boundary plus a cycle, and a cycle can wait up to 30 s on the
            # QEMU CPU-flag probe (qemu-server 0004). 90 s missed it once
            # (release-check 2026-11-06); allow 240 s. Data is still required.
            deadline = time.time() + 240
            points, rows = [], []
            while True:
                try:
                    rows = metrics.rrd(self.client, self.node, kind="qemu",
                                       vmid=VMID, timeframe="hour")
                except api.APIError:
                    # no archive file for this guest until pvestatd files it
                    rows = []
                points = metrics.series(rows, "maxmem")
                if points or time.time() > deadline:
                    break
                time.sleep(5)
            self.assertTrue(points,
                            "VMID %d never appeared in the RRD archive" % VMID)
            self.assertLessEqual(len(rows), 61)
            _, unit = metrics.scale([value for _, value in points], "bytes")
            self.assertIn(unit, ("B", "KiB", "MiB", "GiB", "TiB", "PiB"))
        finally:
            self._destroy(VMID)

    def _destroy(self, vmid):
        try:
            upid = guests.destroy(self.client, self.node, "qemu", vmid)
            tasks.wait_task(self.client, self.node, upid, timeout=180)
        except api.APIError:
            pass


if __name__ == "__main__":
    unittest.main()
