"""Offline Manager robustness check: xvfb-run -a python3 tests/manager-offline.py

Runs the real Manager GUI against a local HTTPS node we control, plus an
address where nothing listens, and asserts the documented behaviour: a dead
node fails fast with a clear status line, HTTP 500 and 401 are reported as
errors (401 also clears the session), a node that vanishes mid-session keeps
the previous rows, Full management refuses to open without a pin, and no
network call ever happens on the GTK main thread.

No VM, no live server, nothing outside build/.
"""
import os
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
build = ROOT / "build"
build.mkdir(exist_ok=True)
preferences = tempfile.TemporaryDirectory(prefix="manager-offline-", dir=build)
os.environ["XDG_CONFIG_HOME"] = preferences.name
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests" / "py"))

import http.server
import json
import ssl

from test_manager_pin import _self_signed_cn  # noqa: E402

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402

from supermox_manager import api, logic  # noqa: E402
from supermox_manager import app as appmod  # noqa: E402

RESULTS = []
NETWORK_THREADS = set()


def ok(name, condition, detail=""):
    RESULTS.append((name, bool(condition)))
    print("%-58s %s" % (name, "PASS" if condition else "FAIL " + detail), flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    """Answers like pveproxy: JSON body, status chosen by the test."""

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        path = self.path.split("?")[0]
        forced = getattr(self.server, "force", None)
        if forced:
            status, result = forced
        elif path.endswith("/access/ticket"):
            status, result = 200, self.server.ticket
        elif path.endswith("/resources"):
            status, result = 200, self.server.resources
        else:
            status, result = self.server.reply
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())

    def log_message(self, *_args):
        pass


def main():
    pem, key, der = _self_signed_cn("offline-node")
    cert = build / "manager-offline-cert.pem"
    private = build / "manager-offline-key.pem"
    cert.write_bytes(pem)
    private.write_bytes(key)
    pin = logic.fingerprint_der(der)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert), str(private))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.reply = (200, {"data": []})
    server.force = None
    server.ticket = {"data": {"ticket": "PVE:offline", "CSRFPreventionToken": "csrf",
                              "username": "root@pam"}}
    server.resources = {"data": [{"node": "atlas", "id": "vm/100", "vmid": 100,
                                  "name": "one", "type": "qemu", "status": "running",
                                  "template": 0, "memory": 1024, "maxmemory": 2048}]}
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "https://127.0.0.1:%d/" % server.server_address[1]

    original_connect = api.Client._connect

    def connect(self):
        NETWORK_THREADS.add(threading.current_thread().name)
        return original_connect(self)

    api.Client._connect = connect

    def quiet(manager, address, password):
        manager.message = lambda *args: None
        manager.form = lambda *args: {"url": address, "username": "root@pam",
                                      "password": password, "otp": "", "pin": pin}
        return manager

    node = quiet(appmod.Manager(url, pin, demo=False), url, "secret")
    dead = quiet(appmod.Manager("https://127.0.0.1:1/", pin, demo=False),
                 "https://127.0.0.1:1/", "x")

    state = {"index": 0, "dead_at": 0.0, "deadline": time.monotonic() + 90}

    def step_dead_start():
        state["dead_at"] = time.monotonic()
        dead.connect_dialog()

    def step_dead_check():
        text = dead.status.get_text()
        ok("dead address: status reports the failure", "Cannot reach the node" in text,
           repr(text))
        ok("dead address: fails fast", time.monotonic() - state["dead_at"] < 5,
           "%.1fs" % (time.monotonic() - state["dead_at"]))
        ok("dead address: no session is kept", dead.client is None)
        ok("dead address: not stuck busy", not dead.busy)

    def step_login():
        node.connect_dialog()

    def step_login_check():
        ok("live node: login succeeded", node.client is not None)

    def step_resources():
        node.navigate(None, "Machines")
        node.refresh()

    def step_resources_check():
        ok("live node: resources rendered", len(node.resources) == 1,
           str(node.resources)[:60])

    def step_500():
        server.force = (500, {"status": "error", "message": "boom"})
        node.refresh()

    def step_500_check():
        text = node.status.get_text()
        ok("HTTP 500: reported as an error", "500" in text, repr(text))
        ok("HTTP 500: page still usable", node.nav is not None and not node.busy)

    def step_401():
        server.force = (401, {"status": "error", "message": "permission denied"})
        node.refresh()

    def step_401_check():
        text = node.status.get_text()
        ok("HTTP 401: reported as a session problem", "Sign in again" in text, repr(text))
        ok("HTTP 401: session cleared",
           node.client is not None and node.client.ticket is None)

    def step_vanished():
        server.shutdown()
        server.server_close()
        node.refresh()

    def step_vanished_check():
        text = node.status.get_text()
        ok("node vanished: reported as an error", "Cannot reach the node" in text, repr(text))
        ok("node vanished: not stuck busy", not node.busy)
        ok("node vanished: previous rows stay until a new answer arrives",
           len(node.resources) == 1, str(node.resources)[:60])

    def step_full():
        node.pin = None
        node.open_full()

    def step_full_check():
        ok("Full management without a pin: no WebKit window", not node.full_windows)
        ok("network never runs on the GTK main thread", "MainThread" not in NETWORK_THREADS,
           str(NETWORK_THREADS))
        ok("network work is threaded", bool(NETWORK_THREADS), "no network observed")
        node.window.close()

    steps = [step_dead_start, step_dead_check, step_login, step_login_check,
             step_resources, step_resources_check, step_500, step_500_check,
             step_401, step_401_check, step_vanished, step_vanished_check,
             step_full, step_full_check]

    def tick():
        if node.closed or dead.closed:
            return False
        if time.monotonic() > state["deadline"]:
            print("timed out after %d checks" % len(RESULTS))
            return False
        if state["index"] >= len(steps):
            return False
        if not node.busy and not dead.busy:
            steps[state["index"]]()
            state["index"] += 1
        return True

    GLib.timeout_add(20, tick)
    Gtk.main()
    failed = [name for name, passed in RESULTS if not passed]
    print("%d checks, %d failed" % (len(RESULTS), len(failed)))
    if failed:
        print("failed: " + "; ".join(failed))
    if len(RESULTS) < len(steps) // 2:
        print("too few checks ran: %d of %d" % (len(RESULTS), len(steps)))
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
