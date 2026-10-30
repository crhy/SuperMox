"""Tests for supermox_manager.logic: certificate pinning and node selection.

Nothing here imports GTK or WebKit: the whole point of splitting logic.py from
app.py is that the security-relevant decisions are testable on a host that
has no GUI. app.py is only compiled, never imported.
"""

import datetime
import http.server
import os
import py_compile
import ssl
import sys
import tempfile
import threading
import unittest

from supermox_manager import logic


def _self_signed_cn(common_name):
    """A throwaway self-signed certificate, as pveproxy makes its own."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    now = datetime.datetime.now(datetime.timezone.utc)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=365))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName("127.0.0.1")]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    return (
        cert.public_bytes(serialization.Encoding.PEM),
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ),
        cert.public_bytes(serialization.Encoding.DER),
    )


class _TempDir:
    """Temp files live under the repo's build/ dir, never in /tmp."""

    def __init__(self):
        root = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))))
        self.base = os.path.join(root, "build", "tmp")
        os.makedirs(self.base, exist_ok=True)

    def make(self):
        return tempfile.TemporaryDirectory(dir=self.base)


class FingerprintTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pem, cls.key_pem, cls.der = _self_signed_cn("supermox-test-a")
        cls.other_pem, _k, cls.other_der = _self_signed_cn("supermox-test-b")

    def test_pem_and_der_agree(self):
        self.assertEqual(logic.fingerprint_pem(self.pem),
                         logic.fingerprint_der(self.der))

    def test_fingerprint_is_lowercase_sha256_hex(self):
        fp = logic.fingerprint_pem(self.pem)
        self.assertEqual(len(fp), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in fp))

    def test_distinct_certificates_distinct_fingerprints(self):
        self.assertNotEqual(logic.fingerprint_pem(self.pem),
                            logic.fingerprint_pem(self.other_pem))

    def test_pem_of_der_roundtrip(self):
        pem = logic.pem_of_der(self.der)
        self.assertEqual(logic.fingerprint_pem(pem), logic.fingerprint_der(self.der))

    def test_unparseable_input_is_none(self):
        self.assertIsNone(logic.fingerprint_pem(b"not a certificate"))
        self.assertIsNone(logic.fingerprint_pem(""))
        self.assertIsNone(logic.fingerprint_pem(b""))


class DecideTests(unittest.TestCase):
    """decide() returns (allowed, reason); only an exact pin match allows."""

    def test_match_allows(self):
        ok, reason = logic.decide("ab" * 32, "ab" * 32)
        self.assertTrue(ok)
        self.assertIn("matches", reason)

    def test_mismatch_denies(self):
        ok, reason = logic.decide("ab" * 32, "cd" * 32)
        self.assertFalse(ok)
        self.assertIn("does not match", reason)

    def test_no_pin_denies_even_when_the_node_answers(self):
        # A node whose membership entry carries no tls_fingerprint, and a
        # local node whose certificate file cannot be read, are both refused.
        for pin in (None, ""):
            ok, reason = logic.decide("ab" * 32, pin)
            self.assertFalse(ok)
            self.assertIn("no pinned certificate", reason)

    def test_unreachable_node_denies(self):
        ok, reason = logic.decide(None, "ab" * 32)
        self.assertFalse(ok)
        self.assertIn("could not reach", reason)

    def test_no_shortcuts_on_empty_both_sides(self):
        self.assertFalse(logic.decide(None, None)[0])
        self.assertFalse(logic.decide("", "ab" * 32)[0])


class CertFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = _TempDir()

    def _pve_dir(self, *files):
        d = self.tmp.make()
        self.addCleanup(d.cleanup)
        base = d.name
        for name, body in files:
            path = os.path.join(base, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(body)
        return base

    def test_proxy_certificate_is_preferred(self):
        pem = _self_signed_cn("supermox-test-a")[0]
        base = self._pve_dir(("local/pveproxy-ssl.pem", pem), ("pve-ssl.pem", pem))
        self.assertEqual(logic.cert_file(base),
                         os.path.join(base, "local/pveproxy-ssl.pem"))

    def test_cluster_certificate_is_the_fallback(self):
        pem = _self_signed_cn("supermox-test-a")[0]
        base = self._pve_dir(("pve-ssl.pem", pem))
        self.assertEqual(logic.cert_file(base), os.path.join(base, "pve-ssl.pem"))

    def test_no_certificate_file_is_none(self):
        self.assertIsNone(logic.cert_file(self._pve_dir()))

    def test_pin_from_cert_file(self):
        pem = _self_signed_cn("supermox-test-a")[0]
        base = self._pve_dir(("local/pveproxy-ssl.pem", pem))
        self.assertEqual(logic.pin_from_cert_file(os.path.join(base, "local/pveproxy-ssl.pem")),
                         logic.fingerprint_pem(pem))

    def test_missing_or_broken_cert_file_is_none(self):
        base = self._pve_dir(("local/pveproxy-ssl.pem", b"-----BEGIN CERTIFICATE-----\nbroken\n"))
        self.assertIsNone(logic.pin_from_cert_file(os.path.join(base, "local/pveproxy-ssl.pem")))
        self.assertIsNone(logic.pin_from_cert_file(os.path.join(base, "absent.pem")))


class PeerCertTests(unittest.TestCase):
    def setUp(self):
        self.tmp = _TempDir()
    """fetch_peer_cert() must report the certificate the node really sends.

    The handshake is deliberately unverified: trust comes from the fingerprint
    comparison, never from a CA store.
    """

    @classmethod
    def setUpClass(cls):
        cls.pem, cls.key_pem, cls.der = _self_signed_cn("supermox-test-a")

    def _serve_tls(self):
        d = self.tmp.make()
        self.addCleanup(d.cleanup)
        cert = os.path.join(d.name, "cert.pem")
        key = os.path.join(d.name, "key.pem")
        with open(cert, "wb") as fh:
            fh.write(self.pem)
        with open(key, "wb") as fh:
            fh.write(self.key_pem)
        srv = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()

        def stop():
            try:
                srv.shutdown()
            except OSError:
                pass
            srv.server_close()
            thread.join(timeout=5)

        self.addCleanup(stop)
        return srv

    def test_presented_certificate_fingerprint_matches_the_pin(self):
        srv = self._serve_tls()
        port = srv.server_address[1]
        fetched = logic.fetch_peer_cert("127.0.0.1", port)
        self.assertIsNotNone(fetched)
        der, pem, fingerprint = fetched
        self.assertEqual(der, self.der)
        self.assertEqual(fingerprint, logic.fingerprint_pem(self.pem))
        self.assertTrue(logic.decide(fingerprint, logic.fingerprint_pem(self.pem))[0])

    def test_a_foreign_certificate_is_refused(self):
        other_der = _self_signed_cn("supermox-test-b")[2]
        fingerprint = logic.fingerprint_der(other_der)
        ok, reason = logic.decide(fingerprint, logic.fingerprint_pem(self.pem))
        self.assertFalse(ok)
        self.assertIn("does not match", reason)

    def test_unreachable_host_returns_none(self):
        # Port 1 has nothing listening; no exception may escape.
        self.assertIsNone(logic.fetch_peer_cert("127.0.0.1", 1, timeout=1.0))


class NodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = _TempDir()

    def _tmpdir(self):
        d = self.tmp.make()
        self.addCleanup(d.cleanup)
        return d.name

    def test_bare_host_drops_the_overlay_port(self):
        self.assertEqual(logic.bare_host("10.0.0.5:12345"), "10.0.0.5")
        self.assertEqual(logic.bare_host("phone-1.example.org:9"), "phone-1.example.org")
        self.assertEqual(logic.bare_host("10.0.0.5"), "10.0.0.5")

    def test_node_url_is_https_on_the_pveproxy_port(self):
        self.assertEqual(logic.node_url("phone-1"), "https://phone-1:8006/")
        self.assertEqual(logic.node_url("10.0.0.5"), "https://10.0.0.5:8006/")

    def test_membership_of_a_state_without_one_is_empty(self):
        self.assertEqual(logic.membership(None), [])
        self.assertEqual(logic.membership(object()), [])

    def test_entry_for(self):
        st = _state([{"name": "pc-2", "tls_fingerprint": "aa" * 32}])
        self.assertEqual(logic.entry_for("pc-2", st)["tls_fingerprint"], "aa" * 32)
        self.assertIsNone(logic.entry_for("pc-9", st))

    def test_pin_for_a_remote_member_comes_from_the_membership_list(self):
        st = _state([{"name": "pc-2", "tls_fingerprint": "aa" * 32}])
        self.assertEqual(logic.pin_for("pc-2", st, "pc-1"), "aa" * 32)

    def test_a_remote_member_without_a_fingerprint_has_no_pin(self):
        st = _state([{"name": "phone-1"}])
        self.assertIsNone(logic.pin_for("phone-1", st, "pc-1"))

    def test_the_local_node_is_pinned_to_its_own_certificate_file(self):
        pem = _self_signed_cn("supermox-test-a")[0]
        base = self._tmpdir()
        path = os.path.join(base, "local", "pveproxy-ssl.pem")
        os.makedirs(os.path.dirname(path))
        with open(path, "wb") as fh:
            fh.write(pem)
        st = _state([{"name": "pc-1"}])
        self.assertEqual(logic.pin_for("pc-1", st, "pc-1", pve_dir=base),
                         logic.fingerprint_pem(pem))

    def test_the_local_node_with_no_certificate_file_has_no_pin(self):
        st = _state([{"name": "pc-1"}])
        self.assertIsNone(logic.pin_for("pc-1", st, "pc-1", pve_dir=self._tmpdir()))

    def test_a_local_node_named_otherwise_is_still_pinned_to_the_local_cert(self):
        pem = _self_signed_cn("supermox-test-b")[0]
        base = self._tmpdir()
        with open(os.path.join(base, "pve-ssl.pem"), "wb") as fh:
            fh.write(pem)
        st = _state([])
        self.assertEqual(logic.pin_local(pve_dir=base), logic.fingerprint_pem(pem))
        self.assertEqual(logic.pin_for("(this host)", st, "pc-1",
                                        pve_dir=base, is_local=True),
                         logic.fingerprint_pem(pem))

    def test_the_local_certificate_is_preferred_over_the_cluster_wide_one(self):
        local_pem = _self_signed_cn("supermox-test-d")[0]
        base = self._tmpdir()
        with open(os.path.join(base, "pve-ssl.pem"), "wb") as fh:
            fh.write(_self_signed_cn("supermox-test-c")[0])
        os.makedirs(os.path.join(base, "local"))
        with open(os.path.join(base, "local", "pveproxy-ssl.pem"), "wb") as fh:
            fh.write(local_pem)
        self.assertEqual(logic.pin_local(pve_dir=base),
                         logic.fingerprint_pem(local_pem))

    def test_node_list_puts_the_local_node_first(self):
        st = _state([
            {"name": "pc-1"},
            {"name": "phone-1", "overlay_addr": "10.0.0.7:4433"},
            {"name": "pc-2", "overlay_addr": "10.0.0.6:1234"},
        ])
        nodes = logic.node_list(st, "pc-1")
        self.assertEqual([n for n, _u, _l in nodes], ["pc-1", "pc-2", "phone-1"])
        self.assertTrue(nodes[0][2])
        self.assertEqual(nodes[0][1], logic.node_url(logic.LOCAL_HOST))
        self.assertEqual(nodes[1][1], "https://10.0.0.6:8006/")

    def test_a_member_with_no_overlay_address_is_not_offered(self):
        st = _state([{"name": "pc-1"}, {"name": "phone-2"}])
        self.assertEqual([n for n, _u, _l in logic.node_list(st, "pc-1")], ["pc-1"])

    def test_node_list_of_an_empty_membership_is_empty(self):
        self.assertEqual(logic.node_list(_state([]), "pc-1"), [])


def _state(membership):
    """A stand-in for supermox.state.NodeState: logic only reads .membership."""
    class Fake:
        pass
    fake = Fake()
    fake.membership = membership
    return fake


class SettingsTests(unittest.TestCase):
    """The app keeps only the window size and the last node, in $XDG_CONFIG_HOME."""

    def setUp(self):
        self.tmp = _TempDir()
        self.old_xdg = os.environ.get("XDG_CONFIG_HOME")

    def tearDown(self):
        if self.old_xdg is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = self.old_xdg

    def _use_config_dir(self):
        d = self.tmp.make()
        self.addCleanup(d.cleanup)
        os.environ["XDG_CONFIG_HOME"] = d.name
        return d.name

    def test_settings_path_is_under_the_config_dir(self):
        base = self._use_config_dir()
        path = logic.settings_path()
        self.assertEqual(path, os.path.join(base, "supermox-manager", "settings.json"))

    def test_roundtrip_creates_the_directory(self):
        base = self._use_config_dir()
        self.assertTrue(logic.save_settings({"width": 1024, "node": "pc-2"}))
        settings = logic.load_settings()
        self.assertEqual(settings["width"], 1024)
        self.assertEqual(settings["node"], "pc-2")
        self.assertEqual(len(os.listdir(os.path.join(base, "supermox-manager"))), 1)

    def test_missing_settings_give_defaults(self):
        self._use_config_dir()
        self.assertEqual(logic.load_settings(), logic.DEFAULTS)

    def test_broken_settings_give_defaults(self):
        base = self._use_config_dir()
        path = os.path.join(base, "supermox-manager", "settings.json")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            fh.write("{not json")
        self.assertEqual(logic.load_settings(), logic.DEFAULTS)

    def test_non_object_settings_give_defaults(self):
        base = self._use_config_dir()
        path = os.path.join(base, "supermox-manager", "settings.json")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            fh.write("[1, 2]")
        self.assertEqual(logic.load_settings(), logic.DEFAULTS)

    def test_unknown_keys_are_dropped(self):
        base = self._use_config_dir()
        logic.save_settings({"width": 800, "secret": "x"})
        self.assertEqual(logic.load_settings()["width"], 800)
        self.assertNotIn("secret", logic.load_settings())

    def test_no_secrets_are_stored(self):
        base = self._use_config_dir()
        logic.save_settings({"width": 800, "height": 600, "node": "pc-2"})
        with open(os.path.join(base, "supermox-manager", "settings.json")) as fh:
            stored = fh.read()
        for word in ("fingerprint", "secret", "phrase", "key", "word"):
            self.assertNotIn(word, stored)


class GuiCompilesTests(unittest.TestCase):
    """The GUI file and the launcher must at least compile on a headless host."""

    def test_app_and_launcher_compile(self):
        root = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))))
        tmp = _TempDir()
        with tmp.make() as d:
            for i, name in enumerate((os.path.join("src", "supermox_manager", "app.py"),
                                      os.path.join("bin", "supermox-manager"))):
                py_compile.compile(os.path.join(root, name),
                                   cfile=os.path.join(d, "c%d.pyc" % i),
                                   doraise=True)

    def test_logic_pulls_in_no_gui_libraries(self):
        for mod in ("gi", "gtk", "WebKit", "cairo"):
            self.assertNotIn(mod, sys.modules)


if __name__ == "__main__":
    unittest.main()
