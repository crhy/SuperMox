"""Native user, group, role, permission (ACL) and API-token operations (no GTK).

Every path and parameter name below was read from the running node with
`pvesh usage` (recorded in .strata/notes-t74-manager-permissions.md); nothing is
guessed. A user cannot be created into a group that does not exist yet, so
callers create the group first. An API token's secret is returned exactly once
by create_token(); nothing here stores it — the caller shows it and it is then
gone. Passwords and token secrets are never logged.
"""

from .. import api


def _subject(value):
    """Normalise a users/groups/tokens selector to the comma string the API wants."""
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        return ",".join(str(v) for v in value)
    return str(value)


def users(client, full=False):
    """GET /access/users: the user index.

    ``full`` (default 0) includes group and token information. In the plain
    list a user's ``groups`` is a comma string; with full=1 ``tokens`` is a list.
    """
    params = {}
    if full:
        params["full"] = 1
    return client.request("GET", "/access/users", params or None)


def get_user(client, userid):
    """GET /access/users/{userid}: one user's configuration (groups is a list)."""
    if not userid:
        raise ValueError("Give a userid.")
    return client.request("GET", "/access/users/" + api.segment(userid))


def create_user(client, userid, password=None, groups=None, comment=None,
                enable=None, expire=None):
    """POST /access/users: create a new user.

    ``userid`` is required and must be ``name@realm``. ``password`` is the
    initial password (never logged). ``groups`` is a comma string or list of
    group names — each must already exist. ``enable`` (bool) and ``expire``
    (epoch seconds, 0 = never) are optional. Returns the created userid.
    """
    if not userid:
        raise ValueError("Give a userid.")
    params = {"userid": userid}
    if password is not None:
        params["password"] = password
    if groups is not None:
        params["groups"] = _subject(groups)
    if comment is not None:
        params["comment"] = comment
    if enable is not None:
        params["enable"] = int(bool(enable))
    if expire is not None:
        params["expire"] = int(expire)
    return client.request("POST", "/access/users", params)


def update_user(client, userid, **options):
    """PUT /access/users/{userid}: change a stored user's configuration.

    The userid is in the path, not the body. Optional options: comment, email,
    enable (bool), expire (int), firstname, lastname, groups (comma string or
    list), keys, append (bool, only meaningful with groups). Returns null.
    """
    if not userid:
        raise ValueError("Give a userid.")
    params = {}
    for key in ("comment", "email", "firstname", "lastname", "keys"):
        if options.get(key) is not None:
            params[key] = options[key]
    if options.get("enable") is not None:
        params["enable"] = int(bool(options["enable"]))
    if options.get("expire") is not None:
        params["expire"] = int(options["expire"])
    if options.get("groups") is not None:
        params["groups"] = _subject(options["groups"])
    if options.get("append") is not None:
        params["append"] = int(bool(options["append"]))
    return client.request("PUT", "/access/users/" + api.segment(userid), params)


def delete_user(client, userid):
    """DELETE /access/users/{userid}: remove a user."""
    if not userid:
        raise ValueError("Give a userid.")
    return client.request("DELETE", "/access/users/" + api.segment(userid), {})


def groups(client):
    """GET /access/groups: the group index (array of {groupid, comment})."""
    return client.request("GET", "/access/groups")


def create_group(client, groupid, comment=None):
    """POST /access/groups: create a new group. ``groupid`` is required."""
    if not groupid:
        raise ValueError("Give a groupid.")
    params = {"groupid": groupid}
    if comment is not None:
        params["comment"] = comment
    return client.request("POST", "/access/groups", params)


def delete_group(client, groupid):
    """DELETE /access/groups/{groupid}: remove a group."""
    if not groupid:
        raise ValueError("Give a groupid.")
    return client.request("DELETE", "/access/groups/" + api.segment(groupid), {})


def roles(client):
    """GET /access/roles: the role index (array of {roleid, privs, special})."""
    return client.request("GET", "/access/roles")


def acl(client):
    """GET /access/acl: the access control list.

    Returns rows of {path, propagate, roleid, type (user|group|token), ugid}.
    """
    return client.request("GET", "/access/acl")


def _acl_params(path, role, users, groups, tokens, propagate, delete):
    params = {"path": path, "roles": role}
    if users is not None:
        params["users"] = _subject(users)
    if groups is not None:
        params["groups"] = _subject(groups)
    if tokens is not None:
        params["tokens"] = _subject(tokens)
    if propagate is not None:
        params["propagate"] = int(bool(propagate))
    if delete:
        params["delete"] = 1
    return params


def grant(client, path, role, users=None, groups=None, tokens=None, propagate=True):
    """PUT /access/acl: add a permission.

    ``path`` (e.g. /vms) and ``role`` (e.g. PVEVMUser) are required. Give at
    least one subject: ``users``, ``groups`` or ``tokens`` (comma string or list).
    ``propagate`` (default True) allows the permission to be inherited by
    sub-paths. Returns null.
    """
    if not path:
        raise ValueError("Give an access control path.")
    if not role:
        raise ValueError("Give a role.")
    if users is None and groups is None and tokens is None:
        raise ValueError("Give at least one user, group or token to grant to.")
    return client.request("PUT", "/access/acl",
                          _acl_params(path, role, users, groups, tokens, propagate, False))


def revoke(client, path, role, users=None, groups=None, tokens=None, propagate=True):
    """PUT /access/acl with delete=1: remove a permission.

    Same selectors as grant(); the ``delete`` flag makes the API remove the
    matching ACL entries instead of adding them. Returns null.
    """
    if not path:
        raise ValueError("Give an access control path.")
    if not role:
        raise ValueError("Give a role.")
    if users is None and groups is None and tokens is None:
        raise ValueError("Give at least one user, group or token to revoke from.")
    return client.request("PUT", "/access/acl",
                          _acl_params(path, role, users, groups, tokens, propagate, True))


def create_token(client, userid, tokenid, privsep=1, comment=None):
    """POST /access/users/{userid}/token/{tokenid}: create an API token.

    Returns the token SECRET exactly once (the API's ``value``); it cannot be
    retrieved afterwards, so the caller must show it and nothing here stores it.
    ``privsep`` (default 1) restricts the token to its own ACLs; 0 gives it the
    full privileges of the corresponding user. ``comment`` is optional.
    """
    if not userid:
        raise ValueError("Give a userid.")
    if not tokenid:
        raise ValueError("Give a token name.")
    params = {"privsep": int(bool(privsep))}
    if comment is not None:
        params["comment"] = comment
    data = client.request(
        "POST",
        "/access/users/{}/token/{}".format(api.segment(userid), api.segment(tokenid)),
        params)
    if not isinstance(data, dict) or not data.get("value"):
        raise api.APIError("The node did not return a token secret.")
    return data["value"]


def delete_token(client, userid, tokenid):
    """DELETE /access/users/{userid}/token/{tokenid}: remove an API token."""
    if not userid:
        raise ValueError("Give a userid.")
    if not tokenid:
        raise ValueError("Give a token name.")
    return client.request(
        "DELETE",
        "/access/users/{}/token/{}".format(api.segment(userid), api.segment(tokenid)),
        {})


def change_password(client, userid, password, confirmation_password=None):
    """PUT /access/password: change a user's password.

    ``userid`` and ``password`` are required; the password is never logged.
    ``confirmation_password`` (the current password of the user performing the
    change) is optional and passed through when given. Returns null.
    """
    if not userid:
        raise ValueError("Give a userid.")
    if password is None:
        raise ValueError("Give a new password.")
    params = {"userid": userid, "password": password}
    if confirmation_password is not None:
        params["confirmation-password"] = confirmation_password
    return client.request("PUT", "/access/password", params)
