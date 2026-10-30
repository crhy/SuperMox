"""SuperMox Manager: a GTK 3 + WebKitGTK window on a node's web interface.

The pure parts (which nodes exist, which certificate is pinned, what
settings survive) live in :mod:`supermox_manager.logic` so they can be
tested without a display.  This module is the window itself.

Run it with ``supermox-manager`` (see ``bin/supermox-manager``).
"""

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")

import urllib.parse

from gi.repository import Gtk, WebKit

from supermox_manager import logic

PVE_PORT = 8006

# Base font sizes (px) the header bar offers, and the zoom range, in %.
TEXT_MIN, TEXT_MAX = 10, 32
ZOOM_MIN, ZOOM_MAX = 50, 200


class Manager:
    """GTK window holding one WebKit view of the selected node."""

    def __init__(self, state, my_name, start=None, url=None):
        if url:
            host = urllib.parse.urlsplit(url).hostname or url
            self.nodes = [("(this host)", "https://{}:{}/".format(host, PVE_PORT), True)]
            self.current = "(this host)"
        else:
            self.nodes = logic.node_list(state, my_name)
            if not self.nodes:
                raise SystemExit(
                    "supermox-manager: no nodes; run supermox-join first "
                    "or pass --url")
            self.current = start if start in [n for n, _u, _l in self.nodes] \
                else logic.load_settings()["node"]
            if self.current not in [n for n, _u, _l in self.nodes]:
                self.current = self.nodes[0][0]
        self.state = state
        self.my_name = my_name
        self.allowed = set()        # hosts whose certificate we accepted
        self.buttons = {}
        self.settings = logic.load_settings()
        self.build()
        self.pick(self.current)

    # ------------------------------------------------------------ window

    def build(self):
        self.window = Gtk.Window(title="SuperMox Manager")
        self.window.connect("destroy", self.on_destroy)
        self.window.set_default_size(self.settings["width"], self.settings["height"])
        self.window.set_titlebar(self.header())

        self.view = WebKit.View()
        self.view.connect("load-failed-with-tls-errors", self.on_tls_error)
        self.view.connect("load-failed", self.on_load_failed)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        body.pack_start(self.view, True, True, 0)
        self.status = Gtk.Label(label="")
        self.status.set_ellipsize(1)  # Gtk.EllipsizeMode.END
        self.status.set_line_wrap(False)
        self.status.set_hexpand(True)
        self.status.set_halign(Gtk.Align.START)
        self.status.set_margin_start(6)
        self.status.set_margin_end(6)
        body.pack_start(self.status, False, False, 0)
        self.window.add(body)
        self.apply_settings()

    def header(self):
        """Node picker on the left, controls on the right."""
        bar = Gtk.HeaderBar()

        picker = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        picker.set_spacing(2)
        for name, url, is_local in self.nodes:
            btn = Gtk.ToggleButton(label=name)
            btn.connect("clicked", self.on_pick, name)
            btn.set_tooltip_text("{}{}".format(url, " (this node)" if is_local else ""))
            self.buttons[name] = btn
            picker.pack_start(btn, False, False, 0)
        bar.add(picker)

        reload_btn = Gtk.Button(label="Reload")
        reload_btn.set_tooltip_text("reload this node's page")
        reload_btn.connect("clicked", self.on_reload)
        bar.add(reload_btn)

        self.text_spin = Gtk.SpinButton.new_with_range(TEXT_MIN, TEXT_MAX, 1)
        self.text_spin.set_value(self.settings["text_size"])
        self.text_spin.set_tooltip_text("base font size (px)")
        self.text_spin.connect("change-value", self.on_settings)
        bar.add(self.text_spin)

        self.zoom_spin = Gtk.SpinButton.new_with_range(ZOOM_MIN, ZOOM_MAX, 5)
        self.zoom_spin.set_value(self.settings["zoom"] * 100)
        self.zoom_spin.set_tooltip_text("zoom (%)")
        self.zoom_spin.connect("change-value", self.on_settings)
        bar.add(self.zoom_spin)

        quit_btn = Gtk.Button(label="Quit")
        quit_btn.set_tooltip_text("save the window size and quit")
        quit_btn.connect("clicked", self.on_quit)
        bar.add(quit_btn)
        return bar

    # ------------------------------------------------------------ nodes

    def on_pick(self, _btn, name):
        self.pick(name)

    def pick(self, name):
        for other, btn in self.buttons.items():
            btn.set_active(other == name)
        self.current = name
        self.window.set_title("SuperMox Manager - {}".format(name))
        self.load()

    def url(self):
        for name, url, _local in self.nodes:
            if name == self.current:
                return url
        return self.nodes[0][1]

    def host(self):
        return urllib.parse.urlsplit(self.url()).hostname

    def is_local(self):
        for name, _url, is_local in self.nodes:
            if name == self.current:
                return is_local
        return False

    def load(self):
        self.status.set_text("connecting to {}...".format(self.url()))
        self.view.load_uri(self.url())

    # ------------------------------------------------------------ pinning

    def expected_pin(self):
        """Fingerprint of the certificate this node must present."""
        if self.is_local():
            return logic.pin_local()
        return logic.pin_for(self.current, self.state, self.my_name)

    def on_tls_error(self, _view, _frame, _error, cert):
        """WebKit refused the certificate; decide before it is trusted."""
        presented = logic.fingerprint_der(cert.export_der())
        pin = self.expected_pin()
        allowed, reason = logic.decide(presented, pin)
        if not allowed:
            self.status.set_text("refused: {}".format(reason))
            self.refuse(presented, pin, self.url())
            return True
        host = self.host()
        if not self.pin_certificate(cert, host):
            self.status.set_text("refused: could not pin the certificate")
            self.refuse(presented, pin, self.url())
            return True
        self.allowed.add(host)
        self.status.set_text("pinned {} ({})".format(host, presented[:12]))
        self.view.reload()
        return True

    def pin_certificate(self, cert, host):
        """Tell WebKit that exactly this certificate is trusted on *host*."""
        context = self.view.get_context()
        for args in ((cert, host), (host, cert)):
            try:
                context.allow_tls_certificate_for_host(*args)
                return True
            except Exception:
                continue
        return False

    def on_load_failed(self, _view, _frame, error, _uri):
        if self.host() in self.allowed:
            return False
        self.status.set_text("cannot connect: {}".format(error))
        self.refuse(None, self.expected_pin(), self.url(),
                    "the node is not answering over TLS on port {}".format(PVE_PORT))
        return True

    def refuse(self, presented, pin, target,
               why="the certificate is not the one we pinned"):
        """Show a plain page instead of the node's content."""
        html = (
            "<!doctype html><meta charset=utf-8>"
            "<title>SuperMox Manager</title>"
            "<style>body{{font-family:sans-serif;margin:2em;color:#222}}"
            "code{{font-family:monospace}}</style>"
            "<h1>SuperMox Manager</h1>"
            "<p><b>{}</b> is not shown: {}.</p>"
            "<p>Pinned fingerprint: <code>{}</code></p>"
            "<p>Presented fingerprint: <code>{}</code></p>"
            "<p>Nothing from that host was rendered.</p>"
        ).format(target, why, pin or "(none)", presented or "(none)")
        self.view.load_html(html, "about:supermox")

    # ------------------------------------------------------------ settings

    def on_reload(self, _btn):
        self.view.reload()

    def on_settings(self, _spin, _direction, _delta):
        self.apply_settings()

    def apply_settings(self):
        settings = self.view.get_settings()
        base = int(self.text_spin.get_value())
        settings.set_default_font_size(base)
        settings.set_minimum_font_size(max(1, base - 4))
        self.view.set_settings(settings)
        self.view.set_zoom_level(self.zoom_spin.get_value() / 100.0)

    def on_quit(self, _btn):
        self.window.close()

    def on_destroy(self, _win):
        """Save what we keep, then stop the main loop."""
        self.save_size()
        Gtk.main_quit()
        return False

    def save_size(self):
        try:
            width, height = self.window.get_size()
        except Exception:
            return
        settings = logic.load_settings()
        settings["width"] = width
        settings["height"] = height
        settings["node"] = self.current
        settings["text_size"] = int(self.text_spin.get_value())
        settings["zoom"] = self.zoom_spin.get_value() / 100.0
        logic.save_settings(settings)


def run(argv=None):
    """Open the manager window."""
    import argparse

    parser = argparse.ArgumentParser(
        prog="supermox-manager",
        description="show a SuperMox node's web interface in one window")
    parser.add_argument("--node", default=None, help="node to open")
    parser.add_argument("--url", default=None,
                        help="open this host instead of a node from the state file")
    args = parser.parse_args(argv)

    from supermox import state as pve_state

    state = pve_state.NodeState.load()
    manager = Manager(state, state.my_name(), start=args.node, url=args.url)
    manager.window.show()
    Gtk.main()
    return 0
