#!/usr/bin/env python3
"""Live tests for the network page against a running Manager.

Skipped unless SUPERMOX_LIVE_URL is set (see tests/manager-live.sh). Exercises the
full create -> apply -> read -> update -> apply -> delete -> apply round-trip on a
throwaway interface (type eth, the only non-enum-surprising manual type on this
build). Always cleans up the test interface and re-applies.
"""
import os
import unittest

from supermox_manager import api
from supermox_manager.ops import network, tasks

LIVE_URL = os.environ.get("SUPERMOX_LIVE_URL")
LIVE_PIN = os.environ.get("SUPERMOX_LIVE_PIN")
IFACE = "vmbr98"


class NetworkLive(unittest.TestCase):
    def setUp(self):
        self.client = api.Client(LIVE_URL, LIVE_PIN)
        self.client.login("root@pam", "supermox")
        self.node = self.client.request("GET", "/nodes")[0]["node"]

    def _apply(self):
        upid = network.apply(self.client, self.node)
        self.assertTrue(upid.startswith("UPID:"), "apply returned {!r}".format(upid))
        self.assertTrue(tasks.wait_task(self.client, self.node, upid, timeout=120,
                                        allow_warnings=True),
                        "network apply task did not finish")

    def test_create_apply_update_delete(self):
        try:
            network.create(self.client, self.node, IFACE, "eth")
            self._apply()
            names = [i["iface"] for i in network.interfaces(self.client, self.node)]
            self.assertIn(IFACE, names, "created iface missing after apply: {}".format(names))

            network.update(self.client, self.node, IFACE, type="eth", autostart=0)
            self._apply()
            names = [i["iface"] for i in network.interfaces(self.client, self.node)]
            self.assertIn(IFACE, names, "iface missing after update+apply")
        finally:
            network.delete(self.client, self.node, IFACE)
            self._apply()
        names = [i["iface"] for i in network.interfaces(self.client, self.node)]
        self.assertNotIn(IFACE, names, "iface still present after delete+apply")

    def test_apply_is_idempotent(self):
        # Applying with no pending change must still succeed.
        self._apply()
        self._apply()


if __name__ == "__main__":
    if not LIVE_URL:
        raise SystemExit("SUPERMOX_LIVE_URL is not set")
    unittest.main()
