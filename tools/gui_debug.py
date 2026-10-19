#!/usr/bin/env python3
"""Guarded real keyboard GUI check for the neutral workbench on Hyprland's Lua API.

Uses compositor key events, not DAP, Input.parse_input_event, button.emit_signal, or handler calls.
Only temporary staged sources/user data are used. Observer instrumentation is read-only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

import dev_debug
import editor_debug
import portable_release

ROOT = Path(__file__).resolve().parents[1]


def shell(command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=5)
    if result.returncode or result.stdout.lstrip().lower().startswith("error:"):
        raise RuntimeError(f"Local UI command failed: {result.stdout} {result.stderr}")
    return result.stdout.strip()


def key_lua(address, pid, key, mods, state):
    if not re.fullmatch(r"0x[0-9a-fA-F]+", address) or type(pid) is not int or pid <= 0:
        raise ValueError("Invalid owned-window identity")
    if key not in {"Tab", "space", "BackSpace", "Return", "semicolon"} and not re.fullmatch(r"[a-z0-9]", key):
        raise ValueError("Unsupported GUI test key")
    if mods not in ("", "CTRL", "SHIFT") or state not in ("down", "up"):
        raise ValueError("Invalid explicit key state")
    selector = json.dumps("address:" + address)
    guard = (f"local w=hl.get_window({selector}); assert(w and w.pid=={pid},'OWNED_WINDOW_MISSING'); ")
    if state == "down":
        guard += (f"local a=hl.get_active_window(); assert(a and a.address==w.address and a.pid=={pid},'FOCUS_CHANGED'); ")
    return guard + "hl.dispatch(hl.dsp.send_key_state({mods=%s,key=%s,state=%s,window=%s}))" % (
        json.dumps(mods), json.dumps(key), json.dumps(state), selector)


def owned_window(clients, pid):
    found = [w for w in clients if w.get("pid") == pid and w.get("mapped") and not w.get("hidden")]
    if len(found) != 1 or not re.fullmatch(r"0x[0-9a-fA-F]+", found[0].get("address", "")):
        raise RuntimeError("Expected exactly one mapped window for the owned workbench process")
    return found[0]


def snapshot(path, pid, timeout=5, predicate=lambda s: True, process=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process is not None and (process.process.poll() is not None or process.error.is_set()):
            raise RuntimeError("Workbench exited or logged an engine error during GUI check")
        try:
            data = json.loads(path.read_text())
            if data.get("pid") == pid and predicate(data):
                return data
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.025)
    raise TimeoutError("GUI observation did not reach the expected state")


class Keyboard:
    def __init__(self, window, recorder):
        self.address, self.pid = window["address"], window["pid"]
        self.recorder = recorder

    def focus(self):
        selector = json.dumps("address:" + self.address)
        shell(["hyprctl", "eval", f"local w=hl.get_window({selector}); assert(w and w.pid=={self.pid}); hl.dispatch(hl.dsp.focus({{window={selector}}}))"])
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            active = json.loads(shell(["hyprctl", "-j", "activewindow"]))
            if active.get("address") == self.address and active.get("pid") == self.pid:
                self.recorder.emit("gui_focus", address=self.address, pid=self.pid)
                return
            time.sleep(.025)
        raise RuntimeError("Owned workbench window did not gain focus")

    def press(self, key, mods=""):
        shell(["hyprctl", "eval", key_lua(self.address, self.pid, key, mods, "down")])
        try:
            self.recorder.emit("gui_key", address=self.address, pid=self.pid, key=key, mods=mods, state="down")
            time.sleep(.05)
        finally:
            # Release to the same owned window even if another surface gained focus in the meantime.
            shell(["hyprctl", "eval", key_lua(self.address, self.pid, key, mods, "up")])
            self.recorder.emit("gui_key", address=self.address, pid=self.pid, key=key, mods=mods, state="up")
        time.sleep(.025)

    def focus_control(self, name, observe):
        for _ in range(24):
            if observe()["focus"] == name:
                return
            self.press("Tab")
        raise RuntimeError(f"Keyboard navigation did not reach {name}")

    def type_request(self, text, observe):
        if not re.fullmatch(r"[a-z0-9 ;]+", text):
            raise ValueError("Use a lowercase neutral fixture request")
        self.focus_control("request", observe)
        self.press("a", "CTRL")
        self.press("BackSpace")
        for character in text:
            self.press({" ": "space", ";": "semicolon"}.get(character, character))


def fixture(project):
    portable_release.stage(project, disable_file_logging=True)
    portable_release.copy(ROOT / "tools/fixtures/gui_observer.gd", project / "gui_observer.gd")
    scene = project / "main.tscn"
    text = scene.read_text().replace("load_steps=2", "load_steps=3", 1)
    text = text.replace('[node name="Workbench"', '[ext_resource type="Script" path="res://gui_observer.gd" id="2"]\n\n[node name="Workbench"', 1)
    text += '\n[node name="GuiObserver" type="Node" parent="."]\nscript = ExtResource("2")\n'
    scene.write_text(text)


def isolated_save_path(observation, root):
    path = Path(observation["save_path"]).resolve()
    if not path.is_relative_to(root.resolve()) or path.name != "workbench.json":
        raise ValueError("Engine save path is outside the isolated fixture")
    return path


def run(godot, output):
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        raise RuntimeError("This real-GUI check requires the local Hyprland session")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Choose a new empty evidence directory")
    paths = [ROOT / "workbench" / name for name in portable_release.WORKBENCH]
    paths += [ROOT / "game/src/ext/loader" / name for name in portable_release.CORE]
    paths += [ROOT / "game/project.godot"]
    hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    initial_active = json.loads(shell(["hyprctl", "-j", "activewindow"]))
    prior_focus = {k: initial_active.get(k) for k in ("address", "pid")}
    summary = {"ok": False, "input_method": "Hyprland Lua explicit-modifier key down/up; real GUI focus/navigation"}
    results = []
    codes = []
    with tempfile.TemporaryDirectory(prefix="neutral-gui-") as temp, dev_debug.Recorder(output / "events.jsonl") as recorder:
        root = Path(temp)
        project = root / "project"
        fixture(project)
        env = dict(os.environ, NEUTRAL_GUI_EVIDENCE=str(output))
        for key, name in {"HOME": "home", "USERPROFILE": "home", "XDG_DATA_HOME": "data",
                          "XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache", "APPDATA": "data", "LOCALAPPDATA": "data"}.items():
            (root / name).mkdir(exist_ok=True)
            env[key] = str(root / name)
        child = None
        stops = []

        def launch(session):
            stop_file = output / f"stop-{session}"
            child_env = dict(env, NEUTRAL_GUI_SESSION=session)
            managed = dev_debug.ManagedProcess([godot, "--path", str(project), "--max-fps", "60",
                       "--audio-driver", "Dummy", "--", "--debug-telemetry=0.5", f"--debug-stop-file={stop_file}"],
                       recorder, "runtime", ROOT, child_env, False)
            stops.append((managed, stop_file))
            observation_path = output / f"snapshot-{session}.json"

            def observe(predicate=lambda s: True):
                return snapshot(observation_path, managed.process.pid, predicate=predicate, process=managed)

            first = observe()
            if first["headless"]:
                raise AssertionError("Actual rendered GUI required")
            deadline = time.monotonic() + 5
            while True:
                try:
                    window = owned_window(json.loads(shell(["hyprctl", "-j", "clients"])), managed.process.pid)
                    break
                except RuntimeError:
                    if time.monotonic() > deadline:
                        raise
                    time.sleep(.05)
            keyboard = Keyboard(window, recorder)
            keyboard.focus()
            recorder.emit("gui_session", session=session, address=window["address"], pid=managed.process.pid)
            return managed, stop_file, observe, keyboard

        def record(name, observation):
            results.append({"case": name, "snapshot": observation})
            recorder.emit("gui_check", case=name, selection=observation["selection"], status=observation["status"],
                          action_count=observation["action_count"], input_count=observation["input_count"])

        def press_button(label, observe, keyboard):
            previous = observe()["action_count"]
            keyboard.focus_control(label, observe)
            keyboard.press("space")
            after = observe(lambda s: s["action_count"] > previous)
            if after["actions"][-1]["button"] != label:
                raise AssertionError("The wrong GUI control received the input")
            return after

        def capture(name, session, observe):
            request = output / "capture-request.json"
            pending = request.with_suffix(".tmp")
            pending.write_text(json.dumps({"name": name, "session": session}))
            pending.replace(request)
            observe(lambda s: s["last_capture"] == name)
            return editor_debug.png_info(output / (name + ".png"))

        try:
            child, stop_file, observe, keyboard = launch("1")
            initial = observe()
            save_path = isolated_save_path(initial, root)
            if initial["selection"]["slots"] or save_path.exists():
                raise AssertionError("GUI fixture did not start with fresh selection/save data")
            applied = press_button("Apply", observe, keyboard)
            if applied["selection"]["slots"] != {"outerwear": "sample:blue-jacket", "background": "sample:station"}:
                raise AssertionError("GUI Apply did not select the requested assets")
            record("apply", applied)
            capture("applied", "1", observe)
            undone = press_button("Undo", observe, keyboard)
            if undone["selection"] != initial["selection"] or undone["status"] != "Selection undone.":
                raise AssertionError("GUI Undo did not restore the previous selection")
            record("undo", undone)
            capture("undone", "1", observe)
            empty_undo = press_button("Undo", observe, keyboard)
            if empty_undo["selection"] != initial["selection"] or empty_undo["status"] != "Nothing to undo.":
                raise AssertionError("Empty GUI undo did not preserve state and report its result")
            record("empty_undo", empty_undo)
            keyboard.type_request("wear gold jacket; background garden", observe)
            observe(lambda s: s["request"] == "wear gold jacket; background garden")
            selected = press_button("Apply", observe, keyboard)
            expected = {"outerwear": "sample:gold-jacket", "background": "sample:garden"}
            if selected["selection"]["slots"] != expected:
                raise AssertionError("Typed GUI request was not applied")
            saved = press_button("Save", observe, keyboard)
            if saved["status"] != "Saved locally." or not save_path.exists():
                raise AssertionError(f"GUI Save failed: {saved['status']}")
            good_bytes = save_path.read_bytes()
            good_save = json.loads(good_bytes)
            if good_save["assets"] != selected["selection"] or good_save["story"] != selected["story"]:
                raise AssertionError("GUI save contents differ from visible/runtime state")
            record("save", saved)
            capture("saved", "1", observe)
            codes.append(child.finish("restart", timeout=2, stop_file=stop_file))
            child = None

            child, stop_file, observe, keyboard = launch("2")
            restarted = observe()
            if restarted["selection"]["slots"] or isolated_save_path(restarted, root) != save_path or save_path.read_bytes() != good_bytes:
                raise AssertionError("Restart did not preserve the isolated save and reset transient state")
            loaded = press_button("Load", observe, keyboard)
            if loaded["selection"] != good_save["assets"] or loaded["story"] != good_save["story"] or not loaded["status"].startswith("Restored."):
                raise AssertionError("GUI Load did not restore the saved configuration across restart")
            record("load_after_restart", loaded)
            capture("loaded", "2", observe)

            for name, invalid in (("malformed", b'{"schema":'), ("incompatible", None)):
                before = observe()
                if name == "incompatible":
                    bad = json.loads(good_bytes)
                    bad["assets"]["slots"] = {"outerwear": "sample:blue-jacket", "background": "sample:station"}
                    bad["story"]["document_digest"] = "incompatible-fixture"
                    invalid = json.dumps(bad).encode()
                save_path.write_bytes(invalid)
                after = press_button("Load", observe, keyboard)
                if after["selection"] != before["selection"] or after["story"] != before["story"] or after["undo_count"] != before["undo_count"]:
                    raise AssertionError("Invalid GUI load changed live state")
                expected_error = "invalid_json" if name == "malformed" else "Incompatible save:"
                if expected_error not in after["status"]:
                    raise AssertionError("Invalid GUI load did not display the expected error")
                record(name + "_rejected", after)
                capture(name, "2", observe)
            save_path.write_bytes(good_bytes)
            recovered = press_button("Load", observe, keyboard)
            if recovered["selection"] != good_save["assets"] or not recovered["status"].startswith("Restored."):
                raise AssertionError("GUI did not recover after invalid saves")
            record("valid_load_recovery", recovered)
            codes.append(child.finish("completed", timeout=2, stop_file=stop_file))
            child = None
            engine_errors = [json.loads(line).get("text") for line in (output / "events.jsonl").read_text().splitlines()
                             if json.loads(line).get("event") == "output" and json.loads(line).get("level") == "error"]
            if any(code != 0 for code in codes) or any(editor_debug.pid_exists(p.process.pid) or p.reader.is_alive() for p, _ in stops):
                raise AssertionError("GUI runtime/reader cleanup failed")
            if engine_errors or any(p.error.is_set() for p, _ in stops):
                raise AssertionError("Engine reported an error during the GUI milestone")
            if not all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in hashes.items()):
                raise AssertionError("Original source changed during GUI fixture run")
            if not recovered["input_count"] or any(i["meta"] for case in results for i in case["snapshot"]["inputs"]):
                raise AssertionError("GUI input evidence is absent or unexpected SUPER modifiers reached the fixture")
            summary.update({"ok": True, "cases": results, "runtime_pids": [p.process.pid for p, _ in stops],
                            "runtime_exits": codes, "runtime_pids_reaped": True, "readers_joined": True,
                            "save_paths_isolated": True, "save_round_trip": True, "original_sources_unchanged": True,
                            "engine_errors": engine_errors,
                            "images": {name: editor_debug.png_info(output / (name + ".png")) for name in ("applied", "undone", "saved", "loaded", "malformed", "incompatible")}})
        except BaseException as exc:
            summary["failure"] = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            for managed, stop_file in stops:
                if managed.process.poll() is None:
                    managed.finish("cleanup", timeout=2, stop_file=stop_file)
            if prior_focus.get("address") and prior_focus.get("pid"):
                selector = json.dumps("address:" + prior_focus["address"])
                shell(["hyprctl", "eval", f"local w=hl.get_window({selector}); if w and w.pid=={int(prior_focus['pid'])} then hl.dispatch(hl.dsp.focus({{window={selector}}})) end"])
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "cases"}, indent=2))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--output", type=Path, required=True, help="new empty local evidence directory")
    args = parser.parse_args()
    run(args.godot, args.output.resolve())


if __name__ == "__main__":
    main()
