import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("dev_debug", Path(__file__).resolve().parents[1] / "tools/dev_debug.py")
debug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(debug)
release_spec = importlib.util.spec_from_file_location("debug_portable_release", Path(__file__).resolve().parents[1] / "tools/portable_release.py")
release = importlib.util.module_from_spec(release_spec)
release_spec.loader.exec_module(release)


class EventRecorder(debug.Recorder):
    def __init__(self, path):
        super().__init__(path)
        self.events = []
        self.condition = threading.Condition()

    def emit(self, event, **fields):
        super().emit(event, **fields)
        with self.condition:
            self.events.append(dict(event=event, **fields))
            self.condition.notify_all()

    def wait_for(self, event, predicate=lambda e: True, count=1, timeout=5):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                found = [e for e in self.events if e["event"] == event and predicate(e)]
                if len(found) >= count:
                    return found[-1]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"Timed out waiting for {event}: {self.events}")
                self.condition.wait(remaining)


class Session:
    def __init__(self, root, script, *, paths=(), prepare=None, **options):
        self.recorder = EventRecorder(root / "events.jsonl")
        self.stop = threading.Event()
        self.result = []
        self.errors = []
        settings = dict(interval=.01, debounce=.08, backoff=.02, max_backoff=.05,
                        shutdown_timeout=.15, echo=False)
        settings.update(options)

        def run():
            try:
                self.result.append(debug.supervise([sys.executable, "-c", script], paths, self.recorder,
                                                  prepare=prepare, stop_event=self.stop, **settings))
            except BaseException as exc:
                self.errors.append(exc)
        self.thread = threading.Thread(target=run, name="test-supervisor")

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.stop.set()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise AssertionError("Supervisor did not terminate")
        self.recorder.close()
        if self.errors:
            raise self.errors[0]
        if any(t.name.startswith("dev-debug-output-") for t in threading.enumerate()):
            raise AssertionError("Output reader leaked after shutdown")

class DebugTests(unittest.TestCase):
    def test_fingerprint_detects_edit_delete_and_ignores_import_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "main.gd"
            path.write_text("a")
            first = debug.fingerprint([root])
            path.write_text("b")
            self.assertNotEqual(first, debug.fingerprint([root]))
            cache = root / ".godot"
            cache.mkdir()
            (cache / "cache.gd").write_text("ignored")
            self.assertEqual(len(debug.fingerprint([root])), 1)
            path.unlink()
            self.assertEqual(debug.fingerprint([root]), {})

    def run_child(self, script, limit):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            recorder = debug.Recorder(path)
            try:
                result = debug.supervise([sys.executable, "-c", script], [], recorder,
                                          max_restarts=limit, interval=.02)
            finally:
                recorder.close()
            return result, [json.loads(line) for line in path.read_text().splitlines()]

    def test_clean_exit_is_not_restarted_and_captures_output(self):
        result, events = self.run_child("print('hello')", 2)
        self.assertEqual(result, 0)
        self.assertEqual(sum(e["event"] == "started" for e in events), 1)
        self.assertTrue(any(e.get("text") == "hello" for e in events))

    def test_crash_restart_is_bounded(self):
        result, events = self.run_child("raise SystemExit(7)", 1)
        self.assertEqual(result, 7)
        self.assertEqual(sum(e["event"] == "started" for e in events), 2)
        self.assertTrue(any(e["event"] == "restart_limit" for e in events))

    def test_watched_read_race_retries_then_detects_stable_deletion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "main.gd"
            path.write_text("before")
            before = debug.fingerprint([root])
            original = Path.read_bytes

            def removed_during_read(candidate):
                if candidate == path:
                    candidate.unlink()
                    raise FileNotFoundError("atomic-save gap")
                return original(candidate)

            with mock.patch.object(Path, "read_bytes", removed_during_read):
                self.assertEqual(debug.fingerprint([root], before), before)
            self.assertEqual(debug.fingerprint([root], before), {})
            root.rmdir()
            self.assertEqual(debug.fingerprint([root], before), {})

    def test_atomic_save_burst_is_one_debounced_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "main.gd"
            source.write_text("version-0")
            script = f"from pathlib import Path; import time; print(Path({str(source)!r}).read_text(), flush=True); time.sleep(30)"
            with Session(root, script, paths=[root]) as session:
                session.recorder.wait_for("started")
                for version in (1, 2, 3):
                    pending = root / "main.gd.tmp"
                    pending.write_text(f"version-{version}")
                    pending.replace(source)
                    time.sleep(.025)
                session.recorder.wait_for("started", count=2)
                session.recorder.wait_for("output", lambda e: e.get("text") == "version-3")
                time.sleep(.15)
                events = session.recorder.events
                self.assertEqual(sum(e["event"] == "source_reload" for e in events), 1)
                self.assertEqual(sum(e["event"] == "started" for e in events), 2)
            self.assertEqual(session.result, [0])

    def test_failed_preparation_recovers_before_runtime_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            counter = root / "attempts"
            script = (f"from pathlib import Path; p=Path({str(counter)!r}); "
                      "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1)); raise SystemExit(8 if n == 0 else 0)")
            with Session(root, "import time; time.sleep(30)", prepare=[sys.executable, "-c", script]) as session:
                session.recorder.wait_for("started")
                prepares = [e["exit_code"] for e in session.recorder.events if e["event"] == "prepare"]
                self.assertEqual(prepares, [8, 0])
                self.assertEqual(counter.read_text(), "2")
            self.assertEqual(session.result, [0])

    def test_failed_preparation_has_a_session_retry_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            with Session(Path(directory), "raise SystemExit(0)", max_restarts=2,
                         prepare=[sys.executable, "-c", "raise SystemExit(9)"]) as session:
                session.recorder.wait_for("restart_limit")
                session.thread.join(timeout=2)
                self.assertEqual(session.result, [9])
                self.assertEqual(sum(e["event"] == "prepare_started" for e in session.recorder.events), 3)
                self.assertFalse(any(e["event"] == "started" for e in session.recorder.events))

    def test_stop_interrupts_preparation_without_launching_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            with Session(Path(directory), "raise SystemExit(99)",
                         prepare=[sys.executable, "-c", "import time; time.sleep(30)"]) as session:
                session.recorder.wait_for("prepare_started")
                start = time.monotonic()
                session.stop.set()
                session.thread.join(timeout=2)
                self.assertFalse(session.thread.is_alive())
                self.assertLess(time.monotonic() - start, 2)
                self.assertFalse(any(e["event"] == "started" for e in session.recorder.events))
            self.assertEqual(session.result, [0])

    def test_stop_interrupts_backoff_without_another_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            with Session(Path(directory), "raise SystemExit(7)", backoff=30, max_backoff=30) as session:
                session.recorder.wait_for("restarting")
                session.stop.set()
                session.thread.join(timeout=2)
                self.assertFalse(session.thread.is_alive())
                self.assertEqual(sum(e["event"] == "started" for e in session.recorder.events), 1)
            self.assertEqual(session.result, [0])

    def test_error_output_cannot_pass_as_a_successful_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            with Session(Path(directory), "print('ERROR: neutral fixture')", max_restarts=0) as session:
                session.recorder.wait_for("restart_limit")
                session.thread.join(timeout=2)
                self.assertNotEqual(session.result, [0])
                self.assertTrue(any(e.get("output_error") for e in session.recorder.events))

    def test_source_change_cannot_hide_a_runtime_error_or_reset_its_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "main.gd"
            source.write_text("original")
            original_emit = EventRecorder.emit

            def edit_on_error(recorder, event, **fields):
                if event == "output" and fields.get("text") == "ERROR: edit fixture":
                    source.write_text("changed")
                original_emit(recorder, event, **fields)

            with mock.patch.object(EventRecorder, "emit", edit_on_error):
                with Session(root, "print('ERROR: edit fixture')", paths=[root], debounce=0, max_restarts=0) as session:
                    session.recorder.wait_for("restart_limit")
                    session.thread.join(timeout=2)
                    self.assertEqual(sum(e["event"] == "started" for e in session.recorder.events), 1)
                    self.assertNotEqual(session.result, [0])

    def test_missing_executable_exits_nonzero_without_a_leaked_reader(self):
        with tempfile.TemporaryDirectory() as directory:
            with debug.Recorder(Path(directory) / "events.jsonl") as recorder:
                code = debug.supervise([str(Path(directory) / "absent-engine")], [], recorder,
                                       max_restarts=0, interval=.01, echo=False)
            self.assertEqual(code, 127)
            self.assertFalse(any(t.name.startswith("dev-debug-output-") for t in threading.enumerate()))

    def test_preparation_timeout_is_nonzero_and_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            with Session(Path(directory), "raise SystemExit(0)", max_restarts=0, prepare_timeout=.08,
                         prepare=[sys.executable, "-c", "import time; time.sleep(30)"]) as session:
                session.recorder.wait_for("restart_limit")
                session.thread.join(timeout=2)
                self.assertEqual(session.result, [124])

    def test_log_rotation_bounds_bytes_files_and_oversized_records(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with debug.Recorder(root / "events.jsonl", max_bytes=1024, backups=2) as recorder:
                for i in range(40):
                    recorder.emit("output", text="x" * 10000, sequence=i)
            logs = list(root.iterdir())
            self.assertLessEqual(len(logs), 3)
            self.assertTrue(all(p.stat().st_size <= 1024 for p in logs))
            records = [json.loads(line) for p in logs for line in p.read_text().splitlines()]
            self.assertTrue(all(e["truncated"] for e in records))

    def test_existing_oversized_managed_log_is_bounded_on_open(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            path.write_text('{"old":true}\n' * 1000)
            Path(str(path) + ".5").write_text("older session\n")
            with debug.Recorder(path, max_bytes=1024, backups=2) as recorder:
                recorder.emit("new_session")
            self.assertFalse(Path(str(path) + ".5").exists())
            self.assertTrue(all(p.stat().st_size <= 1024 for p in Path(directory).iterdir()))

    def test_failed_reader_setup_reaps_process_and_closes_pipe(self):
        children = []
        original = debug.subprocess.Popen

        def tracked(*args, **kwargs):
            child = original(*args, **kwargs)
            children.append(child)
            return child

        with tempfile.TemporaryDirectory() as directory:
            with debug.Recorder(Path(directory) / "events.jsonl") as recorder:
                with mock.patch.object(debug.subprocess, "Popen", tracked), \
                        mock.patch.object(debug.os, "set_blocking", side_effect=OSError("fixture pipe failure")):
                    result = debug.supervise([sys.executable, "-c", "import time; time.sleep(30)"], [], recorder,
                                              max_restarts=0, interval=.01, echo=False)
            self.assertEqual(result, 127)
            self.assertEqual(len(children), 1)
            self.assertIsNotNone(children[0].poll())
            self.assertTrue(children[0].stdout.closed)

    def test_output_reader_drains_and_closes_without_a_trailing_newline(self):
        result, events = self.run_child("import sys; sys.stdout.write('last fragment')", 0)
        self.assertEqual(result, 0)
        self.assertTrue(any(e.get("text") == "last fragment" for e in events))
        self.assertTrue(any(e["event"] == "child_stopped" and not e["reader_alive"] for e in events))

    def test_failed_stage_copy_preserves_previous_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged, destination = root / "staged", root / "project"
            staged.mkdir()
            destination.mkdir()
            (staged / "main.gd").write_text("new")
            (destination / "main.gd").write_text("old")
            with mock.patch.object(release.shutil, "copytree", side_effect=OSError("fixture disk error")):
                with self.assertRaises(OSError):
                    release.install_stage(staged, destination)
            self.assertEqual((destination / "main.gd").read_text(), "old")
            self.assertFalse((root / ".project-next").exists())

    def test_failed_stage_swap_rolls_back_and_interrupted_swap_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged, destination = root / "staged", root / "project"
            staged.mkdir()
            destination.mkdir()
            (staged / "main.gd").write_text("new")
            (destination / "main.gd").write_text("old")
            original = Path.replace

            def fail_install(path, target):
                if path == root / ".project-next":
                    raise OSError("fixture rename error")
                return original(path, target)

            with mock.patch.object(Path, "replace", fail_install):
                with self.assertRaises(OSError):
                    release.install_stage(staged, destination)
            self.assertEqual((destination / "main.gd").read_text(), "old")
            destination.replace(root / ".project-previous")
            with mock.patch.object(release.shutil, "copytree", side_effect=OSError("fixture disk error")):
                with self.assertRaises(OSError):
                    release.install_stage(staged, destination)
            self.assertEqual((destination / "main.gd").read_text(), "old")
            release.install_stage(staged, destination)
            self.assertEqual((destination / "main.gd").read_text(), "new")
            self.assertFalse((root / ".project-previous").exists())

    @unittest.skipUnless(os.name == "posix", "POSIX signal/process-group check")
    def test_sigterm_during_preparation_and_backoff_restores_handlers(self):
        for phase in ("prepare_started", "restarting"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "events.jsonl"
                command = [sys.executable, "-c", "import time; time.sleep(30)" if phase == "prepare_started" else "raise SystemExit(7)"]
                prepare = command if phase == "prepare_started" else None
                script = (f"import sys,signal; sys.path.insert(0,{str(Path(__file__).resolve().parents[1] / 'tools')!r}); "
                          "import dev_debug as d; before=signal.getsignal(signal.SIGTERM); "
                          f"r=d.Recorder(__import__('pathlib').Path({str(path)!r})); "
                          f"code=d.supervise({command!r},[],r,prepare={prepare!r},interval=.02,backoff=30,max_backoff=30,echo=False); "
                          "r.close(); print('restored',before==signal.getsignal(signal.SIGTERM)); raise SystemExit(code)")
                with subprocess.Popen([sys.executable, "-W", "error::ResourceWarning", "-c", script],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as driver:
                    try:
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            text = path.read_text() if path.exists() else ""
                            if f'"event": "{phase}"' in text:
                                break
                            time.sleep(.02)
                        else:
                            self.fail("Supervisor never reached target phase")
                        driver.send_signal(signal.SIGTERM)
                        stdout, stderr = driver.communicate(timeout=3)
                        self.assertEqual(driver.returncode, 0, stderr)
                        self.assertIn("restored True", stdout)
                        self.assertNotIn("ResourceWarning", stderr)
                        if phase == "prepare_started":
                            self.assertNotIn('"event": "started"', path.read_text())
                    finally:
                        if driver.poll() is None:
                            driver.kill()
                            driver.communicate()
