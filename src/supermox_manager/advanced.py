"""Ephemeral compatibility window for the server's existing interface.

Native API traffic has strict per-connection pinning. WebKit uses its own TLS
stack, with a pinned preflight and a narrowly scoped self-signed certificate
exception. It must never use the IGNORE TLS policy.
"""

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
    body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    warning = Gtk.Label(label="Full server interface · separate sign-in · session discarded when closed")
    body.pack_start(warning, False, False, 8)
    body.pack_start(view, True, True, 0)
    window.add(body)
    origin = api.endpoint(url)
    children = []

    def policy(_view, decision, kind):
        if kind in (WebKit2.PolicyDecisionType.NAVIGATION_ACTION, WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION):
            target = decision.get_navigation_action().get_request().get_uri()
            try:
                parsed = urlsplit(target)
                allowed = (target == "about:blank" or
                           (parsed.scheme == "https" and parsed.hostname == origin[1]
                            and (parsed.port or 443) == origin[2]))
            except ValueError:
                allowed = False
            if not allowed:
                decision.ignore()
                warning.set_text("External navigation blocked. External SSO providers are not supported in this view.")
                return True
        return False

    def tls_failed(active_view, _uri, certificate, _errors):
        actual = logic.fingerprint_pem(certificate.props.certificate_pem)
        if actual != api.fingerprint(pin):
            warning.set_text("Connection refused: certificate changed. Reconnect and verify the fingerprint.")
            active_view.stop_loading()
            return True
        context.allow_tls_certificate_for_host(certificate, origin[1])
        active_view.reload()
        return True

    def permission(_view, request):
        request.deny()
        return True

    def popup(source, _navigation):
        child = Gtk.Window(title="SuperMox Manager · Console", transient_for=window)
        child.set_default_size(1100, 720)
        child.set_icon_name("supermox-manager")
        related = WebKit2.WebView.new_with_related_view(source)
        configure(related)
        child.add(related)
        related.connect("ready-to-show", lambda *_: child.show_all())
        related.connect("close", lambda *_: child.destroy())
        child.connect("destroy", lambda *_: related.stop_loading())
        children.append(child)
        return related

    def configure(active_view):
        active_view.get_settings().set_enable_developer_extras(False)
        active_view.connect("decide-policy", policy)
        active_view.connect("create", popup)
        active_view.connect("load-failed-with-tls-errors", tls_failed)
        active_view.connect("permission-request", permission)

    def download_started(_context, download):
        def destination(item, suggested):
            dialog = Gtk.FileChooserDialog(title="Save download", transient_for=window,
                                           action=Gtk.FileChooserAction.SAVE)
            dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Save", Gtk.ResponseType.OK)
            dialog.set_do_overwrite_confirmation(True)
            # A server-supplied filename never chooses the destination directory.
            dialog.set_current_name(suggested.replace("\\", "/").rsplit("/", 1)[-1] or "download")
            accepted = dialog.run() == Gtk.ResponseType.OK
            chosen = dialog.get_uri() if accepted else None
            dialog.destroy()
            if chosen:
                item.set_allow_overwrite(True)
                item.set_destination(chosen)
            else:
                item.cancel()
            return True
        download.connect("decide-destination", destination)

    def closed(*_args):
        for child in children:
            child.destroy()
        view.stop_loading()
        context.get_cookie_manager().delete_all_cookies()

    configure(view)
    context.connect("download-started", download_started)
    window.connect("destroy", closed)
    view.load_uri(url)
    window.show_all()
    return window
