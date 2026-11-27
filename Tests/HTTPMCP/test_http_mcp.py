"""Run: python3 Tests/HTTPMCP/test_http_mcp.py [path/to/beanpod]. Uses an isolated macOS profile."""
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = Path(sys.argv.pop(1) if len(sys.argv) > 1 else ".build/debug/beanpod").resolve()


class HTTPMCPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.profile = tempfile.TemporaryDirectory(prefix="beanpod-http-test-")
        cls.env = dict(os.environ, CFFIXED_USER_HOME=cls.profile.name)
        cls.env.pop("BEANPOD_MCP_TOKEN", None)
        cls.root = Path(cls.profile.name) / "Library/Application Support/BeanPod"
        cls.token = subprocess.check_output([BINARY, "http-token"], env=cls.env, text=True).strip()
        assert (cls.root / "http-mcp-token").exists(), "Profile isolation is required"
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        cls.server = subprocess.Popen([BINARY, "serve", "--port", str(cls.port)], env=cls.env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=.2):
                    break
            except OSError:
                if cls.server.poll() is not None:
                    raise RuntimeError("HTTP MCP failed to start")
                time.sleep(.05)
        else:
            raise RuntimeError("HTTP MCP did not start")

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)
        cls.profile.cleanup()

    def request(self, payload=None, *, method="POST", path="/mcp", headers=None, auth=True, extra=()):
        body = json.dumps(payload or {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
        fields = {"Host": f"127.0.0.1:{self.port}", "Content-Type": "application/json", "Content-Length": str(len(body))}
        if auth:
            fields["Authorization"] = "Bearer " + self.token
        for key, value in (headers or {}).items():
            if value is None:
                fields.pop(key, None)
            else:
                fields[key] = value
        head = f"{method} {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in list(fields.items()) + list(extra)) + "\r\n"
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as sock:
            sock.sendall(head.encode() + body)
            result = b""
            while True:
                data = sock.recv(65536)
                if not data:
                    break
                result += data
        response, content = result.split(b"\r\n\r\n", 1)
        lines = response.decode().split("\r\n")
        fields = dict(line.lower().split(": ", 1) for line in lines[1:])
        self.assertNotIn("access-control-allow-origin", fields)
        return int(lines[0].split()[1]), content

    def test_authenticated_initialize_tools_and_batch(self):
        for method in ("initialize", "tools/list", "ping"):
            code, body = self.request({"jsonrpc": "2.0", "id": 1, "method": method})
            self.assertEqual(code, 200)
            self.assertIn("result", json.loads(body))
        code, body = self.request([{"jsonrpc": "2.0", "id": i, "method": "ping"} for i in (1, 2)])
        self.assertEqual((code, len(json.loads(body))), (200, 2))

    def test_auth_required(self):
        self.assertEqual(self.request(auth=False)[0], 401)
        self.assertEqual(self.request(headers={"Authorization": "Bearer " + "0" * 64})[0], 401)

    def test_browser_origins_and_fetch_metadata_rejected(self):
        for headers in ({"Origin": "https://untrusted.invalid"}, {"Origin": "null"}, {"Origin": ""},
                        {"Origin": f"http://127.0.0.1:{self.port}"}, {"Sec-Fetch-Site": "none"}, {"Sec-Fetch-Mode": "no-cors"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.request(headers=headers)[0], 403)
        self.assertEqual(self.request(method="OPTIONS", headers={"Origin": "https://untrusted.invalid"})[0], 403)

    def test_host_route_and_content_type(self):
        for host in ("untrusted.invalid", f"untrusted.invalid:{self.port}", "127.0.0.1", f"127.0.0.1:{self.port}@untrusted.invalid"):
            self.assertEqual(self.request(headers={"Host": host})[0], 403)
        for path in ("/other", "/mcp?token=bad", "/%6dcp", f"http://127.0.0.1:{self.port}/mcp"):
            self.assertEqual(self.request(path=path)[0], 404)
        self.assertEqual(self.request(headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request(headers={"Content-Type": "application/json; charset=utf-8", "Host": f"LOCALHOST:{self.port}", "Authorization": "bearer " + self.token})[0], 200)
        self.assertEqual(self.request(method="OPTIONS")[0], 405)

    def test_unauthorized_writes_have_no_side_effects(self):
        before = set(self.root.rglob("*"))
        write = {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "add_note", "arguments": {"title": "test", "text": "must not be saved"}}}
        for payload in (write, [write]):
            self.assertEqual(self.request(payload, auth=False)[0], 401)
            self.assertEqual(self.request(payload, headers={"Origin": "https://untrusted.invalid"})[0], 403)
        self.assertEqual(before, set(self.root.rglob("*")))

    def test_malformed_framing_never_dispatches_or_crashes(self):
        for length in ("", " ", "-1", "+1", "abc", "1,1", "999999999999999999999999"):
            self.assertEqual(self.request(headers={"Content-Length": length})[0], 400)
        self.assertEqual(self.request(headers={"Content-Length": str(8 * 1024 * 1024 + 1)})[0], 413)
        self.assertEqual(self.request(headers={"Content-Length": None})[0], 411)
        self.assertEqual(self.request(headers={"Transfer-Encoding": "chunked"})[0], 400)
        for name, value in (("content-length", "2"), ("authorization", "Bearer bad"), ("host", "untrusted.invalid"), ("origin", "https://untrusted.invalid")):
            headers = {"Origin": "null"} if name == "origin" else {}
            self.assertEqual(self.request(headers=headers, extra=[(name, value)])[0], 400)
        self.assertEqual(self.request(headers={"X-Large": "x" * 17000})[0], 400)
        self.assertEqual(self.request()[0], 200)

    def test_stdio_unchanged(self):
        result = subprocess.run([BINARY, "mcp"], input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
                                text=True, capture_output=True, env=self.env, check=True)
        self.assertIn("search_recordings", result.stdout)

    def test_credential_persists_and_fails_closed(self):
        token_file = self.root / "http-mcp-token"
        result = subprocess.check_output([BINARY, "http-token"], env=self.env, text=True).strip()
        self.assertEqual(result, self.token)
        self.assertEqual(stat.S_IMODE(token_file.stat().st_mode), 0o600)
        with tempfile.TemporaryDirectory(prefix="beanpod-invalid-token-") as home:
            folder = Path(home) / "Library/Application Support/BeanPod"
            folder.mkdir(parents=True)
            target = folder / "http-mcp-token"
            target.write_text("invalid")
            target.chmod(0o600)
            env = dict(self.env, CFFIXED_USER_HOME=home)
            self.assertNotEqual(subprocess.run([BINARY, "http-token"], env=env, capture_output=True).returncode, 0)
            self.assertEqual(target.read_text(), "invalid")
            target.write_text(self.token)
            target.chmod(0o644)
            self.assertNotEqual(subprocess.run([BINARY, "http-token"], env=env, capture_output=True).returncode, 0)
            target.unlink()
            target.symlink_to(token_file)
            self.assertNotEqual(subprocess.run([BINARY, "http-token"], env=env, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
