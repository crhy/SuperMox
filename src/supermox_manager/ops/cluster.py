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

import json
import re
import time

from . import terminal

# /cluster/log is unbounded; the page asks for the last 50 entries.
MAX_LOG = 50

# The port supermox-join's own daemon answers joins on (src/supermox/joind.py
# DEFAULT_PORT); `create --endpoint` names this node to the rest of the cluster.
JOIN_PORT = 8743

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


# --- the cluster page's actions, run in the node's own shell (c08) ----------
#
# The Manager has no API for SuperMox's own join state: it lives in
# /etc/supermox, which only `supermox-join` reads. So every action here is ONE
# command typed into a node shell (ops/terminal.run_command) and its output
# shown as it came back. The command strings are built here, not in the page,
# so the offline tests can pin them without GTK.

_ID_RE = re.compile(r"[A-Za-z0-9+/=]{8,32}")
_IPV4_RE = re.compile(r"[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")
# 127.x and 169.254.x are the node talking to itself; ::1 and fe80:: are not
# IPv4 at all, so the pattern above already leaves them out.
_LOOPBACK_RE = re.compile(r"^(?:127\.|169\.254\.|0\.0\.0\.0$)")


def _arg(value, pattern, what):
    """One command-line argument, checked against the shape it may have.

    The value goes into a shell line, so a name that is not one of these
    shapes is refused here rather than typed: `supermox-join` would reject it
    anyway, but the shell would have run the rest of the line first.
    """
    value = str(value or "").strip()
    if not pattern.fullmatch(value):
        raise ValueError("Not a valid {}: {}.".format(what, value))
    return value


def members_command():
    """`supermox-join members --json`: this cluster's members, machine-readable."""
    return "supermox-join members --json"


def pending_command():
    """`supermox-join pending --json`: join requests waiting for approval."""
    return "supermox-join pending --json"


def managed_command():
    """A probe for whether this node's nodelist is ours.

    `supermox-join cluster-init` is the repair, but the page only offers it
    when the nodelist is not already managed, and the marker it looks for
    belongs to supermox: the node's own copy of the package is asked, so the
    Manager never has to repeat the marker string.
    """
    return ("python3 -c 'from supermox import corosync_cluster as c; "
            "print(\"yes\" if c.is_managed(c.PVE_COROSYNC_CONF) else "
            "\"no\")'")


def create_command(node, endpoint):
    """`supermox-join create --name <node> --endpoint <host>:<port>`.

    This node becomes the first member of a new cluster. The 12-word phrase
    is generated by the command and printed once, never passed in, so there
    is nothing secret in this line.
    """
    node = _arg(node, _NAME_RE, "node name")
    endpoint = str(endpoint or "").strip()
    if not endpoint or not _HOST_RE.fullmatch(endpoint):
        raise ValueError("Give the member as a host, optionally host:port.")
    if ":" not in endpoint:
        endpoint = "{}:{}".format(endpoint, JOIN_PORT)
    return "supermox-join create --name {} --endpoint {}".format(
        node, endpoint)


def invite_command(ttl=900):
    """`supermox-join invite --ttl <seconds>`: a single-use join invite.

    The invite carries no phrase: it is the QR code and the short-lived id,
    so showing its terminal output in the page is safe.
    """
    ttl = int(ttl)
    if ttl < 1 or ttl > 86400:
        raise ValueError("The invite must live between 1 second and 1 day.")
    return "supermox-join invite --ttl {}".format(ttl)


def decide_command(name, request_id):
    """`supermox-join approve <id>` or `supermox-join deny <id>`.

    The id is base64 out of the state file, so it is quoted: it can hold +,
    / and =, which the shell would otherwise have to make sense of.
    """
    if name not in ("approve", "deny"):
        raise ValueError("A join request is either approved or denied.")
    request_id = _arg(request_id, _ID_RE, "join request id")
    return "supermox-join {} '{}'".format(name, request_id)


def core_command():
    """`supermox-join core`: make the node this shell runs on a core member."""
    return "supermox-join core"


def cluster_init_command():
    """`supermox-join cluster-init`: write this cluster's corosync nodelist."""
    return "supermox-join cluster-init"


def parse_rows(text, keys):
    """The JSON array a --json command printed, or None when it is not one.

    Garbage, a truncated answer and an object where an array was expected
    all come back as None: the page then shows the raw terminal text, which
    is what the user needs to see when a command did not answer as promised.
    """
    try:
        rows = json.loads(text)
    except (TypeError, ValueError):
        return None
    if not isinstance(rows, list):
        return None
    out = []
    for row in rows:
        if not isinstance(row, dict):
            return None
        out.append({key: row.get(key) for key in keys})
    return out


def parse_members(text):
    """Members as [{name, role, overlay_addr, arch, caps, core}]."""
    return parse_rows(text, ("name", "role", "overlay_addr", "arch",
                             "caps", "core"))


def parse_pending(text):
    """Join requests as [{id, name, arch, age_s}]."""
    return parse_rows(text, ("id", "name", "arch", "age_s"))


def run_shell(client, node, command, timeout=terminal.COMMAND_TIMEOUT):
    """Run ONE command in a node shell and return the text it printed.

    The session is opened and closed inside this call, so an action leaves no
    shell behind. The text is the command's own stdout and stderr; the page
    shows it whether or not it parses as JSON, because a command that failed
    is exactly when the user needs to read it.
    """
    return terminal.run_command(client, node, command, timeout=timeout)


def page_actions(members, managed):
    """Which page-level actions this state allows, as a set of names.

    "create" only with no members: a node that already belongs to a cluster
    cannot start a second one, and `supermox-join create` says so. "invite"
    and "upgrade" need the opposite. "upgrade" additionally needs the nodelist
    to be someone else's, which is what managed_command() asked.
    """
    actions = set()
    if not members:
        actions.add("create")
    else:
        actions.add("invite")
        if not managed:
            actions.add("upgrade")
    return actions


def core_allowed(member):
    """True when this member can still be made a corosync core member.

    A member already in the nodelist has no `core` left to do; the button is
    offered for the others, with the two conditions supermox-join itself
    checks (same LAN, no guests on that node) stated next to it.
    """
    return bool(member) and not member.get("core")


def age_text(seconds):
    """A pending request's age as the text the table shows."""
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return ""
    if seconds < 60:
        return "{} s".format(seconds)
    if seconds < 3600:
        return "{} min".format(seconds // 60)
    return "{} h".format(seconds // 3600)


def endpoint_from_interfaces(rows):
    """The first non-loopback IPv4 a node's interfaces name, as a host.

    `create --endpoint` is how this node tells the rest of the cluster where
    to reach it, so the page prefills it from /nodes/{node}/network rather
    than making the user type an address they can look up. A /nnn on the
    value is a network prefix, not part of the address, so it is dropped;
    an IPv6 address is not an IPv4 one and is skipped. Empty means the page
    has to ask.
    """
    for row in rows or ():
        if not isinstance(row, dict):
            continue
        for field in ("address", "cidr"):
            value = str(row.get(field) or "").strip()
            if not value:
                continue
            value = value.split("/", 1)[0].strip()
            if _IPV4_RE.fullmatch(value) and not _LOOPBACK_RE.match(value):
                return value
    return ""
