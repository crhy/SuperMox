"""Ephemeral compatibility window for the server's complete interface."""

from urllib.parse import urlsplit

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gio, Gtk, WebKit2

from . import api, logic


def open_window(parent, url, pin, pem):
    window = Gtk.Window(title="SuperMox Manager · Full management", transient_for=parent)
    window.set_default_size(1200, 800)
    window.set_icon_name("supermox-manager")
    context = WebKit2.WebContext.new_ephemeral()
    context.set_tls_errors_policy(WebKit2.TLSErrorsPolicy.FAIL)
    context.allow_tls_certificate_for_host(Gio.TlsCertificate.new_from_pem(pem, -1), urlsplit(url).hostname)
    view = WebKit2.WebView.new_with_context(context)
    view.get_settings().set_enable_developer_extras(False)
    body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    warning = Gtk.Label(label="Full server interface · separate sign-in · session discarded when closed")
    body.pack_start(warning, False, False, 8)
    body.pack_start(view, True, True, 0)
    window.add(body)
    origin = api.endpoint(url)

    def policy(_view, decision, kind):
        if kind in (WebKit2.PolicyDecisionType.NAVIGATION_ACTION, WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION):
            target = decision.get_navigation_action().get_request().get_uri()
            try:
                parsed = urlsplit(target)
                allowed = parsed.scheme == "https" and parsed.hostname == origin[1] and (parsed.port or 443) == origin[2]
            except ValueError:
                allowed = False
            if not allowed or kind == WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION:
                decision.ignore()
                warning.set_text("External navigation blocked. Use the native desktop for other connections.")
                return True
        return False

    def tls_failed(_view, _uri, certificate, _errors):
        actual = logic.fingerprint_pem(certificate.props.certificate_pem)
        if actual != api.fingerprint(pin):
            warning.set_text("Connection refused: certificate changed. Reconnect and verify the fingerprint.")
            view.stop_loading()
            return True
        context.allow_tls_certificate_for_host(certificate, origin[1])
        view.reload()
        return True

    def permission(_view, request):
        request.deny()
        return True

    view.connect("decide-policy", policy)
    view.connect("load-failed-with-tls-errors", tls_failed)
    view.connect("permission-request", permission)
    # No browser profile, persisted cookies, automatic downloads, or credential sharing.
    context.connect("download-started", lambda _context, download: download.cancel())
    window.connect("destroy", lambda *_: view.stop_loading())
    view.load_uri(url)
    window.show_all()
    return window
