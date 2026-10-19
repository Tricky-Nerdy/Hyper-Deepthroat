#!/usr/bin/env python3
"""Exercise real Godot editor breakpoints over loopback DAP in a temporary neutral project.

Requires an available graphical display. Does not automate desktop-wide input or capture other apps.
All source instrumentation, editor settings and saves are confined to a temporary fixture.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time

import dev_debug
import portable_release

ROOT = Path(__file__).resolve().parents[1]
MAX_MESSAGE = 2 * 1024 * 1024


class DAP:
    """Small bounded, synchronous DAP client with retained asynchronous events."""

    def __init__(self, connection, recorder):
        self.connection, self.recorder = connection, recorder
        self.buffer = b""
        self.sequence = 0
        self.pending = []
        self.runtime_info = None
        self.runtime_output = []
        self.metrics = []

    def send(self, command, **arguments):
        self.sequence += 1
        message = {"seq": self.sequence, "type": "request", "command": command, "arguments": arguments}
        data = json.dumps(message).encode()
        self.connection.sendall(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.recorder.emit("dap_request", message=message)
        return self.sequence

    def receive(self, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            if b"\r\n\r\n" in self.buffer:
                header, body = self.buffer.split(b"\r\n\r\n", 1)
                if len(header) > 4096:
                    raise ValueError("DAP header outside bounds")
                headers = {key.strip().lower(): value for key, value in (line.split(b":", 1) for line in header.split(b"\r\n"))}
                size = int(headers.get(b"content-length", b"-1").strip())
                if not 0 <= size <= MAX_MESSAGE:
                    raise ValueError("DAP message size outside bounds")
                if len(body) >= size:
                    self.buffer = body[size:]
                    message = json.loads(body[:size])
                    self.recorder.emit("dap_message", message=message)
                    if message.get("type") == "event" and message.get("event") == "output":
                        for line in message.get("body", {}).get("output", "").splitlines():
                            self.runtime_output.append(line)
                            if line.startswith("WORKBENCH_READY "):
                                self.runtime_info = json.loads(line.removeprefix("WORKBENCH_READY "))
                            elif line.startswith("WORKBENCH_METRICS "):
                                self.metrics.append(json.loads(line.removeprefix("WORKBENCH_METRICS ")))
                        if len(self.runtime_output) > 2000 or len(self.metrics) > 200:
                            raise RuntimeError("Runtime evidence limit exceeded")
                    return message
            elif len(self.buffer) > 4096:
                raise ValueError("DAP header outside bounds")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("DAP response deadline exceeded")
            self.connection.settimeout(remaining)
            chunk = self.connection.recv(65536)
            if not chunk:
                raise ConnectionError("DAP connection closed")
            self.buffer += chunk

    def wait(self, predicate, timeout=15):
        for index, message in enumerate(self.pending):
            if predicate(message):
                return self.pending.pop(index)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.receive(deadline - time.monotonic())
            if predicate(message):
                return message
            self.pending.append(message)
            if len(self.pending) > 500:
                raise RuntimeError("Too many unmatched DAP messages")
        raise TimeoutError("DAP event deadline exceeded")

    def response(self, sequence, timeout=15):
        response = self.wait(lambda m: m.get("type") == "response" and m.get("request_seq") == sequence, timeout)
        if not response.get("success"):
            raise RuntimeError(f"DAP request failed: {response}")
        return response.get("body", {})

    def request(self, command, **arguments):
        return self.response(self.send(command, **arguments))

    def event(self, name, timeout=15):
        return self.wait(lambda m: m.get("type") == "event" and m.get("event") == name, timeout).get("body", {})


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def connect(port_number, editor, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if editor.process.poll() is not None:
            raise RuntimeError("Editor exited before its debug adapter was ready")
        try:
            return socket.create_connection(("127.0.0.1", port_number), timeout=.2)
        except OSError:
            time.sleep(.05)
    raise TimeoutError("Editor debug adapter did not become ready")


def fixture(project, output):
    portable_release.stage(project, disable_file_logging=True)
    main = project / "main.gd"
    text = main.read_text()
    # Inject only into this temporary staged copy. The inspected functions remain unchanged.
    text = text.replace('var _debug_interval := 0.0', 'var _debug_interval := 0.25')
    text = text.replace("\t# Used by portable_release.py smoke:", "\tcall_deferred(\"_editor_probe\")\n\t# Used by portable_release.py smoke:")
    text += '''

func _editor_probe() -> void:
	Engine.max_fps = 60
	await get_tree().create_timer(1.0).timeout
	_request.text = "wear Blue Jacket; background Station"
	_apply()
	var before := commands.state.duplicate(true)
	print("EDITOR_PROBE_VALID " + JSON.stringify(before))
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(%s)
	await get_tree().create_timer(0.5).timeout
	_request.text = "wear Missing Jacket"
	_apply()
	print("EDITOR_PROBE_MISSING " + JSON.stringify({"state_unchanged": before == commands.state, "status": _status.text}))
	_debug_frame_ms.clear()
	_debug_frames = 0
	_debug_last_frame = Time.get_ticks_usec()
	_debug_window_start = _debug_last_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(%s)
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)
''' % (json.dumps(str(output / "workbench.png")), json.dumps(str(output / "missing.png")))
    main.write_text(text)
    # A fixture-local editor plugin permits bounded, graceful editor exit and app-only UI capture.
    addon = project / "addons/editor_probe"
    addon.mkdir(parents=True)
    (addon / "plugin.cfg").write_text('[plugin]\nname="Neutral debug fixture"\ndescription="Temporary local evidence"\nauthor="Workbench"\nversion="1"\nscript="plugin.gd"\n')
    (addon / "plugin.gd").write_text('''@tool
extends EditorPlugin
var capturing := false
func _enter_tree() -> void:
	call_deferred("_open_script")
func _open_script() -> void:
	EditorInterface.edit_script(load("res://main.gd"))
	await get_tree().process_frame
	await get_tree().process_frame
	print("EDITOR_FIXTURE_READY")
func _process(_delta: float) -> void:
	if FileAccess.file_exists(%s):
		get_tree().quit(0)
	if not capturing and FileAccess.file_exists(%s):
		capturing = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(%s)
''' % (json.dumps(str(output / "editor-stop")), json.dumps(str(output / "capture-editor")), json.dumps(str(output / "editor.png"))))
    with (project / "project.godot").open("a") as config:
        config.write('\n[editor_plugins]\nenabled=PackedStringArray("res://addons/editor_probe/plugin.cfg")\n')
    cache = project / ".godot/editor"
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "script_editor_cache.cfg").write_text('[res://main.gd]\nstate={}\nbreakpoints=[]\n')
    # Instrumentation adds a line before _apply; discover final locations rather than assuming offsets.
    text = main.read_text()
    apply_line = next(i for i, line in enumerate(text.splitlines(), 1) if line.strip() == "var proposal := commands.propose(_request.text)")
    result_line = next(i for i, line in enumerate(text.splitlines(), 1) if line.strip() == "_status.text = JSON.stringify(result)")
    return apply_line, result_line


def stack(dap):
    frames = dap.request("stackTrace", threadId=1).get("stackFrames", [])
    if not frames:
        raise AssertionError("Debugger returned no stack frames")
    return frames


def inspect(dap, frame):
    scopes = dap.request("scopes", frameId=frame["id"])["scopes"]
    # Godot sends the frame-variable dump asynchronously after the scopes response.
    time.sleep(.1)
    locals_ = next(scope for scope in scopes if scope["name"] == "Locals")
    variables = dap.request("variables", variablesReference=locals_["variablesReference"])["variables"]
    return {"frame": frame, "locals": variables}


def png_info(path):
    with path.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"Invalid rendered PNG: {path.name}")
    width, height = struct.unpack(">II", header[16:24])
    if width <= 0 or height <= 0:
        raise ValueError("Empty rendered image")
    return {"width": width, "height": height, "bytes": path.stat().st_size}


def pid_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run(godot, output):
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        raise RuntimeError("A graphical session is required; this milestone must not silently become headless")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Choose a new empty evidence directory")
    paths = [ROOT / "workbench" / name for name in portable_release.WORKBENCH]
    paths += [ROOT / "game/src/ext/loader" / name for name in portable_release.CORE]
    paths += [ROOT / "game/project.godot"]
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    summary = {"ok": False, "interaction": "real Godot editor DAP, not manual toolbar clicks"}
    with tempfile.TemporaryDirectory(prefix="neutral-editor-") as temp, dev_debug.Recorder(output / "events.jsonl") as recorder:
        root = Path(temp)
        project = root / "project"
        first_line, result_line = fixture(project, output)
        env = dict(os.environ)
        for key, name in {"HOME": "home", "USERPROFILE": "home", "XDG_DATA_HOME": "data",
                          "XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache", "APPDATA": "data", "LOCALAPPDATA": "data"}.items():
            (root / name).mkdir(exist_ok=True)
            env[key] = str(root / name)
        dap_port, debug_port, lsp_port = port(), port(), port()
        editor = None
        dap = None
        connection = None
        runtime_pid = None
        try:
            editor = dev_debug.ManagedProcess([godot, "--editor", "--path", str(project),
                       "--rendering-method", "gl_compatibility", "--audio-driver", "Dummy",
                       "--dap-port", str(dap_port), "--lsp-port", str(lsp_port),
                       "--debug-server", f"tcp://127.0.0.1:{debug_port}"], recorder, "editor", ROOT, env, False)
            deadline = time.monotonic() + 30
            while "EDITOR_FIXTURE_READY" not in (output / "events.jsonl").read_text():
                if editor.process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Editor fixture did not finish opening its script")
                time.sleep(.05)
            connection = connect(dap_port, editor)
            dap = DAP(connection, recorder)
            dap.request("initialize", adapterID="godot", linesStartAt1=True, columnsStartAt1=True,
                        supportsVariableType=True, pathFormat="path")
            dap.event("initialized")
            launch = dap.send("launch", project=str(project), noDebug=False, scene="main")
            breakpoints = dap.request("setBreakpoints", source={"path": str(project / "main.gd"), "name": "main.gd", "checksums": []},
                                      breakpoints=[{"line": first_line}, {"line": result_line}])
            if len(breakpoints.get("breakpoints", [])) != 2 or not all(b["verified"] for b in breakpoints["breakpoints"]):
                raise AssertionError("Editor did not verify the requested breakpoints")
            dap.request("configurationDone")
            dap.response(launch)
            process_event = dap.event("process")
            observations = []
            for label in ("valid", "missing"):
                stopped = dap.event("stopped")
                if dap.runtime_info:
                    runtime_pid = dap.runtime_info["pid"]
                frames = stack(dap)
                if frames[0]["name"] != "_apply" or frames[0]["line"] != first_line:
                    raise AssertionError(f"Expected _apply entry breakpoint, got {frames[0]}")
                entry = inspect(dap, frames[0])
                request_value = dap.request("evaluate", frameId=frames[0]["id"], expression="_request.text")
                state_before = dap.request("evaluate", frameId=frames[0]["id"], expression="commands.state")
                dap.request("stepIn", threadId=1)
                dap.event("stopped")
                step_frames = stack(dap)
                if step_frames[0]["name"] != "propose":
                    raise AssertionError(f"Step Into did not enter propose(): {step_frames[0]}")
                entered = inspect(dap, step_frames[0])
                if next(v["value"] for v in entered["locals"] if v["name"] == "text") != request_value["result"]:
                    raise AssertionError("Stepped function argument does not match the workbench request")
                dap.request("next", threadId=1)
                dap.event("stopped")
                over_frames = stack(dap)
                if over_frames[0]["name"] != "propose" or over_frames[0]["line"] <= step_frames[0]["line"]:
                    raise AssertionError("Step Over did not advance inside propose()")
                stepped_over = inspect(dap, over_frames[0])
                if label == "valid":
                    (output / "capture-editor").write_text("capture\n")
                dap.request("continue", threadId=1)
                dap.event("stopped")
                result_frames = stack(dap)
                if result_frames[0]["name"] != "_apply" or result_frames[0]["line"] != result_line:
                    raise AssertionError("Expected result-inspection breakpoint")
                result = inspect(dap, result_frames[0])
                state_after = dap.request("evaluate", frameId=result_frames[0]["id"], expression="commands.state")
                result_value = json.loads(next(v["value"] for v in result["locals"] if v["name"] == "result"))
                if label == "valid":
                    if not result_value.get("ok") or json.loads(state_after["result"])["slots"].get("outerwear") != "sample:blue-jacket":
                        raise AssertionError("Valid command was not applied")
                elif result_value.get("error") != "missing_asset" or json.loads(state_before["result"]) != json.loads(state_after["result"]):
                    raise AssertionError("Missing-asset command did not preserve previous state")
                observations.append({"case": label, "stopped": stopped, "entry": entry, "request": request_value,
                                     "state_before": state_before, "stepped_into": entered,
                                     "stepped_over": stepped_over, "result": result, "state_after": state_after})
                time.sleep(.1)
                dap.request("continue", threadId=1)
            dap.event("terminated", timeout=20)
            runtime_exit = dap.event("exited").get("exitCode")
            dap.request("disconnect", restart=False)
            connection.close()
            connection = None
            editor_code = editor.finish("completed", timeout=5, stop_file=output / "editor-stop")
            editor_errors = [json.loads(line).get("text") for line in (output / "events.jsonl").read_text().splitlines()
                             if json.loads(line).get("event") == "output" and json.loads(line).get("level") == "error"]
            images = {name: png_info(output / name) for name in ("workbench.png", "missing.png", "editor.png")}
            tail = dap.metrics[-3:]
            summary.update({"editor_exit": editor_code, "editor_pid": editor.process.pid,
                            "runtime_pid": runtime_pid, "runtime_exit": runtime_exit, "breakpoints": breakpoints,
                            "metrics": dap.metrics, "runtime_info": dap.runtime_info,
                            "editor_errors": editor_errors, "images": images,
                            "runtime_reaped": bool(runtime_pid) and not pid_exists(runtime_pid),
                            "rendered_tail_sample": {"windows": len(tail),
                                "observed_fps_range": [min(m["observed_fps"] for m in tail), max(m["observed_fps"] for m in tail)],
                                "frame_gap_mean_ms_range": [min(m["frame_gap_ms_mean"] for m in tail), max(m["frame_gap_ms_mean"] for m in tail)],
                                "engine_static_memory_bytes_range": [min(m["engine_static_memory_bytes"] for m in tail), max(m["engine_static_memory_bytes"] for m in tail)]},
                            "observations": observations, "original_sources_unchanged": all(
                                hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items())})
            if editor_code != 0 or runtime_exit != 0 or not runtime_pid or not summary["original_sources_unchanged"] \
                    or editor_errors or not summary["runtime_reaped"] or len(tail) < 3 \
                    or any(m["headless"] for m in tail) or dap.runtime_info["headless"] \
                    or not Path(dap.runtime_info["user_data_dir"]).is_relative_to(root):
                raise AssertionError("Editor cleanup, source preservation, or rendered capture failed")
            summary["ok"] = True
        except BaseException as exc:
            summary["failure"] = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            if connection is not None:
                connection.close()
            if editor is not None and editor.process.poll() is None:
                editor.finish("cleanup", timeout=3, stop_file=output / "editor-stop")
            if runtime_pid:
                try:
                    os.kill(runtime_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k not in ("observations", "metrics", "breakpoints", "runtime_info")}, indent=2))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--output", type=Path, required=True, help="new empty local evidence directory")
    args = parser.parse_args()
    run(args.godot, args.output.resolve())


if __name__ == "__main__":
    main()
