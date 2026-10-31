"""Permissions: native users, groups, roles, access control and API tokens.

A Gtk.Notebook with five tabs — Users, Groups, Roles, Permissions, API tokens.
Every endpoint and parameter name was read from the running node with `pvesh
usage` (see .strata/notes-t74-manager-permissions.md); nothing is guessed. A
user cannot be created into a group that does not exist yet, so the Groups tab
comes before the Users tab in the workflow. An API token's secret is returned
exactly once by create_token(); the token tab shows it in a dialog with a Copy
button and a warning that it can never be retrieved again — nothing here stores
it, and passwords and secrets are never logged.
"""

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from .. import api
from ..ops import access

TITLE = "Permissions"
SUBTITLE = "Users, groups, roles, access and API tokens."

TABS = ("Users", "Groups", "Roles", "Permissions", "API tokens")


def _clear(box):
    for child in box.get_children():
        box.remove(child)
        child.destroy()


def _table(results, columns, rows, select=None):
    """Build a tree view and pack it into a tab's results box (GTK thread)."""
    model = Gtk.ListStore(*([str] * len(columns)))
    for row in rows:
        model.append([str(v) for v in row])
    tree = Gtk.TreeView(model=model)
    tree.set_headers_visible(True)
    for index, name in enumerate(columns):
        renderer = Gtk.CellRendererText()
        renderer.set_property("ypad", 10)
        renderer.set_property("xpad", 8)
        column = Gtk.TreeViewColumn(name, renderer, text=index)
        column.set_expand(True)
        tree.append_column(column)
    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    scroll.add(tree)
    results.pack_start(scroll, True, True, 0)
    if select:
        tree.connect("row-activated", select)
    return tree


def _results(manager, name):
    """Return the live results box for a tab, or None if the page was redrawn."""
    box = getattr(manager, "perm_results", {}).get(name)
    if box is None:
        return None
    try:
        if box.get_parent() is None:
            return None
    except Exception:
        return None
    return box


def _deliver(manager, name, builder):
    """Wrap a table builder so it only paints into the current page."""
    def show(rows):
        if manager.current != TITLE:
            return
        box = _results(manager, name)
        if box is None:
            return
        _clear(box)
        builder(manager, box, rows)
        box.show_all()
    return show


def _yes(value):
    return str(value).strip().lower() in ("1", "yes", "true", "on")


# --- Users ---------------------------------------------------------------

def _users_rows(manager, box, rows):
    manager.perm_user_map = {row["userid"]: row for row in rows}
    manager.perm_sel_user = None
    _table(box, ("User", "Enabled", "Expires", "Groups", "Comment"),
           [(row.get("userid", ""),
             "yes" if row.get("enable", 1) else "no",
             "never" if not row.get("expire") else row.get("expire"),
             row.get("groups", ""),
             row.get("comment", ""))
            for row in rows],
           select=lambda view, path, _c: _pick_user(manager, view, path))


def _pick_user(manager, view, path):
    manager.perm_sel_user = manager.perm_user_map.get(view.get_model()[path][0])


def _load_users(manager):
    manager.work(lambda: access.users(manager.client, full=True),
                 _deliver(manager, "Users", _users_rows))


def _create_user(manager):
    values = manager.form(
        "Create a user",
        [("userid", "User id (name@realm, e.g. alice@pve)", "new@pve", False),
         ("password", "Initial password", "", True),
         ("groups", "Groups (comma separated, must already exist)", "", False),
         ("comment", "Comment", "", False),
         ("enable", "Enabled (1 or 0)", "1", False),
         ("expire", "Expire at (epoch seconds, 0 = never)", "0", False)],
        "Create",
        "Creates a new user. Any group named here must already exist — create it "
        "on the Groups tab first. The password is held only for this request.")
    if values is None:
        return
    if not values["userid"].strip():
        manager.message("Check the fields", "Give at least the user id (name@realm).")
        return
    options = {}
    if values["password"]:
        options["password"] = values["password"]
    if values["groups"].strip():
        options["groups"] = values["groups"].strip()
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    options["enable"] = 1 if _yes(values["enable"]) else 0
    if values["expire"].strip():
        options["expire"] = int(values["expire"].strip())
    client = manager.client

    def op():
        access.create_user(client, values["userid"].strip(), **options)
    manager.work(op, lambda _r: (manager.status.set_text("Created " + values["userid"].strip()),
                                 _load_users(manager)))


def _selected(manager, attr, what, tab):
    found = getattr(manager, attr, None)
    if not found:
        manager.message("Select a {} first".format(what),
                        "Open the {} tab and double-click the {} you want to change."
                        .format(tab, what))
    return found


def _change_user(manager):
    user = _selected(manager, "perm_sel_user", "user", "Users")
    if not user:
        return
    values = manager.form(
        "Change {}".format(user["userid"]),
        [("comment", "Comment", user.get("comment", ""), False),
         ("enable", "Enabled (1 or 0)", "1" if user.get("enable", 1) else "0", False),
         ("expire", "Expire at (epoch seconds, 0 = never)", str(user.get("expire", 0) or 0), False),
         ("groups", "Groups (comma separated, replaces the list)", user.get("groups", ""), False)],
        "Change",
        "Updates this user's stored configuration. The user id itself does not change.")
    if values is None:
        return
    options = {"comment": values["comment"].strip(),
               "enable": 1 if _yes(values["enable"]) else 0,
               "expire": int(values["expire"].strip() or 0),
               "groups": values["groups"].strip()}
    client = manager.client
    manager.work(lambda: access.update_user(client, user["userid"], **options),
                 lambda _r: (manager.status.set_text("Updated " + user["userid"]),
                             _load_users(manager)))


def _delete_user(manager):
    user = _selected(manager, "perm_sel_user", "user", "Users")
    if not user:
        return
    if not manager.confirm("Delete user {}?".format(user["userid"]),
                           "Remove this user and its account. This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: access.delete_user(client, user["userid"]),
                 lambda _r: (manager.status.set_text("Deleted " + user["userid"]),
                             _load_users(manager)))


def _change_password(manager):
    user = _selected(manager, "perm_sel_user", "user", "Users")
    if not user:
        return
    values = manager.form(
        "Change password · {}".format(user["userid"]),
        [("password", "New password", "", True)],
        "Change",
        "Sets a new password for this user. The password is held only for this request.")
    if values is None or not values["password"]:
        return
    client = manager.client
    manager.work(lambda: access.change_password(client, user["userid"], values["password"]),
                 lambda _r: manager.status.set_text("Password changed for " + user["userid"]))


# --- Groups --------------------------------------------------------------

def _groups_rows(manager, box, rows):
    manager.perm_group_map = {row["groupid"]: row for row in rows}
    manager.perm_sel_group = None
    _table(box, ("Group", "Comment"),
           [(row.get("groupid", ""), row.get("comment", "")) for row in rows],
           select=lambda view, path, _c: _pick_group(manager, view, path))


def _pick_group(manager, view, path):
    manager.perm_sel_group = manager.perm_group_map.get(view.get_model()[path][0])


def _load_groups(manager):
    manager.work(lambda: access.groups(manager.client),
                 _deliver(manager, "Groups", _groups_rows))


def _create_group(manager):
    values = manager.form(
        "Create a group",
        [("groupid", "Group name", "team", False),
         ("comment", "Comment", "", False)],
        "Create",
        "Creates a new group. Create groups before adding users to them.")
    if values is None:
        return
    if not values["groupid"].strip():
        manager.message("Check the fields", "Give a group name.")
        return
    client = manager.client
    options = {}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    manager.work(lambda: access.create_group(client, values["groupid"].strip(), **options),
                 lambda _r: (manager.status.set_text("Created group " + values["groupid"].strip()),
                             _load_groups(manager)))


def _delete_group(manager):
    group = _selected(manager, "perm_sel_group", "group", "Groups")
    if not group:
        return
    if not manager.confirm("Delete group {}?".format(group["groupid"]),
                           "Remove this group. Users keep existing but lose this membership. "
                           "This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: access.delete_group(client, group["groupid"]),
                 lambda _r: (manager.status.set_text("Deleted group " + group["groupid"]),
                             _load_groups(manager)))


# --- Roles ---------------------------------------------------------------

def _roles_rows(manager, box, rows):
    _table(box, ("Role", "Special", "Privileges"),
           [(row.get("roleid", ""),
             "yes" if row.get("special") else "no",
             row.get("privs", "") or "—")
            for row in rows])


def _load_roles(manager):
    manager.work(lambda: access.roles(manager.client),
                 _deliver(manager, "Roles", _roles_rows))


# --- Permissions (ACL) ---------------------------------------------------

def _acl_rows(manager, box, rows):
    manager.perm_acl_map = {}
    for index, row in enumerate(rows):
        manager.perm_acl_map[index] = row
    manager.perm_sel_acl = None

    def pick(view, path, _c):
        manager.perm_sel_acl = manager.perm_acl_map.get(path)

    _table(box, ("Path", "Role", "Subject type", "Subject", "Propagate"),
           [(row.get("path", ""), row.get("roleid", ""), row.get("type", ""),
             row.get("ugid", ""), "yes" if row.get("propagate") else "no")
            for row in rows],
           select=pick)


def _load_acl(manager):
    manager.work(lambda: access.acl(manager.client),
                 _deliver(manager, "Permissions", _acl_rows))


def _add_permission(manager):
    values = manager.form(
        "Add a permission",
        [("path", "Path (e.g. /vms, /)", "/vms", False),
         ("role", "Role (e.g. PVEVMUser)", "PVEVMUser", False),
         ("users", "Users (comma separated)", "", False),
         ("groups", "Groups (comma separated)", "", False),
         ("tokens", "Tokens (comma separated)", "", False),
         ("propagate", "Propagate to sub-paths (1 or 0)", "1", False)],
        "Add",
        "Grants a role on a path to the named users, groups or tokens. Give at "
        "least one subject. Propagate lets sub-paths inherit the permission.")
    if values is None:
        return
    if not values["path"].strip() or not values["role"].strip():
        manager.message("Check the fields", "Give the path and the role.")
        return
    if not any(values[k].strip() for k in ("users", "groups", "tokens")):
        manager.message("Check the fields", "Give at least one user, group or token.")
        return
    options = {}
    for key in ("users", "groups", "tokens"):
        if values[key].strip():
            options[key] = values[key].strip()
    client = manager.client
    manager.work(lambda: access.grant(client, values["path"].strip(), values["role"].strip(),
                                      propagate=_yes(values["propagate"]), **options),
                 lambda _r: (manager.status.set_text("Granted " + values["role"].strip()),
                             _load_acl(manager)))


def _remove_permission(manager):
    entry = _selected(manager, "perm_sel_acl", "permission", "Permissions")
    if not entry:
        return
    subject = entry.get("ugid", "")
    kind = entry.get("type", "user")
    if not manager.confirm("Remove {} on {}?".format(entry.get("roleid", ""), entry.get("path", "")),
                           "Revoke {} on {} from {} ({}). This cannot be undone."
                           .format(entry.get("roleid", ""), entry.get("path", ""), subject, kind)):
        return
    options = {"users": subject} if kind == "user" else (
             {"groups": subject} if kind == "group" else {"tokens": subject})
    client = manager.client
    manager.work(lambda: access.revoke(client, entry["path"], entry["roleid"],
                                       propagate=_yes(entry.get("propagate")), **options),
                 lambda _r: (manager.status.set_text("Revoked " + entry.get("roleid", "")),
                             _load_acl(manager)))


# --- API tokens ----------------------------------------------------------

def _token_rows(manager, box, rows):
    manager.perm_token_map = {}
    out = []
    for user in rows:
        for token in (user.get("tokens") or []):
            key = (user["userid"], token.get("tokenid", ""))
            manager.perm_token_map[key] = (user["userid"], token)
            out.append((user["userid"], token.get("tokenid", ""),
                        "own ACLs" if token.get("privsep") else "full rights",
                        token.get("comment", ""),
                        "never" if not token.get("expire") else token.get("expire")))

    def pick(view, path, _c):
        userid = view.get_model()[path][0]
        tokenid = view.get_model()[path][1]
        manager.perm_sel_token = manager.perm_token_map.get((userid, tokenid))

    manager.perm_sel_token = None
    if not out:
        box.pack_start(Gtk.Label(label="No API tokens on any user."), False, False, 6)
        return
    _table(box, ("User", "Token", "Privilege separation", "Comment", "Expires"), out,
           select=pick)


def _load_tokens(manager):
    manager.work(lambda: access.users(manager.client, full=True),
                 _deliver(manager, "API tokens", _token_rows))


def _show_token_secret(manager, secret):
    """Show a freshly created token's secret once, with a Copy button."""
    dialog = Gtk.Dialog(title="API token created", transient_for=manager.window, modal=True)
    area = dialog.get_content_area()
    area.set_border_width(20)
    area.set_spacing(12)
    warning = Gtk.Label(label="This secret is shown once. It cannot be retrieved again — "
                        "copy it now or discard it and create a new token.")
    warning.set_line_wrap(True)
    warning.set_max_width_chars(58)
    warning.get_style_context().add_class("preview")
    area.pack_start(warning, False, False, 6)
    entry = Gtk.Entry()
    entry.set_text(secret)
    entry.set_editable(False)
    entry.set_width_chars(48)
    area.pack_start(entry, False, False, 0)

    def do_copy(_button, value=secret):
        try:
            clipboard = Gtk.Clipboard.new(Gtk.ClipboardFormat.GTK)
            clipboard.set_text(value, -1)
            clipboard.set_application_id("supermox-manager")
            clipboard.commit()
        except Exception:
            pass

    copy = Gtk.Button(label="Copy to clipboard")
    copy.connect("clicked", do_copy)
    area.pack_start(copy, False, False, 0)
    dialog.add_button("Close", Gtk.ResponseType.CLOSE)
    dialog.show_all()
    dialog.run()
    entry.set_text("")
    dialog.destroy()


def _create_token(manager):
    values = manager.form(
        "Create an API token",
        [("userid", "User the token belongs to (name@realm)", "root@pam", False),
         ("tokenid", "Token name (after the !)", "mytoken", False),
         ("privsep", "Privilege separation (1 = own ACLs, 0 = full user rights)", "1", False),
         ("comment", "Comment", "", False)],
        "Create",
        "Creates a token named userid!tokenid. The secret is shown once and can "
        "never be retrieved. Privilege separation 1 restricts the token to its own "
        "ACLs; 0 gives it the full rights of the user.")
    if values is None:
        return
    if not values["userid"].strip() or not values["tokenid"].strip():
        manager.message("Check the fields", "Give the user and the token name.")
        return
    client = manager.client
    options = {}
    if values["comment"].strip():
        options["comment"] = values["comment"].strip()
    manager.work(lambda: access.create_token(client, values["userid"].strip(),
                                             values["tokenid"].strip(),
                                             privsep=1 if _yes(values["privsep"]) else 0, **options),
                 lambda secret: _show_token_secret(manager, secret))


def _delete_token(manager):
    token = _selected(manager, "perm_sel_token", "token", "API tokens")
    if not token:
        return
    userid, info = token
    if not manager.confirm("Delete token {}!{}?".format(userid, info.get("tokenid", "")),
                           "Revoke this API token. Any script using it stops working. "
                           "This cannot be undone."):
        return
    client = manager.client
    manager.work(lambda: access.delete_token(client, userid, info.get("tokenid", "")),
                 lambda _r: (manager.status.set_text("Deleted token " + info.get("tokenid", "")),
                             _load_tokens(manager)))


# --- Page --------------------------------------------------------------

DESCRIPTIONS = {
    "Users": "Create, change, delete users and change their passwords. "
             "Double-click a row to select it.",
    "Groups": "Create and delete groups. Create groups before adding users to them.",
    "Roles": "The roles you can grant, and the privileges each one contains (read-only).",
    "Permissions": "The access control list. Add and remove permissions; double-click a row to select it.",
    "API tokens": "Create and delete API tokens. A token's secret is shown once, never stored.",
}

ACTIONS = {
    "Users": (("Users", lambda m: _load_users(m)),
              ("Create user", _create_user),
              ("Change user", _change_user),
              ("Delete user", _delete_user),
              ("Change password", _change_password)),
    "Groups": (("Groups", lambda m: _load_groups(m)),
               ("Create group", _create_group),
               ("Delete group", _delete_group)),
    "Roles": (("Roles", lambda m: _load_roles(m)),),
    "Permissions": (("Permissions", lambda m: _load_acl(m)),
                    ("Add permission", _add_permission),
                    ("Remove permission", _remove_permission)),
    "API tokens": (("Tokens", lambda m: _load_tokens(m)),
                   ("Create token", _create_token),
                   ("Delete token", _delete_token)),
}


def render(manager, content):
    from ..app import label
    notebook = Gtk.Notebook()
    notebook.set_hexpand(True)
    notebook.set_vexpand(True)
    manager.perm_results = {}
    for name in TABS:
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        page.set_hexpand(True)
        page.set_vexpand(True)
        page.pack_start(label(DESCRIPTIONS[name], "subtitle"), False, False, 4)
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for text, callback in ACTIONS[name]:
            actions.pack_start(Gtk.Button(label=text), False, False, 0)
        page.pack_start(actions, False, False, 0)
        results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        results.set_hexpand(True)
        results.set_vexpand(True)
        page.pack_start(results, True, True, 0)
        manager.perm_results[name] = results
        notebook.add(page)
        notebook.set_tab_label_text(page, name)
    content.pack_start(notebook, True, True, 0)
