"""Offline unit tests for the access operations: exact paths and parameter names.

A recording client proves each call hits the endpoint and parameter set the
running node advertises (see .strata/notes-t74-manager-permissions.md). No
server and no GTK needed. Passwords and token secrets are checked to be
present in the request but never asserted as logged.
"""

import unittest

from supermox_manager.ops import access
from supermox_manager import api


class Recorder:
    def __init__(self, responses=None):
        self.calls = []
        self.responses = list(responses or [])

    def request(self, method, path, params=None):
        self.calls.append((method, path, params))
        if self.responses:
            return self.responses.pop(0)
        return {}


class AccessOps(unittest.TestCase):
    def setUp(self):
        self.client = Recorder()

    def test_users_plain_and_full(self):
        access.users(self.client)
        self.assertEqual(self.client.calls[-1], ("GET", "/access/users", None))
        access.users(self.client, full=True)
        self.assertEqual(self.client.calls[-1], ("GET", "/access/users", {"full": 1}))

    def test_get_user_path_segmented(self):
        access.get_user(self.client, "t74u@pve")
        self.assertEqual(self.client.calls[-1],
                         ("GET", "/access/users/t74u%40pve", None))

    def test_get_user_requires_userid(self):
        with self.assertRaises(ValueError):
            access.get_user(self.client, "")
        self.assertEqual(self.client.calls, [])

    def test_create_user_required_and_options(self):
        access.create_user(self.client, "t74u@pve", password="s3cret",
                           groups=["t74g", "other"], comment="c", enable=True, expire=0)
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/access/users"))
        self.assertEqual(params, {
            "userid": "t74u@pve", "password": "s3cret", "groups": "t74g,other",
            "comment": "c", "enable": 1, "expire": 0})

    def test_create_user_requires_userid(self):
        with self.assertRaises(ValueError):
            access.create_user(self.client, "")
        self.assertEqual(self.client.calls, [])

    def test_create_user_minimal(self):
        access.create_user(self.client, "u@pve")
        self.assertEqual(self.client.calls[-1][2], {"userid": "u@pve"})

    def test_update_user_path_and_params(self):
        access.update_user(self.client, "t74u@pve", enable=False, groups="t74g",
                           append=True, comment="x")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/access/users/t74u%40pve"))
        self.assertEqual(params, {"enable": 0, "groups": "t74g", "append": 1, "comment": "x"})

    def test_update_user_requires_userid(self):
        with self.assertRaises(ValueError):
            access.update_user(self.client, "")
        self.assertEqual(self.client.calls, [])

    def test_delete_user(self):
        access.delete_user(self.client, "t74u@pve")
        self.assertEqual(self.client.calls[-1],
                         ("DELETE", "/access/users/t74u%40pve", {}))

    def test_groups_index(self):
        access.groups(self.client)
        self.assertEqual(self.client.calls[-1], ("GET", "/access/groups", None))

    def test_create_group(self):
        access.create_group(self.client, "t74g", comment="team")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("POST", "/access/groups"))
        self.assertEqual(params, {"groupid": "t74g", "comment": "team"})

    def test_create_group_requires_groupid(self):
        with self.assertRaises(ValueError):
            access.create_group(self.client, "")
        self.assertEqual(self.client.calls, [])

    def test_delete_group(self):
        access.delete_group(self.client, "t74g")
        self.assertEqual(self.client.calls[-1], ("DELETE", "/access/groups/t74g", {}))

    def test_roles_index(self):
        access.roles(self.client)
        self.assertEqual(self.client.calls[-1], ("GET", "/access/roles", None))

    def test_acl_index(self):
        access.acl(self.client)
        self.assertEqual(self.client.calls[-1], ("GET", "/access/acl", None))

    def test_grant_params(self):
        access.grant(self.client, "/vms", "PVEVMUser", groups=["t74g"], propagate=True)
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/access/acl"))
        self.assertEqual(params, {"path": "/vms", "roles": "PVEVMUser",
                                  "groups": "t74g", "propagate": 1})

    def test_grant_needs_a_subject(self):
        with self.assertRaises(ValueError):
            access.grant(self.client, "/vms", "PVEVMUser")
        self.assertEqual(self.client.calls, [])

    def test_grant_needs_path_and_role(self):
        with self.assertRaises(ValueError):
            access.grant(self.client, "", "PVEVMUser", groups="g")
        with self.assertRaises(ValueError):
            access.grant(self.client, "/vms", "", groups="g")
        self.assertEqual(self.client.calls, [])

    def test_revoke_sets_delete(self):
        access.revoke(self.client, "/vms", "PVEVMUser", users=["t74u@pve"], propagate=False)
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/access/acl"))
        self.assertEqual(params, {"path": "/vms", "roles": "PVEVMUser",
                                  "users": "t74u@pve", "propagate": 0, "delete": 1})

    def test_grant_tokens_subject(self):
        access.grant(self.client, "/", "PVEAuditor", tokens=["t74u@pve!t74t"])
        self.assertEqual(self.client.calls[-1][2]["tokens"], "t74u@pve!t74t")

    def test_create_token_returns_secret_once(self):
        client = Recorder([{"full-tokenid": "t74u@pve!t74t",
                           "info": {"comment": "c", "privsep": "0"},
                           "value": "SECRET-UUID"}])
        secret = access.create_token(client, "t74u@pve", "t74t", privsep=0, comment="c")
        self.assertEqual(secret, "SECRET-UUID")
        method, path, params = client.calls[-1]
        self.assertEqual((method, path), ("POST", "/access/users/t74u%40pve/token/t74t"))
        self.assertEqual(params, {"privsep": 0, "comment": "c"})

    def test_create_token_defaults_privsep(self):
        client = Recorder([{"value": "x"}])
        access.create_token(client, "u@pve", "t")
        self.assertEqual(client.calls[-1][2], {"privsep": 1})

    def test_create_token_raises_without_value(self):
        client = Recorder([{"info": {}}])
        with self.assertRaises(api.APIError):
            access.create_token(client, "u@pve", "t")

    def test_create_token_requires_names(self):
        with self.assertRaises(ValueError):
            access.create_token(self.client, "", "t")
        with self.assertRaises(ValueError):
            access.create_token(self.client, "u@pve", "")
        self.assertEqual(self.client.calls, [])

    def test_delete_token_path(self):
        access.delete_token(self.client, "t74u@pve", "t74t")
        self.assertEqual(self.client.calls[-1],
                         ("DELETE", "/access/users/t74u%40pve/token/t74t", {}))

    def test_change_password_params(self):
        access.change_password(self.client, "t74u@pve", "newpass")
        method, path, params = self.client.calls[-1]
        self.assertEqual((method, path), ("PUT", "/access/password"))
        self.assertEqual(params, {"userid": "t74u@pve", "password": "newpass"})

    def test_change_password_confirmation(self):
        access.change_password(self.client, "t74u@pve", "new", confirmation_password="old")
        self.assertEqual(self.client.calls[-1][2],
                         {"userid": "t74u@pve", "password": "new",
                          "confirmation-password": "old"})

    def test_change_password_requires_password(self):
        with self.assertRaises(ValueError):
            access.change_password(self.client, "u@pve", None)
        self.assertEqual(self.client.calls, [])


if __name__ == "__main__":
    unittest.main()
