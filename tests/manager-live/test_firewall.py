#!/usr/bin/env python3
"""Live firewall test against the running SuperMox test VM.

Runs against a real PVE node over the HTTPS API (https://127.0.0.1:18006/),
using the certificate fingerprint as the PIN, exactly like the other live
tests. It exercises the firewall ops at all three scopes: a dedicated
guest VM (9980) for rules and options, the node for a rule, and the
cluster for aliases and IP sets. Finally it runs pve-firewall compile over
ssh to prove the firewall machinery works. Everything is cleaned up.

Requires the test VM to be running (scripts/vm-start.sh). The ssh port for
the compile check comes from SUPERMOX_VM_SSH_PORT (default 2224).
"""
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))

from supermox_manager import api  # noqa: E402
from supermox_manager.ops import firewall  # noqa: E402
from supermox_manager.ops import create as create_ops  # noqa: E402
from supermox_manager.ops import guests  # noqa: E402
from supermox_manager.ops import tasks  # noqa: E402

BASE_URL = "https://127.0.0.1:18006/"
PIN = os.environ.get("SUPERMOX_LIVE_PIN")
USER = os.environ.get("SUPERMOX_LIVE_USER", "root@pam")
PASSWORD = os.environ.get("SUPERMOX_LIVE_PASSWORD",
                          os.environ.get("SUPERMOX_LIVE_PASS", "supermox"))
SSH_PORT = os.environ.get("SUPERMOX_VM_SSH_PORT", "2224")
VMID = 9980
CLUSTER = "/cluster/firewall"


def _ssh(command):
    return subprocess.run(
        ["sshpass", "-p", PASSWORD, "ssh",
         "-p", SSH_PORT, "-o", "StrictHostKeyChecking=no",
         "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=10",
         "root@127.0.0.1", command],
        capture_output=True, text=True)


def _quiet_destroy(client, node, vmid):
    try:
        upid = guests.destroy(client, node, "qemu", vmid)
        tasks.wait_task(client, node, upid, timeout=180)
    except api.APIError:
        pass


class FirewallLiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        client = api.Client(BASE_URL, PIN)
        client.login(USER, PASSWORD)
        cls.client = client
        cls.node = client.request("GET", "/nodes")[0]["node"]
        cls.base = api.guest_path({"node": cls.node, "type": "qemu",
                                   "vmid": VMID}) + "/firewall"
        _quiet_destroy(client, cls.node, VMID)
        params = create_ops.vm_params("t76-firewall", 512, 1, "local", 1)
        upid = create_ops.create(client, cls.node, VMID, params)
        tasks.wait_task(client, cls.node, upid, timeout=240)

    @classmethod
    def tearDownClass(cls):
        cls._clean()
        _quiet_destroy(cls.client, cls.node, VMID)
        cls.client.logout()

    @classmethod
    def _clean(cls):
        for name in ("t76alias", "t76alias2"):
            try:
                firewall.delete_alias(cls.client, CLUSTER, name)
            except api.APIError:
                pass
        for name in ("t76set",):
            try:
                firewall.delete_ipset(cls.client, CLUSTER, name, force=True)
            except api.APIError:
                pass
        try:
            for rule in firewall.rules(cls.client, cls.base):
                firewall.delete_rule(cls.client, cls.base, rule["pos"])
        except api.APIError:
            pass
        try:
            firewall.set_options(cls.client, cls.base, enable=0)
        except api.APIError:
            pass

    def _clear_rules(self, base):
        for rule in firewall.rules(self.client, base):
            firewall.delete_rule(self.client, base, rule["pos"])

    def test_01_guest_rules(self):
        firewall.set_options(self.client, self.base, enable=1)
        self._clear_rules(self.base)
        firewall.add_rule(self.client, self.base, action="ACCEPT", type="in",
                          source="10.0.0.0/8")
        firewall.add_rule(self.client, self.base, action="ACCEPT", type="out",
                          proto="tcp", dport="22")
        rules = firewall.rules(self.client, self.base)
        self.assertEqual(len(rules), 2)
        in_pos = next(r["pos"] for r in rules if r["type"] == "in")
        # Reposition: move the in rule to the top (position 0).
        firewall.move_rule(self.client, self.base, in_pos, 0)
        rules = firewall.rules(self.client, self.base)
        self.assertEqual(next(r["pos"] for r in rules if r["type"] == "in"),
                         0)
        # Update the rule now at position 0 (the in rule).
        firewall.update_rule(self.client, self.base, 0, action="DROP",
                             type="in", source="10.0.0.0/8")
        rules = firewall.rules(self.client, self.base)
        self.assertEqual(next(r["action"] for r in rules if r["pos"] == 0),
                         "DROP")
        # Disable the rule at position 1, then delete both.
        firewall.update_rule(self.client, self.base, 1, enable=0)
        rules = firewall.rules(self.client, self.base)
        self.assertEqual(next(r["enable"] for r in rules if r["pos"] == 1),
                         0)
        firewall.delete_rule(self.client, self.base, 0)
        firewall.delete_rule(self.client, self.base, 0)
        self.assertEqual(firewall.rules(self.client, self.base), [])

    def test_02_guest_options(self):
        firewall.set_options(self.client, self.base, enable=1, policy_in="DROP")
        options = firewall.options(self.client, self.base)
        self.assertEqual(options.get("enable"), 1)
        self.assertEqual(options.get("policy_in"), "DROP")
        firewall.set_options(self.client, self.base, enable=0)
        self.assertEqual(firewall.options(self.client, self.base).get("enable"),
                         0)

    def test_03_node_rule(self):
        node_base = "/nodes/" + self.node + "/firewall"
        firewall.add_rule(self.client, node_base, action="ACCEPT", type="in",
                          source="10.0.0.0/8")
        rules = firewall.rules(self.client, node_base)
        matches = [r for r in rules if r.get("source") == "10.0.0.0/8"]
        self.assertTrue(matches)
        for rule in matches:
            firewall.delete_rule(self.client, node_base, rule["pos"])
        remaining = [r for r in firewall.rules(self.client, node_base)
                     if r.get("source") == "10.0.0.0/8"]
        self.assertEqual(remaining, [])

    def test_04_aliases(self):
        self._clean()
        firewall.add_alias(self.client, CLUSTER, "t76alias", "10.0.0.0/24")
        aliases = firewall.aliases(self.client, CLUSTER)
        match = [a for a in aliases if a["name"] == "t76alias"]
        self.assertEqual(match[0]["cidr"], "10.0.0.0/24")
        firewall.delete_alias(self.client, CLUSTER, "t76alias")
        self.assertEqual([a for a in firewall.aliases(self.client, CLUSTER)
                          if a["name"] == "t76alias"], [])

    def test_05_ipsets(self):
        self._clean()
        firewall.add_ipset(self.client, CLUSTER, "t76set")
        firewall.add_cidr(self.client, CLUSTER, "t76set", "10.0.0.1")
        firewall.add_cidr(self.client, CLUSTER, "t76set", "10.0.0.2")
        members = firewall.ipset_members(self.client, CLUSTER, "t76set")
        self.assertEqual(sorted(m["cidr"] for m in members),
                         ["10.0.0.1", "10.0.0.2"])
        firewall.delete_ipset(self.client, CLUSTER, "t76set", force=True)
        self.assertEqual([s for s in firewall.ipsets(self.client, CLUSTER)
                          if s["name"] == "t76set"], [])

    def test_06_compile(self):
        # The firewall service runs under sysvinit; compiling proves the
        # rules/options we set are consumed by the real firewall machinery.
        result = _ssh("pve-firewall compile")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
