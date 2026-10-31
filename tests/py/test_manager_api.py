"""Exercise the native client against a real local TLS endpoint, no GTK needed."""
import http.server
import io
import json
import ssl
import threading
import unittest
from pathlib import Path
from urllib.parse import parse_qs

from supermox_manager import api, logic
from test_manager_pin import _self_signed_cn, _TempDir


class ManagerAPI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = _TempDir().make()
        root = Path(cls.directory.name)
        pem, key, der = _self_signed_cn('manager-test')
        (root / 'cert.pem').write_bytes(pem)
        (root / 'key.pem').write_bytes(key)
        cls.pin = logic.fingerprint_der(der)

        class Handler(http.server.BaseHTTPRequestHandler):
            def handle(self):
                try:
                    super().handle()
                except (BrokenPipeError, ConnectionResetError):
                    # A pin rejection deliberately closes TLS before sending HTTP.
                    pass

            def log_message(self, *_args):
                pass

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.respond()

            def respond(self):
                length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(length) if length else b''
                self.server.last_body = body
                ctype = self.headers.get('Content-Type', '')
                params = (parse_qs(body.decode('utf-8', 'replace'))
                          if 'x-www-form-urlencoded' in ctype else {})
                self.server.requests.append((self.command, self.path, dict(self.headers), params))
                status, result = self.server.reply
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())

        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(root / 'cert.pem'), str(root / 'key.pem'))
        cls.server.socket = ctx.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = 'https://127.0.0.1:{}/'.format(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.directory.cleanup()

    def setUp(self):
        self.server.requests = []
        self.server.last_body = b''
        self.server.reply = (200, {'data': []})
        self.client = api.Client(self.url, self.pin)

    def login(self):
        self.server.reply = (200, {'data': {'ticket': 'PVE:test+ticket',
                                         'CSRFPreventionToken': 'csrf', 'username': 'admin@pam'}})
        self.client.login('admin@pam', 'secret & password', '123456')

    def test_login_cookie_csrf_and_guest_action(self):
        self.login()
        method, path, headers, params = self.server.requests[-1]
        self.assertEqual((method, path), ('POST', '/api2/json/access/ticket'))
        self.assertEqual(params['password'], ['secret & password'])
        self.assertEqual(params['otp'], ['123456'])
        self.assertNotIn('Cookie', headers)
        self.server.reply = (200, {'data': 'UPID:test'})
        guest = {'node': 'atlas', 'type': 'qemu', 'vmid': 100}
        self.assertEqual(self.client.action(guest, 'start'), 'UPID:test')
        method, path, headers, params = self.server.requests[-1]
        self.assertEqual(path, '/api2/json/nodes/atlas/qemu/100/status/start')
        self.assertEqual(headers['CSRFPreventionToken'], 'csrf')
        self.assertEqual(headers['Cookie'], 'PVEAuthCookie=PVE%3Atest%2Bticket')
        self.assertEqual(params, {})

    def test_pin_mismatch_sends_no_http_or_password(self):
        client = api.Client(self.url, '0' * 64)
        with self.assertRaisesRegex(api.APIError, 'No credentials were sent'):
            client.login('root@pam', 'never-send-this')
        self.assertEqual(self.server.requests, [])

    def test_expired_session_is_cleared(self):
        self.login()
        self.server.reply = (401, {'data': None})
        with self.assertRaisesRegex(api.APIError, 'Sign in again'):
            self.client.resources()
        self.assertIsNone(self.client.ticket)
        self.assertIsNone(self.client.csrf)
        self.assertIsNone(self.client.username)

    def test_tfa_challenge_is_never_a_session(self):
        self.server.reply = (200, {'data': {'ticket': 'PVE:!tfa!challenge', 'NeedTFA': 1,
                                         'CSRFPreventionToken': 'csrf'}})
        with self.assertRaisesRegex(api.APIError, 'interactive second factor'):
            self.client.login('admin@pam', 'password')
        self.assertIsNone(self.client.ticket)

    def test_redirect_is_not_followed(self):
        self.server.reply = (302, {'data': None})
        with self.assertRaises(api.APIError):
            self.client.resources()
        self.assertEqual(len(self.server.requests), 1)

    def test_error_text_does_not_echo_server_secrets(self):
        self.server.reply = (500, {'message': 'secret-password-123', 'data': None})
        with self.assertRaises(api.APIError) as caught:
            self.client.resources()
        self.assertNotIn('secret-password-123', str(caught.exception))

    def test_resource_paths_and_query(self):
        self.client.resources()
        self.assertEqual(self.server.requests[-1][1], '/api2/json/cluster/resources')
        self.client.tasks()
        self.assertEqual(self.server.requests[-1][1], '/api2/json/cluster/tasks')
        self.client.request('GET', '/nodes/atlas/tasks/a/log', {'limit': 500})
        self.assertTrue(self.server.requests[-1][1].endswith('?limit=500'))

    def test_origin_and_fingerprint_validation(self):
        for value in ('http://node/', 'https://user:pass@node/', 'https://node/a',
                      'https://node/#x', 'https://node/?x', 'https://node:bad/'):
            with self.assertRaises(ValueError):
                api.endpoint(value)
        self.assertEqual(api.endpoint('https://[::1]:8006/')[1:], ('::1', 8006))
        self.assertEqual(api.fingerprint(':'.join(['AB'] * 32)), 'ab' * 32)
        with self.assertRaises(ValueError):
            api.fingerprint('abc')
        with self.assertRaises(ValueError):
            self.client.action({'type': 'qemu'}, 'destroy')

    def test_upload_streams_multipart_and_csrf(self):
        self.login()
        self.server.reply = (200, {'data': 'UPID:upload'})
        content = b'A' * (1024 * 1024 + 4096)
        fields = {'content': 'iso'}
        result = self.client.upload('/nodes/atlas/storage/local/upload',
                                    fields, 't.iso', io.BytesIO(content), len(content))
        self.assertEqual(result, 'UPID:upload')
        method, path, headers, params = self.server.requests[-1]
        self.assertEqual((method, path), ('POST', '/api2/json/nodes/atlas/storage/local/upload'))
        self.assertEqual(headers['CSRFPreventionToken'], 'csrf')
        self.assertEqual(headers['Cookie'], 'PVEAuthCookie=PVE%3Atest%2Bticket')
        self.assertIn('multipart/form-data; boundary=', headers['Content-Type'])
        boundary = headers['Content-Type'].split('boundary=', 1)[1]
        expected = (
            '--{b}\r\nContent-Disposition: form-data; name="content"\r\n\r\niso\r\n'
            '--{b}\r\nContent-Disposition: form-data; name="filename"; filename="t.iso"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n'
        ).format(b=boundary).encode('utf-8') + content + ('\r\n--{}--\r\n'.format(boundary).encode('utf-8'))
        self.assertEqual(self.server.last_body, expected)
        self.assertEqual(int(headers['Content-Length']), len(expected))

    def test_preferences_never_save_credentials(self):
        cleaned = logic.clean_settings({'width': 'bad', 'height': -1, 'password': 'secret',
                                        'ticket': 'secret', 'zoom': 1.5, 'node': 'atlas'})
        self.assertEqual(cleaned, {'zoom': 1.5, 'node': 'atlas'})

    def test_preview_is_explicit_and_isolated(self):
        demo = api.DemoClient()
        guest = next(row for row in demo.resources() if row.get('vmid') == 102)
        self.assertIn('Preview only', demo.action(guest, 'start'))
        self.assertEqual(next(row for row in demo.resources() if row.get('vmid') == 102)['status'], 'running')
        self.assertEqual(self.server.requests, [])

    def test_use_token_sets_state(self):
        client = api.Client("https://x.invalid", "0" * 64)
        client.ticket = "PVE::..."
        client.use_token("t74u@pve!t74t", "11111111-2222-3333-4444-555555555555")
        self.assertEqual(client.token, ("t74u@pve!t74t", "11111111-2222-3333-4444-555555555555"))
        self.assertIsNone(client.ticket)
        self.assertIsNone(client.csrf)
        self.assertIsNone(client.username)

    def test_use_token_needs_both(self):
        client = api.Client("https://x.invalid", "0" * 64)
        self.assertRaises(ValueError, client.use_token, "t74u@pve!t74t", "")
        self.assertRaises(ValueError, client.use_token, "", "secret")

    def test_logout_clears_token(self):
        client = api.Client("https://x.invalid", "0" * 64)
        client.use_token("t74u@pve!t74t", "secret")
        client.logout()
        self.assertIsNone(client.token)

    def test_token_header_is_sent_without_cookie(self):
        client = api.Client("https://x.invalid", "0" * 64)
        client.use_token("t74u@pve!t74t", "secret-uuid")
        captured = {}

        class FakeConnection:
            def request(self, method, target, body=None, headers=None):
                captured["method"] = method
                captured["headers"] = headers
                raise AssertionError("stop before network")
            def close(self):
                pass

        client._connect = lambda: FakeConnection()
        try:
            client.request("GET", "/version")
        except AssertionError:
            pass
        self.assertEqual(captured["headers"]["Authorization"],
                         "PVEAPIToken=t74u@pve!t74t=secret-uuid")
        self.assertNotIn("Cookie", captured["headers"])
