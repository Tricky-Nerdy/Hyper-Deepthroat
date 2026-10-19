"""Neutral providers and actual Godot HTTP against a loopback-only mock, never real AI servers."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import base64
import os
from pathlib import Path
import shutil
import subprocess
import sys
import struct
import tempfile
import threading
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get("GODOT") or shutil.which("godot")


def neutral_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(b"\0\0\0\xff")) + chunk(b"IEND", b"")


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False  # server_close joins request workers, including the bounded timeout fixture.

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(3)
        return connection, address


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The client intentionally times out during the slow fixture.

    def do_GET(self):
        if self.headers.get("Authorization") == "Bearer test-only-token":
            self.server.session_token_seen = True
        if self.headers.get("Authorization") == "Bearer test-only-env-token":
            self.server.environment_token_seen = True
        if self.path == "/v1/models":
            self.reply({"data": [{"id": "fixture"}]})
        elif self.path in ("/system_stats", "/sdapi/v1/options"):
            self.reply({"fixture": True})
        elif self.path == "/history/fixture-job":
            self.reply({"fixture-job": {"status": {"completed": True}, "outputs": {"1": {"images": [{"filename": "neutral.png", "type": "output"}]}}}})
        elif self.path == "/history/failed-job":
            self.reply({"failed-job": {"status": {"status_str": "error"}}})
        elif self.path.startswith("/view?filename=neutral.png&"):
            body = neutral_png()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.reply({})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 16384:
            self.reply({}, 413)
            return
        data = json.loads(self.rfile.read(length))
        if self.path == "/v1/chat/completions":
            if not isinstance(data.get("messages"), list) or data.get("stream") is not False or data.get("max_tokens") != 256:
                self.reply({}, 400)
                return
            model = data.get("model")
            if model == "unavailable":
                self.reply({"error": "not exposed to the caller"}, 503)
            elif model == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://203.0.113.1/never-follow")
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif model == "badjson":
                self.send_response(200)
                self.send_header("Content-Length", "1")
                self.end_headers()
                self.wfile.write(b"{")
            elif model == "badschema":
                self.reply({"choices": [{}]})
            elif model == "oversized":
                self.reply({"padding": "x" * 8192})
            elif model == "slow":
                time.sleep(2)
                self.reply({})
            else:
                self.reply({"choices": [{"message": {"content": "Loopback fixture reply"}}]})
        elif self.path == "/prompt":
            self.reply({"prompt_id": "fixture-job"} if isinstance(data.get("prompt"), dict) else {},
                       200 if isinstance(data.get("prompt"), dict) else 400)
        elif self.path == "/sdapi/v1/txt2img":
            valid = isinstance(data.get("prompt"), str) and all(data.get(key) == value for key, value in
                    {"width": 512, "height": 512, "steps": 12, "batch_size": 1, "n_iter": 1}.items())
            self.reply({"images": [base64.b64encode(neutral_png()).decode()]} if valid else {}, 200 if valid else 400)
        else:
            self.reply({}, 404)


class AIProviders(unittest.TestCase):
    @unittest.skipUnless(GODOT, "requires Godot (GODOT environment path or PATH)")
    def test_provider_contracts_and_bounded_loopback_http(self):
        (ROOT / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="independent-ai-", dir=ROOT / "build") as temp:
            project = Path(temp)
            target = project / "src/integrations/ai"
            target.parent.mkdir(parents=True)
            shutil.copytree(ROOT / "game/src/integrations/ai", target)
            atomic = project / "src/ext/loader/atomic_json.gd"
            atomic.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "game/src/ext/loader/atomic_json.gd", atomic)
            shutil.copy2(ROOT / "tools/fixtures/ai_provider_checks.gd", project / "checks.gd")
            (project / "main.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://checks.gd" id="1"]\n[node name="NeutralAIContracts" type="Node"]\nscript=ExtResource("1")\n')
            (project / "project.godot").write_text('config_version=5\n[application]\nrun/main_scene="res://main.tscn"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            env = dict(os.environ, TMPDIR=str(project))
            # Isolate desktop OS profile locations too; only the child environment is changed.
            for key in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA"):
                path = project / key
                path.mkdir()
                env[key] = str(path)
            for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
                env[key] = str(project / key)
            server = FixtureServer(("127.0.0.1", 0), Handler)
            server.session_token_seen = False
            server.environment_token_seen = False
            env["SDT_AI_TEST_ENDPOINT"] = f"http://127.0.0.1:{server.server_port}"
            env["SDT_AI_TEST_BEARER"] = "test-only-env-token"
            env["SDT_AI_TEST_PROFILE"] = str(project / "profile/providers.json")
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                for label, flags in (("import", ["--editor", "--import"]), ("runtime", ["--quit-after", "600"])):
                    result = subprocess.run([GODOT, "--headless", "--path", str(project), *flags],
                                            cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
                    text = result.stdout + result.stderr
                    details = "\n".join(text.splitlines()[-35:])
                    self.assertEqual(result.returncode, 0, details)
                    self.assertFalse("SCRIPT ERROR" in text or "ERROR:" in text, details)
                    if label == "runtime":
                        self.assertIn("AI_PROVIDER_CHECKS_OK", text)
                        self.assertTrue(server.session_token_seen)
                        self.assertTrue(server.environment_token_seen)
            finally:
                server.shutdown()
                thread.join(timeout=5)
                server.server_close()
                self.assertFalse(thread.is_alive(), "mock server thread leaked")


if __name__ == "__main__":
    unittest.main()
