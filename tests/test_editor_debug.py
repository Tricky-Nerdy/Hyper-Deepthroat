"""Bounded DAP framing and temporary neutral-editor fixture tests; no display required."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("editor_debug", ROOT / "tools/editor_debug.py")
editor = importlib.util.module_from_spec(spec)
with mock.patch.object(sys, "path", [str(ROOT / "tools")] + sys.path):
    spec.loader.exec_module(editor)


class Recorder:
    def __init__(self):
        self.events = []

    def emit(self, event, **fields):
        self.events.append(dict(event=event, **fields))


class Connection:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.sent = b""

    def settimeout(self, timeout):
        if timeout <= 0:
            raise TimeoutError("fixture deadline")

    def sendall(self, data):
        self.sent += data

    def recv(self, _size):
        return self.chunks.pop(0) if self.chunks else b""


def frame(message):
    data = json.dumps(message, ensure_ascii=False).encode()
    return f"Content-Length: {len(data)}\r\n\r\n".encode() + data


class EditorDebugProtocol(unittest.TestCase):
    def test_fragmented_utf8_response_preserves_preceding_event(self):
        event = {"type": "event", "event": "initialized"}
        response = {"type": "response", "request_seq": 1, "success": True, "body": {"value": "créatif ✨"}}
        data = frame(event) + frame(response)
        connection = Connection([data[i:i + 7] for i in range(0, len(data), 7)])
        dap = editor.DAP(connection, Recorder())
        self.assertEqual(dap.request("initialize", linesStartAt1=True), response["body"])
        self.assertEqual(dap.event("initialized"), {})
        self.assertIn(b'"command": "initialize"', connection.sent)

    def test_oversized_or_negative_message_is_rejected_before_body(self):
        for length in (-1, editor.MAX_MESSAGE + 1):
            dap = editor.DAP(Connection([f"Content-Length: {length}\r\n\r\n".encode()]), Recorder())
            with self.assertRaises(ValueError):
                dap.receive()

    def test_complete_oversized_header_is_rejected(self):
        data = b"Extra: " + b"x" * 4096 + b"\r\nContent-Length: 2\r\n\r\n{}"
        with self.assertRaises(ValueError):
            editor.DAP(Connection([data]), Recorder()).receive()

    def test_disconnection_and_error_response_are_not_success(self):
        with self.assertRaises(ConnectionError):
            editor.DAP(Connection([]), Recorder()).receive()
        failed = {"type": "response", "request_seq": 1, "success": False, "message": "fixture failure"}
        with self.assertRaises(RuntimeError):
            editor.DAP(Connection([frame(failed)]), Recorder()).request("stepIn")

    def test_runtime_pid_and_metrics_are_read_from_engine_output(self):
        output = "WORKBENCH_READY " + json.dumps({"schema": 1, "pid": 123, "headless": False}) + "\n"
        output += "WORKBENCH_METRICS " + json.dumps({"schema": 1, "headless": False, "observed_fps": 60})
        dap = editor.DAP(Connection([frame({"type": "event", "event": "output", "body": {"output": output}})]), Recorder())
        dap.event("output")
        self.assertEqual(dap.runtime_info["pid"], 123)
        self.assertEqual(dap.metrics[0]["observed_fps"], 60)

    def test_fixture_instruments_only_temporary_staged_project(self):
        original = ROOT / "workbench/main.gd"
        before = hashlib.sha256(original.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apply_line, result_line = editor.fixture(root / "project", root / "evidence")
            lines = (root / "project/main.gd").read_text().splitlines()
            self.assertIn("commands.propose(_request.text)", lines[apply_line - 1])
            self.assertIn("JSON.stringify(result)", lines[result_line - 1])
            self.assertTrue((root / "project/addons/editor_probe/plugin.gd").exists())
        self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
