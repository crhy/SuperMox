"""PVE-compatible API transport. Credentials stay in memory, TLS is pinned.

This is an independent AGPL-3.0 client, not a copy of the upstream UI.
Every request verifies the leaf on the actual connection before sending data.
"""

import hashlib
import http.client
import json
import re
import ssl
from urllib.parse import quote, urlencode, urlsplit


class APIError(Exception):
    """A safe, user-facing connection or API failure."""


def fingerprint(value):
    value = (value or "").replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("Supply the node certificate's SHA256 fingerprint (64 hex digits).")
    return value


def endpoint(value):
    """Only an HTTPS origin is accepted; no credentials, fragments or paths."""
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment):
        raise ValueError("Use an HTTPS address such as https://node.example:8006/")
    port = parsed.port or 8006
    host = parsed.hostname
    origin = "https://{}:{}/".format("[{}]".format(host) if ":" in host else host, port)
    return origin, host, port


def segment(value):
    return quote(str(value), safe="")


def guest_path(guest):
    if guest.get("type") not in ("qemu", "lxc"):
        raise ValueError("Select a virtual machine or container.")
    return "/nodes/{}/{}/{}".format(
        segment(guest["node"]), guest["type"], int(guest["vmid"]))


class Client:
    def __init__(self, url, pin, timeout=15):
        self.url, self.host, self.port = endpoint(url)
        self.pin = fingerprint(pin)
        self.timeout = timeout
        self.ticket = None
        self.csrf = None
        self.username = None

    def logout(self):
        self.ticket = self.csrf = self.username = None

    def request(self, method, path, params=None):
        if method not in ("GET", "POST", "PUT", "DELETE") or not path.startswith("/"):
            raise ValueError("Invalid API request")
        # No redirects or proxy environment variables: credentials never leave this origin.
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        connection = http.client.HTTPSConnection(
            self.host, self.port, timeout=self.timeout, context=context)
        try:
            connection.connect()
            cert = connection.sock.getpeercert(binary_form=True)
            if not cert or hashlib.sha256(cert).hexdigest() != self.pin:
                raise APIError("Certificate mismatch. No credentials were sent. Verify the node fingerprint.")
            body = None
            target = "/api2/json" + path
            headers = {"Accept": "application/json"}
            if method == "GET" and params:
                target += "?" + urlencode(params)
            elif params is not None:
                body = urlencode(params).encode("utf-8")
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            if self.ticket:
                headers["Cookie"] = "PVEAuthCookie=" + quote(self.ticket, safe="")
                if method != "GET":
                    headers["CSRFPreventionToken"] = self.csrf
            connection.request(method, target, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read(16 * 1024 * 1024 + 1)
            if len(payload) > 16 * 1024 * 1024:
                raise APIError("The node returned too much data.")
            if response.status == 401:
                self.logout()
                raise APIError("Sign in again: the session expired or the credentials were rejected.")
            if response.status == 403:
                raise APIError("Your account does not have permission for this operation.")
            try:
                decoded = json.loads(payload)
            except (ValueError, UnicodeError):
                raise APIError("The node returned an invalid API response.") from None
            if not 200 <= response.status < 300:
                # Do not echo server text: it can contain request parameters or secrets.
                fields = decoded.get("errors", {}) if isinstance(decoded, dict) else {}
                names = ", ".join(str(k) for k in fields) if isinstance(fields, dict) else ""
                raise APIError("Operation failed (HTTP {}).{}".format(
                    response.status, " Check fields: " + names if names else ""))
            if not isinstance(decoded, dict) or "data" not in decoded:
                raise APIError("The node returned an invalid API response.")
            return decoded["data"]
        except (OSError, http.client.HTTPException) as exc:
            raise APIError("Cannot reach the node over HTTPS: {}".format(type(exc).__name__)) from None
        finally:
            connection.close()

    def login(self, username, password, otp=""):
        self.logout()
        params = {"username": username, "password": password}
        if otp:
            params["otp"] = otp
        data = self.request("POST", "/access/ticket", params)
        if not isinstance(data, dict):
            raise APIError("The node returned an invalid login response.")
        ticket = data.get("ticket", "")
        if (not isinstance(ticket, str) or not ticket or data.get("NeedTFA")
                or "!tfa!" in ticket or ":tfa!" in ticket or not data.get("CSRFPreventionToken")):
            raise APIError("This login needs an interactive second factor. Use Full management to sign in.")
        self.ticket, self.csrf = ticket, data["CSRFPreventionToken"]
        self.username = data.get("username", username)
        return self.username

    def resources(self):
        return self.request("GET", "/cluster/resources")

    def tasks(self):
        return self.request("GET", "/cluster/tasks")

    def action(self, guest, action, params=None):
        if action not in ("start", "shutdown", "reboot", "stop", "suspend", "resume"):
            raise ValueError("Unsupported power action")
        return self.request("POST", guest_path(guest) + "/status/" + action, params or {})


def human_bytes(value):
    value = float(value or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(value) < 1024 or unit == "TiB":
            return "{:.1f} {}".format(value, unit)
        value /= 1024


class DemoClient:
    """Explicitly synthetic preview. Never connects to or changes a real host."""
    url = "Preview data — no live connection"
    username = "Preview"
    ticket = None

    def __init__(self):
        gib = 1024 ** 3
        self.rows = [
            {"type": "node", "node": "atlas", "status": "online", "cpu": .23,
             "mem": 21 * gib, "maxmem": 64 * gib, "maxcpu": 16},
            {"type": "node", "node": "orbit", "status": "online", "cpu": .09,
             "mem": 5 * gib, "maxmem": 16 * gib, "maxcpu": 8},
            {"type": "qemu", "vmid": 100, "name": "Spaced Linux Desktop", "node": "atlas",
             "status": "running", "cpu": .12, "mem": 6 * gib, "maxmem": 8 * gib},
            {"type": "lxc", "vmid": 101, "name": "Personal cloud", "node": "atlas",
             "status": "running", "cpu": .03, "mem": gib, "maxmem": 2 * gib},
            {"type": "qemu", "vmid": 102, "name": "Build workshop", "node": "orbit",
             "status": "stopped", "cpu": 0, "mem": 0, "maxmem": 4 * gib},
            {"type": "storage", "storage": "local", "node": "atlas", "status": "available",
             "disk": 180 * gib, "maxdisk": 512 * gib, "content": "iso,vztmpl,backup"},
        ]

    def logout(self):
        pass

    def resources(self):
        return [dict(row) for row in self.rows]

    def tasks(self):
        return [{"node": "atlas", "type": "vzdump", "id": "100", "status": "OK",
                 "user": "root@pam", "upid": "preview"}]

    def action(self, guest, action, params=None):
        for row in self.rows:
            if row.get("vmid") == guest["vmid"]:
                row["status"] = "running" if action in ("start", "resume", "reboot") else "stopped"
        return "Preview only: {} simulated".format(action)

    def request(self, method, path, params=None):
        if method != "GET":
            return "Preview only: operation simulated"
        if path.endswith("/config"):
            return {"cores": 4, "memory": 8192, "description": "Sample guest; no host is connected."}
        if path.endswith("/log"):
            return [{"n": 1, "t": "Preview task completed."}]
        if path.endswith("/status"):
            return {"status": "stopped", "exitstatus": "OK"}
        return []
