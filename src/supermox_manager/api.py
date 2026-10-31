"""PVE-compatible API transport. Credentials stay in memory, TLS is pinned.

This is an independent AGPL-3.0 client, not a copy of the upstream UI.
Every request verifies the leaf on the actual connection before sending data.
"""

import hashlib
import http.client
import json
import random
import re
import socket
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


def volume(value):
    """Encode a volume id for the URL path, keeping ':' and '/' intact.

    The node parses the volume as a raw path (a percent-encoded ':' is rejected),
    so only genuinely unsafe characters such as spaces are escaped.
    """
    return quote(str(value), safe=":/")


def _form(params):
    """Serialise API parameters for a form body or query string.

    PVE list options travel as comma-separated values, so a list or tuple
    value is joined with ',' (urlencode would otherwise stringify the
    Python list and send a nonsense value). Everything else is passed
    through unchanged.
    """
    out = {}
    for key, value in params.items():
        if isinstance(value, (list, tuple)):
            out[key] = ",".join(str(item) for item in value)
        else:
            out[key] = value
    return out


def guest_path(guest):
    if guest.get("type") not in ("qemu", "lxc"):
        raise ValueError("Select a virtual machine or container.")
    return "/nodes/{}/{}/{}".format(
        segment(guest["node"]), guest["type"], int(guest["vmid"]))


def pinned_socket(host, port, pin, timeout=15):
    """Return a connected TLS socket whose leaf certificate matches ``pin``.

    The handshake happens before any application data is written; the leaf
    certificate (DER bytes) is hashed on the actual connection and compared
    with the SHA256 fingerprint before the socket is handed back. No redirects
    and no proxy environment variables: credentials never leave this origin.
    api.Client and the terminal websocket share this one check.
    """
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    plain = socket.create_connection((host, port), timeout=timeout)
    try:
        sock = context.wrap_socket(plain, server_hostname=host)
        cert = sock.getpeercert(binary_form=True)
        if not cert or hashlib.sha256(cert).hexdigest() != fingerprint(pin):
            raise APIError("Certificate mismatch. No credentials were sent. "
                           "Verify the node fingerprint.")
    except Exception:
        plain.close()
        raise
    return sock


class Client:
    def __init__(self, url, pin, timeout=15):
        self.url, self.host, self.port = endpoint(url)
        self.pin = fingerprint(pin)
        self.timeout = timeout
        self.ticket = None
        self.csrf = None
        self.username = None
        self.token = None

    def logout(self):
        self.ticket = self.csrf = self.username = self.token = None

    def use_token(self, tokenid, secret):
        """Authenticate as an API token instead of a login session.

        ``tokenid`` is the full token id (``userid!name``) and ``secret`` the
        UUID returned once at creation. The token travels in the Authorization
        header; it is held in memory only and cleared by logout().
        """
        if not tokenid or not secret:
            raise ValueError("Give the full token id and its secret.")
        self.ticket = self.csrf = self.username = None
        self.token = (tokenid, secret)

    def _connect(self):
        """Open a connection and verify the pinned certificate before sending.

        No redirects or proxy environment variables: credentials never leave
        this origin. The TLS handshake and the leaf-certificate check live in
        pinned_socket(), so the terminal websocket verifies exactly the same
        way; http.client is handed the already-verified socket and never opens
        its own connection.
        """
        connection = http.client.HTTPConnection(self.host, self.port,
                                                timeout=self.timeout)
        connection.sock = pinned_socket(self.host, self.port, self.pin,
                                        self.timeout)
        return connection

    def _read_response(self, connection, method, target):
        """Read one HTTP response and return the API 'data' value."""
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

    def request(self, method, path, params=None):
        if method not in ("GET", "POST", "PUT", "DELETE") or not path.startswith("/"):
            raise ValueError("Invalid API request")
        target = "/api2/json" + path
        body = None
        headers = {"Accept": "application/json"}
        if self.token:
            # PVE splits the token value on '=', not ':'.
            headers["Authorization"] = "PVEAPIToken={}={}".format(self.token[0], self.token[1])
        if method in ("GET", "DELETE") and params:
            target += "?" + urlencode(_form(params))
        elif params is not None:
            body = urlencode(_form(params)).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if self.ticket:
            headers["Cookie"] = "PVEAuthCookie=" + quote(self.ticket, safe="")
            if method != "GET":
                headers["CSRFPreventionToken"] = self.csrf
        try:
            connection = self._connect()
            try:
                connection.request(method, target, body=body, headers=headers)
                return self._read_response(connection, method, target)
            finally:
                connection.close()
        except (OSError, http.client.HTTPException) as exc:
            raise APIError("Cannot reach the node over HTTPS: {}".format(type(exc).__name__)) from None

    UPLOAD_CHUNK = 1024 * 1024

    def upload(self, path, fields, filename, fileobj, size):
        """POST a file as multipart/form-data to ``path``.

        ``fields`` are sent as ordinary form fields; the file travels as the
        ``filename`` part (the name the node's upload handler requires) with
        the given ``filename``. ``fileobj`` is read
        and streamed in 1 MiB chunks so large files never sit in memory whole.
        ``size`` must be the exact byte length of the file (used for
        Content-Length). Returns the API 'data' value (a task UPID).
        """
        if not path.startswith("/"):
            raise ValueError("Invalid API request")
        boundary = "----SuperMoxUpload%016x" % random.getrandbits(64)
        prefix = self._multipart_prefix(boundary, fields, filename)
        suffix = ("\r\n--%s--\r\n" % boundary).encode("utf-8")
        headers = {
            "Accept": "application/json",
            "Content-Type": "multipart/form-data; boundary=%s" % boundary,
            "Content-Length": str(len(prefix) + size + len(suffix)),
        }
        if self.ticket:
            headers["Cookie"] = "PVEAuthCookie=" + quote(self.ticket, safe="")
            headers["CSRFPreventionToken"] = self.csrf
        target = "/api2/json" + path
        try:
            connection = self._connect()
            try:
                connection.putrequest("POST", target)
                for name, value in headers.items():
                    connection.putheader(name, value)
                connection.endheaders()
                connection.send(prefix)
                remaining = size
                while remaining > 0:
                    chunk = fileobj.read(min(self.UPLOAD_CHUNK, remaining))
                    if not chunk:
                        break
                    connection.send(chunk)
                    remaining -= len(chunk)
                connection.send(suffix)
                return self._read_response(connection, "POST", target)
            finally:
                connection.close()
        except (OSError, http.client.HTTPException) as exc:
            raise APIError("Cannot reach the node over HTTPS: {}".format(type(exc).__name__)) from None

    @staticmethod
    def _multipart_prefix(boundary, fields, filename):
        quoted = str(filename).replace("\\", "\\\\").replace('"', '\\"')
        parts = []
        for name, value in fields.items():
            parts.append("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n"
                         "\r\n%s\r\n" % (boundary, name, value))
        parts.append("--%s\r\nContent-Disposition: form-data; name=\"filename\"; "
                     'filename="%s"\r\n'
                     "Content-Type: application/octet-stream\r\n\r\n"
                     % (boundary, quoted))
        return "".join(parts).encode("utf-8")

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
        if path == "/cluster/nextid":
            return 103
        if path.endswith("/storage"):
            return [{"storage": "local"}]
        if path.endswith("/network"):
            return [{"iface": "eth0", "type": "eth", "active": 1, "autostart": 1,
                     "address": "192.168.1.1"},
                    {"iface": "vmbr0", "type": "bridge", "active": 1, "autostart": 1,
                     "address": "10.0.0.1"}]
        if path.endswith("/disks/list"):
            return [{"devpath": "/dev/sda", "type": "hdd", "health": "OK",
                     "model": "Sample disk", "size": 512 * gib, "used": 120 * gib,
                     "mounted": 0}]
        if path.endswith("/disks/smart"):
            return {"health": "OK"}
        if path.endswith("/disks/directory"):
            return [{"devpath": "/dev/sda1", "mountpoint": "/var/lib/pve-cluster",
                     "fstype": "ext4", "size": 100 * gib, "used_on_mnt": 30 * gib,
                     "used_percent": 30}]
        if path.endswith("/content"):
            return [{"volid": "local:iso/ubuntu-24.04.iso"}]
        if path.endswith("/firewall/rules"):
            return [{"action": "ACCEPT", "type": "in", "source": "10.0.0.1",
                     "comment": "Sample incoming rule"}]
        if path.endswith("/firewall/options"):
            return {"enable": 0, "policy_in": "ACCEPT", "policy_out": "ACCEPT",
                    "policy_forward": "ACCEPT"}
        if path.endswith("/firewall/aliases"):
            return [{"name": "lab", "cidr": "10.0.0.1", "comment": "Sample alias"}]
        if path.endswith("/firewall/ipset"):
            return [{"name": "blocklist", "comment": "Sample IP set"}]
        if path.endswith("/config"):
            return {"cores": 4, "memory": 8192, "description": "Sample guest; no host is connected."}
        if path.endswith("/log"):
            return [{"n": 1, "t": "Preview task completed."}]
        if path.endswith("/status"):
            return {"status": "stopped", "exitstatus": "OK"}
        return []
