"""t74: native users, groups, roles, permissions and API tokens, live.

Full round-trip against the running node: create a group, create a user in it,
grant a role, log in AS that user, confirm it cannot read the syslog, then mint
an API token for it and call /version with the token. Everything is torn down
afterwards. Names are fixed (t74g, t74u@pve, t74t) and leftovers are removed
first so the test is repeatable.
"""

import os
import secrets
import unittest

from supermox_manager import api
from supermox_manager.ops import access

URL = os.environ["SUPERMOX_LIVE_URL"]
PIN = os.environ["SUPERMOX_LIVE_PIN"]
ROOT = os.environ["SUPERMOX_LIVE_USER"]
ROOT_PASSWORD = os.environ["SUPERMOX_LIVE_PASSWORD"]

GROUP = "t74g"
USER = "t74u@pve"
TOKEN = "t74t"


def _quiet(client, op, *args, **kwargs):
    try:
        op(client, *args, **kwargs)
    except Exception:
        pass


class Permissions(unittest.TestCase):
    def setUp(self):
        self.client = api.Client(URL, PIN)
        self.client.login(ROOT, ROOT_PASSWORD)
        self.node = self.client.request("GET", "/nodes")[0]["node"]
        # remove leftovers from a previous run, in dependency order
        _quiet(self.client, access.delete_token, USER, TOKEN)
        _quiet(self.client, access.delete_user, USER)
        _quiet(self.client, access.delete_group, GROUP)

    def tearDown(self):
        try:
            _quiet(self.client, access.revoke, "/vms", "PVEVMUser", groups=GROUP)
        except Exception:
            pass
        _quiet(self.client, access.delete_token, USER, TOKEN)
        _quiet(self.client, access.delete_user, USER)
        _quiet(self.client, access.delete_group, GROUP)
        self.client.logout()

    def test_permissions_round_trip(self):
        # 1. create the group first (a user cannot join a group that does not exist)
        access.create_group(self.client, GROUP, comment="t74 test group")
        groups = [g["groupid"] for g in access.groups(self.client)]
        self.assertIn(GROUP, groups)

        # 2. create the user, in that group, with a random password
        password = secrets.token_urlsafe(16)
        access.create_user(self.client, USER, password=password, groups=GROUP,
                           comment="t74 test user")
        user = access.get_user(self.client, USER)
        self.assertIn(GROUP, user["groups"])

        # 3. grant PVEVMUser on /vms to the group
        access.grant(self.client, "/vms", "PVEVMUser", groups=GROUP, propagate=True)
        acl = access.acl(self.client)
        self.assertTrue(any(row.get("roleid") == "PVEVMUser"
                            and row.get("ugid") == GROUP and row.get("type") == "group"
                            and row.get("path") == "/vms" for row in acl))

        # 4. log in AS the user with a second client — this must work
        as_user = api.Client(URL, PIN)
        as_user.login(USER, password)
        self.assertEqual(as_user.username, USER)

        # 5. the user cannot read the syslog (PVEVMUser does not grant PVE.Audit)
        with self.assertRaises(api.APIError):
            as_user.request("GET", "/nodes/{}/syslog".format(api.segment(self.node)))
        as_user.logout()

        # 6. mint an API token for the user and call /version with it
        secret = access.create_token(self.client, USER, TOKEN, privsep=0,
                                     comment="t74 test token")
        self.assertTrue(secret)
        with_token = api.Client(URL, PIN)
        with_token.use_token("{}!{}".format(USER, TOKEN), secret)
        version = with_token.request("GET", "/version")
        self.assertIn("version", version)
        with_token.logout()

        # the token is now visible on the user
        tokens = list(access.get_user(self.client, USER).get("tokens") or {})
        self.assertIn(TOKEN, tokens)
