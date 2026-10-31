"""Node administration operations (no GTK).

Paths and parameter names follow the running node's own API (pvesh usage);
never guessed. Every call goes through client.request, which pins TLS.
"""

from .. import api


def summary(client, node):
    """GET /nodes/{node}/status + /nodes/{node}/version merged into one dict.

    Returns keys: cpu, loadavg, memory, swap, rootfs, uptime, kernel, pveversion.
    """
    status = client.request("GET", "/nodes/{}/status".format(api.segment(node)))
    version = client.request("GET", "/nodes/{}/version".format(api.segment(node)))
    result = {
        "cpu": status.get("cpu", 0),
        "cpuinfo": status.get("cpuinfo", {}),
        "loadavg": status.get("loadavg", []),
        "memory": status.get("memory", {}),
        "swap": status.get("swap", {}),
        "rootfs": status.get("rootfs", {}),
        "uptime": status.get("uptime", 0),
        "kernel": status.get("kversion", ""),
        "pveversion": version.get("version", ""),
        "release": version.get("release", ""),
    }
    return result


def services(client, node):
    """GET /nodes/{node}/services: list of service dicts."""
    return client.request("GET", "/nodes/{}/services".format(api.segment(node)))


def service_action(client, node, service, action):
    """POST /nodes/{node}/services/{service}/{action}: returns a UPID.

    action is one of: start, stop, restart, reload.
    """
    if action not in ("start", "stop", "restart", "reload"):
        raise ValueError("Unknown service action: {}".format(action))
    return client.request(
        "POST",
        "/nodes/{}/{}/{}".format(api.segment(node), api.segment(service), action))


def syslog(client, node, start=0, limit=500, service=None, since=None, until=None):
    """GET /nodes/{node}/syslog: list of log line dicts (n, t).

    Parameters: start (offset), limit (max lines), service (filter),
    since/until (datetime strings like '2026-01-01 00:00:00').
    """
    params = {"start": start, "limit": limit}
    if service:
        params["service"] = service
    if since:
        params["since"] = since
    if until:
        params["until"] = until
    return client.request("GET", "/nodes/{}/syslog".format(api.segment(node)), params)


def updates(client, node):
    """GET /nodes/{node}/apt/update: list of available package updates."""
    return client.request("GET", "/nodes/{}/apt/update".format(api.segment(node)))


def refresh_updates(client, node):
    """POST /nodes/{node}/apt/update: resynchronise package index; returns a UPID."""
    return client.request("POST", "/nodes/{}/apt/update".format(api.segment(node)),
                          {"quiet": 1})


def dns(client, node):
    """GET /nodes/{node}/dns: current DNS settings dict."""
    return client.request("GET", "/nodes/{}/dns".format(api.segment(node)))


def set_dns(client, node, search=None, dns1=None, dns2=None, dns3=None):
    """PUT /nodes/{node}/dns: write DNS settings.

    At least one of search, dns1, dns2, dns3 must be provided.
    """
    params = {}
    if search is not None:
        params["search"] = search
    if dns1 is not None:
        params["dns1"] = dns1
    if dns2 is not None:
        params["dns2"] = dns2
    if dns3 is not None:
        params["dns3"] = dns3
    if not params:
        raise ValueError("At least one DNS field must be provided.")
    return client.request("PUT", "/nodes/{}/dns".format(api.segment(node)), params)


def time_info(client, node):
    """GET /nodes/{node}/time: current time and timezone dict."""
    return client.request("GET", "/nodes/{}/time".format(api.segment(node)))


def set_timezone(client, node, timezone):
    """PUT /nodes/{node}/time: set the timezone.

    timezone is a name from /usr/share/zoneinfo/zone.tab (e.g. 'Etc/UTC').
    """
    if not timezone:
        raise ValueError("Timezone must not be empty.")
    return client.request("PUT", "/nodes/{}/time".format(api.segment(node)),
                          {"timezone": timezone})


def hosts(client, node):
    """GET /nodes/{node}/hosts: /etc/hosts content and digest."""
    return client.request("GET", "/nodes/{}/hosts".format(api.segment(node)))
