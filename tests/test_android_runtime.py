"""No emulator or game launch: validate runtime evidence gates and staged-only instrumentation."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    with mock.patch.object(sys, "path", [str(ROOT / "tools"), *sys.path]):
        spec.loader.exec_module(module)
    return module


runtime = load("android_runtime_check")
builder = load("android_runtime_preview")


def log(record, pid="1234"):
    return f"10-19 00:00:01.000  {pid}  4321 I godot : SDT_RUNTIME_PROBE " + json.dumps(record)


def ready_record(drawn):
    return {"main_scene": "res://scenes/main.tscn", "main_ready": True, "flash_stage_children": 2,
            "drawn_frames": drawn, "sdt_native_class": True, "swf_file_class": True,
            "extensions": ["res://bin/sdt_native.gdextension"]}


class AndroidRuntimeEvidence(unittest.TestCase):
    def test_signal_race_still_reaps_the_owned_child(self):
        child = mock.Mock(pid=1234)
        child.poll.return_value = None
        with mock.patch.object(runtime.os, "killpg", side_effect=ProcessLookupError()):
            runtime.stop(child)
        child.wait.assert_called_once_with(timeout=15)

    def test_exited_child_is_reaped_without_signaling_any_group(self):
        child = mock.Mock(pid=1234)
        child.poll.return_value = 0
        with mock.patch.object(runtime.os, "killpg") as kill:
            runtime.stop(child)
        kill.assert_not_called()
        child.wait.assert_called_once_with(timeout=15)

    def test_process_presence_is_not_readiness_or_rendering(self):
        result = runtime.analyze_log("10-19 00:00:01.000  1234  1234 I Godot : Initialized", {"1234"})
        for key in ("main_scene_ready_verified", "native_extension_verified", "rendered_frames_advancing_verified"):
            self.assertFalse(result[key])

    def test_success_requires_real_scene_native_classes_and_advancing_draws(self):
        result = runtime.analyze_log(log(ready_record(10)) + "\n" + log(ready_record(80)), {"1234"})
        for key in ("main_scene_ready_verified", "native_extension_verified", "rendered_frames_advancing_verified"):
            self.assertTrue(result[key])

    def test_exact_pid_fields_ignore_number_matches_and_other_system_errors(self):
        text = "10-19 00:00:01.000  9912  1234 E System : ERROR: request 1234\n"
        text += log(ready_record(10), "12340")
        result = runtime.analyze_log(text, {"1234"})
        self.assertEqual(result["app_log_lines"], 0)
        self.assertFalse(result["native_extension_verified"])
        self.assertEqual(result["app_errors"], [])

    def test_stalled_or_zero_draw_count_does_not_pass(self):
        for first, last in ((0, 80), (10, 10), (80, 10)):
            result = runtime.analyze_log(log(ready_record(first)) + "\n" + log(ready_record(last)), {"1234"})
            self.assertFalse(result["rendered_frames_advancing_verified"])

    def test_autoload_or_neutral_workbench_does_not_count_as_game(self):
        for scene in ("", "res://main.tscn"):
            record = ready_record(10)
            record["main_scene"] = scene
            result = runtime.analyze_log(log(record), {"1234"})
            self.assertFalse(result["main_scene_ready_verified"])

    def test_missing_native_class_cannot_pass(self):
        record = ready_record(10)
        record["swf_file_class"] = False
        result = runtime.analyze_log(log(record), {"1234"})
        self.assertTrue(result["main_scene_ready_verified"])
        self.assertFalse(result["native_extension_verified"])

    def test_app_errors_are_retained_and_malformed_probe_ignored(self):
        text = "10-19 00:00:01.000  1234  1234 E godot : ERROR: No GDExtension library found\n"
        text += "10-19 00:00:01.000  1234  1234 I godot : SDT_RUNTIME_PROBE {bad json}\n" + log([])
        result = runtime.analyze_log(text, {"1234"})
        self.assertEqual(len(result["app_errors"]), 1)
        self.assertEqual(result["probes"], [])

    def test_observer_configuration_preserves_main_scene_and_other_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp)
            (project / "project.godot").write_text('config_version=5\n[application]\nrun/main_scene="res://scenes/main.tscn"\n[autoload]\nFlash="*res://flash/flash_runtime.gd"\n[rendering]\ncustom/keep=true\n')
            report = builder.configure_observer(project)
            text = (project / "project.godot").read_text()
            self.assertIn('run/main_scene="res://scenes/main.tscn"', text)
            self.assertIn('Flash="*res://flash/flash_runtime.gd"', text)
            self.assertIn("custom/keep=true", text)
            self.assertNotIn("limits/opengl/", text)
            self.assertTrue(report["read_only"])
            self.assertEqual((project / report["path"]).read_bytes(), (ROOT / "tools/fixtures/android_runtime_probe.gd").read_bytes())
            with self.assertRaises(ValueError):
                builder.configure_observer(project)


if __name__ == "__main__":
    unittest.main()
