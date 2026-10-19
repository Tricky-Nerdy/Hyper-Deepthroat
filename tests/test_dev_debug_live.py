"""Opt-in end-to-end neutral Godot supervisor check. All edits/saves are temporary.

LIVE_GODOT_DEBUG=1 DEV_DEBUG_EVIDENCE_DIR=/tmp/debug-evidence python3 -m unittest discover \
    -s tests -p 'test_dev_debug_live.py' -v
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("live_portable_release", ROOT / "tools/portable_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def events_at(path):
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return []
    events = []
    for line in lines:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # The supervisor may currently be appending the last line.
    return events


@unittest.skipUnless(os.environ.get("LIVE_GODOT_DEBUG") == "1" and os.name == "posix",
                     "opt in to the actual POSIX Godot lifecycle check with LIVE_GODOT_DEBUG=1")
class LiveWorkbenchDebug(unittest.TestCase):
    def wait_for(self, driver, log, predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            events = events_at(log)
            result = predicate(events)
            if result:
                return result
            if driver.poll() is not None:
                self.fail(f"Supervisor exited early ({driver.returncode}): {events[-12:]}")
            time.sleep(.025)
        self.fail(f"Timed out waiting for live workbench: {events_at(log)[-12:]}")

    def test_start_debounced_reload_prepare_recovery_and_clean_shutdown(self):
        godot = shutil.which(os.environ.get("GODOT", "godot"))
        self.assertIsNotNone(godot, "Godot executable is required for the opted-in live check")
        originals = [ROOT / "workbench" / name for name in release.WORKBENCH]
        originals += [ROOT / "game/src/ext/loader" / name for name in release.CORE]
        originals += [ROOT / "game/project.godot"]
        original_hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in originals}
        summary = {"ok": False}
        with tempfile.TemporaryDirectory(prefix="workbench-debug-live-") as directory:
            root = Path(directory)
            source, output = root / "source", root / "debug"
            for path in originals[:-1] + [ROOT / "LICENSE"]:
                destination = source / path.relative_to(ROOT)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
            main = source / "workbench/main.gd"
            original_main = main.read_text()
            log = output / "events.jsonl"
            command = [sys.executable, "-W", "error::ResourceWarning", str(ROOT / "tools/dev_debug.py"),
                       "--godot", godot, "--source-root", str(source), "--output", str(output),
                       "--headless", "--poll", ".03", "--debounce", ".12", "--backoff", ".2",
                       "--telemetry-interval", ".2"]

            def starts(events):
                return [e for e in events if e["event"] == "started"]

            with subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True) as driver:
                try:
                    first = self.wait_for(driver, log, lambda es: starts(es)[0] if starts(es) else None)
                    self.wait_for(driver, log, lambda es: any(e["event"] == "engine_metrics" and e["pid"] == first["pid"]
                                                            and e["monotonic"] - first["monotonic"] >= 1.2
                                                            and e["metrics"]["engine_fps"] > 0 for e in es))
                    for version in (1, 2, 3):
                        pending = main.with_suffix(".gd.tmp")
                        pending.write_text(original_main.replace("func _ready() -> void:\n",
                                           f'func _ready() -> void:\n\tprint("WORKBENCH_FIXTURE version-{version}")\n', 1))
                        pending.replace(main)
                        time.sleep(.025)
                    second = self.wait_for(driver, log, lambda es: starts(es)[1] if len(starts(es)) >= 2 else None)
                    self.wait_for(driver, log, lambda es: any(e.get("text") == "WORKBENCH_FIXTURE version-3" and e.get("pid") == second["pid"] for e in es))
                    self.wait_for(driver, log, lambda es: any(e["event"] == "engine_metrics" and e["pid"] == second["pid"] for e in es))
                    self.assertEqual(len(starts(events_at(log))), 2, "one atomic-save burst must cause one process reload")

                    staged_main = output / "portable/project/main.gd"
                    good_stage = staged_main.read_bytes()
                    main.unlink()
                    self.wait_for(driver, log, lambda es: any(e["event"] == "prepare" and e["exit_code"] != 0 for e in es))
                    self.assertEqual(staged_main.read_bytes(), good_stage, "failed staging must preserve the previous complete project")
                    main.write_text(original_main.replace("func _ready() -> void:\n",
                                    'func _ready() -> void:\n\tprint("WORKBENCH_FIXTURE recovered")\n', 1))
                    third = self.wait_for(driver, log, lambda es: starts(es)[2] if len(starts(es)) >= 3 else None)
                    self.wait_for(driver, log, lambda es: any(e.get("text") == "WORKBENCH_FIXTURE recovered" and e.get("pid") == third["pid"] for e in es))
                    self.wait_for(driver, log, lambda es: any(e["event"] == "engine_metrics" and e["pid"] == third["pid"] for e in es))
                    stop_started = time.monotonic()
                    driver.send_signal(signal.SIGTERM)
                    _, stderr = driver.communicate(timeout=5)
                    shutdown_seconds = time.monotonic() - stop_started
                    self.assertEqual(driver.returncode, 0, stderr)
                    self.assertNotIn("ResourceWarning", stderr)
                    events = events_at(log)
                    runtime_stops = [e for e in events if e["event"] == "child_stopped" and e["phase"] == "runtime"]
                    self.assertEqual(len(runtime_stops), 3)
                    self.assertTrue(all(e["exit_code"] == 0 and not e["reader_alive"] for e in runtime_stops))
                    self.assertEqual(events[-1]["event"], "stopped")
                    self.assertEqual(sum(e["event"] == "source_reload" for e in events), 2)
                    self.assertFalse(any(e.get("level") == "error" and e.get("phase") == "runtime" for e in events))
                    ready = [json.loads(e["text"].removeprefix("WORKBENCH_READY ")) for e in events
                             if e.get("text", "").startswith("WORKBENCH_READY ")]
                    self.assertEqual(len(ready), 3)
                    self.assertTrue(all(Path(e["user_data_dir"]).is_relative_to(output) for e in ready))
                    self.assertFalse(any((output / "user-data").rglob("*.log")), "engine logs must not bypass bounded JSONL capture")
                    metrics = [e["metrics"] for e in events if e["event"] == "engine_metrics"]
                    warm_metrics = [e["metrics"] for e in events if e["event"] == "engine_metrics" and e["pid"] == first["pid"]
                                    and e["monotonic"] - first["monotonic"] >= 1.2]
                    self.assertTrue(all(m["headless"] and m["observed_fps"] > 0 and m["engine_static_memory_bytes"] > 0 for m in metrics))
                    self.assertTrue(all(not e["reader_alive"] for e in events if e["event"] == "child_stopped"))
                    for pid in [e["pid"] for e in starts(events)]:
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)
                    self.assertTrue(all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in original_hashes.items()))
                    summary = {"ok": True, "scope": "temporary neutral workbench fixture", "mode": "headless",
                               "engine": subprocess.run([godot, "--version"], capture_output=True, text=True, check=True).stdout.strip(),
                               "runtime_starts": len(starts(events)), "source_reloads": 2,
                               "failed_preparations": sum(e["event"] == "prepare" and e["exit_code"] != 0 for e in events),
                               "supervisor_exit": driver.returncode, "runtime_exit_codes": [e["exit_code"] for e in runtime_stops],
                               "shutdown_seconds": shutdown_seconds, "readers_joined": True, "runtime_pids_reaped": True,
                               "original_sources_unchanged": True, "save_paths_isolated": True,
                               "engine_metric_windows": len(metrics),
                               "observed_fps_range": [min(m["observed_fps"] for m in metrics), max(m["observed_fps"] for m in metrics)],
                               "warm_engine_fps_range": [min(m["engine_fps"] for m in warm_metrics), max(m["engine_fps"] for m in warm_metrics)],
                               "warm_observed_fps_range": [min(m["observed_fps"] for m in warm_metrics), max(m["observed_fps"] for m in warm_metrics)],
                               "frame_gap_mean_ms_range": [min(m["frame_gap_ms_mean"] for m in metrics), max(m["frame_gap_ms_mean"] for m in metrics)],
                               "engine_static_memory_bytes_range": [min(m["engine_static_memory_bytes"] for m in metrics), max(m["engine_static_memory_bytes"] for m in metrics)]}
                finally:
                    if driver.poll() is None:
                        driver.terminate()
                        try:
                            driver.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            driver.kill()
                            driver.communicate()
                    if os.environ.get("DEV_DEBUG_EVIDENCE_DIR"):
                        evidence = Path(os.environ["DEV_DEBUG_EVIDENCE_DIR"])
                        evidence.mkdir(parents=True, exist_ok=True)
                        if log.exists():
                            shutil.copyfile(log, evidence / "events.jsonl")
                        (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            print("LIVE WORKBENCH: " + json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
