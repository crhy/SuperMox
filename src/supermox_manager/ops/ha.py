"""High availability: which guests the CRM keeps running, and where.

Three separate things, and the Manager must not confuse them:

  resources   which guests are under HA management, and how they may be
              restarted or relocated
  rules       on which nodes those guests may run (this version has replaced
              the old HA *groups* with rules; GET /cluster/ha/groups still
              exists but the node reports the migration)
  status      what the CRM is doing right now (GET /cluster/ha/status/current)

Endpoints (read from `pvesh usage` on the running node):
  GET    /cluster/ha/resources            list managed resources
  POST   /cluster/ha/resources            manage a guest (--sid vm:100)
  PUT    /cluster/ha/resources/{rid}      change one resource
  DELETE /cluster/ha/resources/{rid}      stop managing it
  GET    /cluster/ha/rules                list rules
  POST   /cluster/ha/rules                create a rule (--rule, --type)
  DELETE /cluster/ha/rules/{id}           remove a rule
  GET    /cluster/ha/status/current       live CRM state

A resource id contains a colon (vm:100), so it goes through api.volume() in
paths, never api.segment().
"""

import re

from .. import api

# Requested state of a managed resource, exactly as the server spells it.
STATES = ("disabled", "enabled", "ignored", "started", "stopped")
RULE_TYPES = ("node-affinity", "resource-affinity")
# Rule names and the machine part of a resource id; both stay one URL segment.
_SID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def sid(kind, identifier):
    """Build a resource id: 'vm:100' or 'ct:101'.

    The server also accepts the bare number, but the typed form is what it
    returns and what the delete path needs, so we always send that.
    """
    if kind not in ("vm", "ct"):
        raise ValueError("HA manages virtual machines and containers.")
    value = str(identifier).strip()
    if not value or not _SID_RE.fullmatch(value):
        raise ValueError("The machine id may only contain letters, digits, dots, "
                         "dashes and underscores.")
    return "{}:{}".format(kind, value)


def _rid(value):
    """A resource id used in a path keeps its colon."""
    value = str(value or "")
    kind, _, name = value.partition(":")
    if kind not in ("vm", "ct") or not name or not _SID_RE.fullmatch(name):
        raise ValueError("Give the resource id as vm:<id> or ct:<id>.")
    return value


def _nodes(value):
    """Nodes travel as a comma-separated list, optionally with priorities."""
    if value in (None, ""):
        return []
    if isinstance(value, str):
        return [part.strip() for part in value.split(",") if part.strip()]
    return [str(part).strip() for part in value if str(part).strip()]


def resources(client, kind=None):
    """GET /cluster/ha/resources: every guest under HA management."""
    params = {}
    if kind:
        params["type"] = kind
    return client.request("GET", "/cluster/ha/resources", params or None)


def add_resource(client, identifier, kind="vm", state="started", group=None,
                 failback=None, auto_rebalance=None, max_restart=None,
                 max_relocate=None, comment=None):
    """POST /cluster/ha/resources: put a guest under HA management.

    The guest has to exist in the cluster config first; the server rejects
    a resource id it cannot find. Returns null; read it back with resources().
    """
    params = {"sid": sid(kind, identifier), "type": kind, "state": state}
    if state not in STATES:
        raise ValueError("State must be one of: " + ", ".join(STATES) + ".")
    if group:
        params["group"] = group
    for name, value in (("failback", failback), ("auto-rebalance", auto_rebalance)):
        if value is not None:
            params[name] = 1 if value else 0
    for name, value in (("max_restart", max_restart), ("max_relocate", max_relocate)):
        if value is not None:
            params[name] = int(value)
    if comment:
        params["comment"] = comment
    return client.request("POST", "/cluster/ha/resources", params)


def update_resource(client, rid, **fields):
    """PUT /cluster/ha/resources/{rid}: change one managed resource.

    Keyword arguments use the Python spelling of the API names
    (``auto_rebalance``, ``max_restart`` ...); underscores become hyphens
    except for max_restart/max_relocate, which the server spells with an
    underscore.
    """
    params = {}
    for key, value in fields.items():
        # max_restart/max_relocate are spelled with an underscore by the server
        # itself; every other hyphenated name follows the Python spelling.
        name = key if key in ("max_restart", "max_relocate") else key.replace("_", "-")
        if name == "state" and value not in STATES:
            raise ValueError("State must be one of: " + ", ".join(STATES) + ".")
        if name in ("failback", "auto-rebalance"):
            value = 1 if value else 0
        params[name] = value
    if not params:
        raise ValueError("Nothing to change.")
    return client.request("PUT",
                          "/cluster/ha/resources/{}".format(api.volume(rid)),
                          params)


def remove_resource(client, rid):
    """DELETE /cluster/ha/resources/{rid}: stop managing a guest."""
    return client.request("DELETE",
                          "/cluster/ha/resources/{}".format(api.volume(_rid(rid))))


def rules(client, kind=None):
    """GET /cluster/ha/rules: the rules saying where resources may run."""
    params = {}
    if kind:
        if kind not in RULE_TYPES:
            raise ValueError("Rule type must be one of: " + ", ".join(RULE_TYPES) + ".")
        params["type"] = kind
    return client.request("GET", "/cluster/ha/rules", params or None)


def add_rule(client, rule, kind, nodes=None, resources=None, affinity=None,
             strict=None, disabled=None, comment=None):
    """POST /cluster/ha/rules: create a rule.

    ``kind`` is node-affinity (these nodes prefer to run the listed
    resources) or resource-affinity (this resource prefers these nodes).
    ``affinity`` is positive (run on the given nodes) or negative (run
    anywhere but those). This version requires ``resources`` even for
    node-affinity rules, so callers must pass the resources the rule
    covers.
    """
    if kind not in RULE_TYPES:
        raise ValueError("Rule type must be one of: " + ", ".join(RULE_TYPES) + ".")
    if not rule or not _SID_RE.fullmatch(str(rule)):
        raise ValueError("A rule name may only contain letters, digits, dots, "
                         "dashes and underscores.")
    nodes = _nodes(nodes)
    resources = _nodes(resources)
    if not nodes or not resources:
        raise ValueError("A rule needs both nodes and resources.")
    params = {"rule": str(rule), "type": kind, "nodes": nodes,
              "resources": resources}
    if affinity:
        if affinity not in ("positive", "negative"):
            raise ValueError("Affinity is either 'positive' or 'negative'.")
        params["affinity"] = affinity
    if strict is not None:
        params["strict"] = 1 if strict else 0
    if disabled is not None:
        params["disable"] = 1 if disabled else 0
    if comment:
        params["comment"] = comment
    return client.request("POST", "/cluster/ha/rules", params)


def remove_rule(client, rule):
    """DELETE /cluster/ha/rules/{id}: remove a rule."""
    if not rule or not _SID_RE.fullmatch(str(rule)):
        raise ValueError("A rule name may only contain letters, digits, dots, "
                         "dashes and underscores.")
    return client.request("DELETE",
                          "/cluster/ha/rules/{}".format(api.segment(rule)))


def groups(client):
    """GET /cluster/ha/groups: the deprecated group list.

    Kept for display only: this version reports that groups have been
    migrated to rules, so callers should show rules() instead and never try
    to create a group here.
    """
    return client.request("GET", "/cluster/ha/groups")


def status(client):
    """GET /cluster/ha/status/current: what the CRM is doing right now.

    One row per cluster node and quorum entry: id, node, status, type,
    quorate, and for managed resources the CRM state and request state.
    """
    return client.request("GET", "/cluster/ha/status/current")
