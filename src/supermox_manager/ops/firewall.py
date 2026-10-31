"""Native firewall operations (no GTK).

The firewall exists at three scopes, and the same operations apply to all
three; only the base path changes:

  cluster   /cluster/firewall                 the datacenter-wide firewall
  node      /nodes/{node}/firewall            a host's own firewall
  guest     /nodes/{node}/{kind}/{vmid}/firewall   one VM or container

Every path and parameter name below was read from the running node with
`pvesh usage <path> --verbose` (recorded in .strata/notes-t76-manager-firewall.md);
nothing is guessed. The API verbs map to HTTP: get=GET, create=POST, set=PUT,
delete=DELETE.

Rule fields travel with hyphenated names where the server uses them (only
``icmp-type``); option names keep the server's own spelling (``policy_in``,
``log_level_in`` ...), so set_options passes its keyword arguments through
unchanged. A rule position (``pos``/``moveto``) is a non-negative integer.
"""

import re

from .. import api

# Names the server accepts for aliases, ip sets, groups and rule actions.
_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]+")
RULE_TYPES = ("in", "out", "forward", "group")


def base_for(node=None, kind=None, vmid=None):
    """Return the firewall base path for one scope.

    No node -> the datacenter firewall. A node with no vmid -> that host's
    firewall. A node plus a vmid and kind (qemu or lxc) -> one guest's firewall.
    """
    if node is None:
        if kind is not None or vmid is not None:
            raise ValueError("A guest needs a node; the datacenter firewall takes neither.")
        return "/cluster/firewall"
    node = str(node).strip()
    if not node:
        raise ValueError("Give a node name.")
    if vmid is None:
        if kind is not None:
            raise ValueError("A guest kind needs a machine id.")
        return "/nodes/{}/firewall".format(api.segment(node))
    if kind not in ("qemu", "lxc"):
        raise ValueError("A guest firewall needs kind 'qemu' or 'lxc'.")
    return "/nodes/{}/{}/{}/firewall".format(
        api.segment(node), kind, _vmid(vmid))


def _vmid(value):
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise ValueError("The machine id must be a number.")
    if value < 0:
        raise ValueError("The machine id must be a number.")
    return value


def _pos(value):
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise ValueError("A rule position must be a whole number.")
    if value < 0:
        raise ValueError("A rule position must be a whole number.")
    return value


def _name(value, what):
    value = str(value or "")
    if not _NAME_RE.fullmatch(value):
        raise ValueError("A {} name must start with a letter and use only "
                         "letters, digits, dashes and underscores.".format(what))
    return value


def _rule_params(action=None, type=None, enable=None, source=None, dest=None,
                 proto=None, dport=None, sport=None, iface=None, comment=None,
                 log=None, macro=None, icmp_type=None, pos=None, digest=None):
    params = {}
    if action is not None:
        params["action"] = action
    if type is not None:
        params["type"] = type
    if enable is not None:
        params["enable"] = int(enable)
    for key, value in (("source", source), ("dest", dest), ("proto", proto),
                       ("dport", dport), ("sport", sport), ("iface", iface),
                       ("comment", comment), ("log", log), ("macro", macro),
                       ("digest", digest)):
        if value is not None:
            params[key] = value
    if icmp_type is not None:
        params["icmp-type"] = icmp_type
    if pos is not None:
        params["pos"] = _pos(pos)
    return params


def rules(client, base):
    """GET {base}/rules: the rules on this firewall scope (a list)."""
    return client.request("GET", base + "/rules")


def add_rule(client, base, action, type, **options):
    """POST {base}/rules: create a rule.

    ``action`` (ACCEPT/DROP/REJECT or a group name) and ``type``
    (in, out, forward or group) are required. Optional options (enable, source,
    dest, proto, dport, sport, iface, comment, log, macro, icmp_type, pos,
    digest) are passed through; ``pos`` inserts the rule at that position.
    """
    if not action or not _NAME_RE.fullmatch(str(action)):
        raise ValueError("Give a rule action (ACCEPT, DROP, REJECT or a group name).")
    if type not in RULE_TYPES:
        raise ValueError("Rule type must be one of: " + ", ".join(RULE_TYPES) + ".")
    params = _rule_params(action=action, type=type, **options)
    return client.request("POST", base + "/rules", params)


def update_rule(client, base, pos, **fields):
    """PUT {base}/rules/{pos}: change the rule stored at position pos.

    Keyword arguments use the same names as add_rule (icmp_type maps to
    icmp-type). At least one field must be given.
    """
    params = _rule_params(**fields)
    if not params:
        raise ValueError("Nothing to change.")
    return client.request("PUT", "{}/rules/{}".format(base, _pos(pos)), params)


def move_rule(client, base, pos, moveto):
    """PUT {base}/rules/{pos} with moveto: move a rule to a new position.

    The server ignores every other argument when moveto is present, so this
    sends only moveto.
    """
    return client.request("PUT", "{}/rules/{}".format(base, _pos(pos)),
                          {"moveto": _pos(moveto)})


def delete_rule(client, base, pos):
    """DELETE {base}/rules/{pos}: remove the rule at position pos."""
    return client.request("DELETE", "{}/rules/{}".format(base, _pos(pos)), {})


def options(client, base):
    """GET {base}/options: the firewall options for this scope (a dict)."""
    return client.request("GET", base + "/options")


def set_options(client, base, **fields):
    """PUT {base}/options: change firewall options.

    Keyword arguments are sent with the server's own spelling (``enable``,
    ``policy_in``, ``policy_out``, ``ipfilter``, ``macfilter``, ``log_level_in``
    ...). Booleans are sent as 1/0. At least one field must be given.
    """
    if not fields:
        raise ValueError("Nothing to change.")
    params = {}
    for key, value in fields.items():
        params[key] = 1 if value is True else 0 if value is False else value
    return client.request("PUT", base + "/options", params)


def aliases(client, base):
    """GET {base}/aliases: the IP/network aliases on this scope (a list)."""
    return client.request("GET", base + "/aliases")


def add_alias(client, base, name, cidr, comment=None):
    """POST {base}/aliases: create an IP or network alias.

    ``name`` and ``cidr`` (CIDR format) are required; ``comment`` optional.
    """
    params = {"name": _name(name, "alias"), "cidr": cidr}
    if not cidr:
        raise ValueError("Give the alias CIDR.")
    if comment:
        params["comment"] = comment
    return client.request("POST", base + "/aliases", params)


def delete_alias(client, base, name):
    """DELETE {base}/aliases/{name}: remove an alias."""
    return client.request("DELETE", "{}/aliases/{}".format(base, _name(name, "alias")), {})


def ipsets(client, base):
    """GET {base}/ipset: the IP sets on this scope (a list)."""
    return client.request("GET", base + "/ipset")


def ipset_members(client, base, name):
    """GET {base}/ipset/{name}: the members (CIDR entries) of one IP set."""
    return client.request("GET", base + "/ipset/" + api.segment(name))


def add_ipset(client, base, name, comment=None):
    """POST {base}/ipset: create an empty IP set."""
    params = {"name": _name(name, "ip set")}
    if comment:
        params["comment"] = comment
    return client.request("POST", base + "/ipset", params)


def add_cidr(client, base, name, cidr, comment=None, nomatch=None):
    """POST {base}/ipset/{name}: add an IP/network member to an IP set.

    ``cidr`` is required. ``nomatch`` (boolean) marks the entry as a
    no-match. The set must already exist (create it with add_ipset first).
    """
    if not cidr:
        raise ValueError("Give the CIDR to add.")
    params = {"cidr": cidr}
    if comment:
        params["comment"] = comment
    if nomatch is not None:
        params["nomatch"] = 1 if nomatch else 0
    return client.request("POST", "{}/ipset/{}".format(base, _name(name, "ip set")), params)


def delete_ipset(client, base, name, force=False):
    """DELETE {base}/ipset/{name}: remove an IP set.

    ``force`` (1) also deletes the set's members when it is not empty.
    """
    params = {}
    if force:
        params["force"] = 1
    return client.request("DELETE", "{}/ipset/{}".format(base, _name(name, "ip set")), params)
