"""The cluster itself: quorum, nodes, the cluster log, datacenter options.

Endpoints (read from `pvesh usage` on the running node; see
.strata/notes-t78-manager-cluster.md for the measured output):

  GET  /cluster/status        one 'cluster' row plus one row per node
  GET  /cluster/config/nodes  the node list (every value here is a string)
  GET  /cluster/log           the cluster log, newest entry first
  GET  /cluster/options       datacenter options
  PUT  /cluster/options       change them ('delete' names options to unset)
  GET  /cluster/tasks         every node's task list
  GET  /cluster/config/join   the join config: NOT shown, it carries the
                              cluster's own secrets (pve_fp, config_digest)

Two things this version forces on us, both measured:

  /cluster/log and /cluster/tasks do not accept 'limit' ("Unknown option:
  limit"), so the Manager slices the answer after fetching it.

  A hash-valued option travels as a plain string: 'migration=secure' is
  accepted and comes back as {'type': 'secure'}.  Sending a JSON object or a
  JSON string is rejected with HTTP 400 "Check fields: migration".
"""

import re
import time

# /cluster/log is unbounded; the page asks for the last 50 entries.
MAX_LOG = 50

# Enums exactly as `pvesh usage /cluster/options --verbose` spells them.
CONSOLE = ("applet", "html5", "vv", "xtermjs")
KEYBOARD = ("da", "de", "de-ch", "en-gb", "en-us", "es", "fi", "fr", "fr-be",
            "fr-ca", "fr-ch", "hu", "is", "it", "ja", "lt", "mk", "nl", "no",
            "pl", "pt", "pt-br", "sl", "sv", "tr")
LANGUAGE = ("ar", "ca", "da", "de", "en", "es", "eu", "fa", "fr", "he", "hr",
            "it", "ja", "ka", "kr", "nb", "nl", "nn", "pl", "pt_BR", "ru",
            "sl", "sv", "tr", "ukr", "zh_CN", "zh_TW")
MIGRATION = ("secure", "insecure")

# The option names the server itself uses, underscores and all.
ENUM_FIELDS = {"console": CONSOLE, "keyboard": KEYBOARD,
               "language": LANGUAGE, "migration": MIGRATION}
TEXT_FIELDS = ("description", "mac_prefix", "email_from", "http_proxy")

# /cluster/log 'pri' is a syslog level number (measured: 6 = info, 3 = err).
LEVEL_NAMES = {0: "emerg", 1: "alert", 2: "crit", 3: "err", 4: "warning",
               5: "notice", 6: "info", 7: "debug"}

_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_HOST_RE = re.compile(r"[A-Za-z0-9.\[\]:_-]+(:[0-9]{1,5})?")


def cluster_row(rows):
    """The 'cluster' row of /cluster/status: where the quorum numbers live.

    Returns None when the answer carries no cluster row, which is what a
    node that is not in a cluster answers.
    """
    for row in rows or []:
        if row.get("type") == "cluster":
            return row
    return None


def node_rows(rows):
    """The node rows of /cluster/status, in the order the node returned them."""
    return [row for row in rows or [] if row.get("type") == "node"]


def status(client):
    """GET /cluster/status: quorum (cluster row) plus one row per node."""
    return client.request("GET", "/cluster/status")


def nodes(client):
    """GET /cluster/config/nodes: name, nodeid, quorum_votes, ring0_addr.

    Every value in this answer is a string, unlike /cluster/status where
    nodes/quorate are numbers; callers that add them must convert first.
    """
    return client.request("GET", "/cluster/config/nodes")


def log(client, max=MAX_LOG):
    """GET /cluster/log: the cluster log, newest entry first.

    The endpoint has no 'limit' parameter (measured: "Unknown option: limit"),
    so the whole log comes back and the last `max` entries are taken here.
    The order is the server's own: the numeric part of 'id' ("26:supermox")
    decreases down the list, which the live test checks.
    """
    rows = client.request("GET", "/cluster/log")
    if max is None or max <= 0:
        return list(rows or [])
    return list(rows or [])[:int(max)]


def cluster_tasks(client):
    """GET /cluster/tasks: the task list of every node in one answer.

    This is the same call api.Client.tasks() makes for the Tasks page; it
    lives here so the cluster page has one place to ask for it.  It has no
    'limit' parameter either.
    """
    return client.request("GET", "/cluster/tasks")


def options(client):
    """GET /cluster/options: the datacenter options.

    Without Sys.Audit on '/' the node returns only part of them; measured on
    the test node that is allowed-tags, description and mac_prefix (plus
    whatever has been set explicitly).
    """
    return client.request("GET", "/cluster/options")


def log_time(row):
    """A /cluster/log entry's 'time' as local text; the node sends epoch."""
    value = row.get("time")
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(value)))
    except (TypeError, ValueError):
        return str(value if value else "")


def option_text(name, record):
    """The current value of one datacenter option, as a form default.

    A hash option comes back from GET /cluster/options as a dict
    ({'type': 'secure'}); the form shows and re-sends the plain value the
    server accepts. An option that was never set reads as the empty string,
    which the form treats as 'leave this alone'.
    """
    value = (record or {}).get(name)
    if isinstance(value, dict):
        value = value.get("type", "")
    return "" if value is None else str(value).strip()


def option_params(**fields):
    """Turn form values into the parameter set PUT /cluster/options expects.

    Keyword names are the names the server uses (mac_prefix with an underscore,
    next-id with a hyphen).  A hash option such as migration is sent as the
    plain string the server accepts; a dict answer read back from options()
    is reduced to its 'type' so a form can round-trip what it read.
    """
    params = {}
    for name, value in fields.items():
        if value is None or value == "":
            continue
        if name == "delete":
            names = value if isinstance(value, str) else ",".join(value)
            for part in [p.strip() for p in names.split(",") if p.strip()]:
                if not _NAME_RE.fullmatch(part):
                    raise ValueError("Option names may only contain letters, "
                                     "digits, dots, dashes and underscores.")
            params["delete"] = names
            continue
        allowed = ENUM_FIELDS.get(name)
        if allowed:
            if isinstance(value, dict):
                value = value.get("type", value)
            if value not in allowed:
                raise ValueError("{} must be one of: {}.".format(
                    name, ", ".join(allowed)))
            params[name] = value
            continue
        if name in TEXT_FIELDS:
            params[name] = str(value)
            continue
        raise ValueError("Unknown option: {}.".format(name))
    if not params:
        raise ValueError("Nothing to change.")
    return params


def set_options(client, **fields):
    """PUT /cluster/options: change datacenter options.

    Pass the fields by their server names, for example
    set_options(client, description="lab", console="xtermjs"), or
    set_options(client, delete="console") to go back to the default.
    """
    return client.request("PUT", "/cluster/options", option_params(**fields))


def join_command(name, endpoint, words=None):
    """The line a new node runs to join this cluster (bin/supermox-join).

    ``supermox-join join --name <name> --endpoint <host> --words <phrase>``
    is what the CLI accepts; the phrase is the 12-word BIP39 cluster secret,
    and supermox-join itself checks the words and their checksum, so this
    helper only keeps the arguments from being mistaken for a shell command.
    """
    name = str(name or "").strip()
    if not name or not _NAME_RE.fullmatch(name):
        raise ValueError("A node name may only contain letters, digits, dots, "
                         "dashes and underscores.")
    endpoint = str(endpoint or "").strip()
    if not endpoint or not _HOST_RE.fullmatch(endpoint):
        raise ValueError("Give the member as a host, optionally host:port.")
    line = "supermox-join join --name {} --endpoint {}".format(name, endpoint)
    if words:
        words = str(words).split()
        if len(words) != 12:
            raise ValueError("The cluster secret is a 12-word phrase; "
                             "supermox-join also checks the words and their "
                             "checksum.")
        line += " --words " + " ".join(words)
    return line
