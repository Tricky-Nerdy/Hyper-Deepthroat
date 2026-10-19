#!/usr/bin/env python3
"""Local neutral-workbench supervisor: process reload, bounded retries and rotating JSONL logs."""
import argparse
import codecs
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]

SUFFIXES = {".gd", ".tscn", ".godot", ".json", ".py", ".cfg", ".txt"}
IGNORED = {".godot", ".git", "__pycache__"}
ANSI = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
ERROR = re.compile(r"^(?:SCRIPT ERROR:|ERROR:|Parse Error:|Compile Error:)")
METRICS_PREFIX = "WORKBENCH_METRICS "
KILL_SIGNAL = getattr(signal, "SIGKILL", signal.SIGTERM)


def fingerprint(paths, previous=None, on_error=None):
    """A stable deletion changes the snapshot; a raced/unreadable file is retried next poll.

    Retain the previous digest when a read/stat races a save, rather than aborting supervision or
    repeatedly restarting on an unreadable file. Directory traversal errors retain that subtree.
    """
    previous = previous or {}
    result = {}

    def unavailable(path, exc, subtree=False):
        if subtree:
            result.update((name, value) for name, value in previous.items()
                          if Path(name).is_relative_to(path))
        elif str(path) in previous:
            result[str(path)] = previous[str(path)]
        if on_error:
            on_error(path, exc)

    def read(path):
        if path.suffix not in SUFFIXES or path.is_symlink():
            return
        try:
            before = path.stat()
            data = path.read_bytes()
            after = path.stat()
            if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
                raise OSError("file changed during fingerprint")
            result[str(path)] = hashlib.sha256(data).hexdigest()
        except OSError as exc:
            unavailable(path, exc)

    for root in paths:
        root = Path(root)
        if root.is_file():
            read(root)
        else:
            def walk_error(exc):
                if not isinstance(exc, FileNotFoundError):
                    unavailable(Path(exc.filename or root), exc, subtree=True)
            for folder, directories, files in os.walk(root, onerror=walk_error, followlinks=False):
                directories[:] = sorted(d for d in directories if d not in IGNORED and not (Path(folder) / d).is_symlink())
                for name in sorted(files):
                    read(Path(folder) / name)
    return result


class Recorder:
    """Thread-safe bounded records: active file plus `backups` rotated files."""

    def __init__(self, path, max_bytes=1024 * 1024, backups=3):
        if max_bytes < 1024 or not 1 <= backups <= 20:
            raise ValueError("log size must be >=1024 bytes; backups must be between 1 and 20")
        self.path = Path(path)
        self.max_bytes, self.backups = max_bytes, backups
        path = self.path
        path.parent.mkdir(parents=True, exist_ok=True)
        for candidate in path.parent.glob(path.name + ".*"):
            suffix = candidate.name.removeprefix(path.name + ".")
            if suffix.isdigit() and int(suffix) > backups:
                candidate.unlink()
        for candidate in [path] + [Path(str(path) + f".{i}") for i in range(1, backups + 1)]:
            if candidate.exists() and candidate.stat().st_size > max_bytes:
                with candidate.open("rb") as stream:
                    stream.seek(-max_bytes, os.SEEK_END)
                    tail = stream.read().split(b"\n", 1)
                candidate.write_bytes(tail[1] if len(tail) == 2 else b"")
        self.stream = path.open("a", encoding="utf-8")
        self.lock = threading.Lock()

    def _rotate(self):
        self.stream.close()
        for i in range(self.backups, 0, -1):
            source = self.path if i == 1 else Path(str(self.path) + f".{i - 1}")
            if source.exists():
                source.replace(Path(str(self.path) + f".{i}"))
        self.stream = self.path.open("w", encoding="utf-8")

    def emit(self, event, **fields):
        record = dict(time=time.time(), monotonic=time.monotonic(), event=event, **fields)
        data = json.dumps(record, ensure_ascii=False) + "\n"
        if len(data.encode("utf-8")) > self.max_bytes:
            record = dict(time=record["time"], monotonic=record["monotonic"], event=event,
                          truncated=True, preview=data.encode("utf-8")[:self.max_bytes // 4].decode("utf-8", "replace"))
            data = json.dumps(record, ensure_ascii=False) + "\n"
        with self.lock:
            if self.stream.tell() + len(data.encode("utf-8")) > self.max_bytes:
                self._rotate()
            self.stream.write(data)
            self.stream.flush()

    def close(self):
        with self.lock:
            self.stream.close()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class ManagedProcess:
    """Own a process, its output pipe and a cancellable, non-daemon reader."""

    def __init__(self, command, recorder, phase, cwd, env, echo):
        self.recorder, self.phase, self.echo = recorder, phase, echo
        self.cancel = threading.Event()
        self.error = threading.Event()
        self.process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, bufsize=0,
                                        start_new_session=os.name == "posix")
        try:
            os.set_blocking(self.process.stdout.fileno(), False)
            self.reader = threading.Thread(target=self._output, name=f"dev-debug-output-{self.process.pid}")
            self.reader.start()
        except BaseException:
            try:
                self._signal(signal.SIGTERM)
                try:
                    self.process.wait(timeout=.2)
                except subprocess.TimeoutExpired:
                    self._signal(KILL_SIGNAL)
                    self.process.wait(timeout=2)
            finally:
                self.process.stdout.close()
            raise

    def _line(self, text):
        text = ANSI.sub("", text.rstrip())
        if ERROR.match(text.lstrip()):
            self.error.set()
        if self.echo:
            try:
                print(text, flush=True)
            except BrokenPipeError:
                self.echo = False
        self.recorder.emit("output", pid=self.process.pid, phase=self.phase,
                           level="error" if ERROR.match(text.lstrip()) else "info", text=text)
        if self.phase == "runtime" and text.startswith(METRICS_PREFIX):
            try:
                metrics = json.loads(text[len(METRICS_PREFIX):])
                if not isinstance(metrics, dict) or metrics.get("schema") != 1:
                    raise ValueError("unsupported metrics schema")
                self.recorder.emit("engine_metrics", pid=self.process.pid, metric_source="godot", metrics=metrics)
            except (ValueError, TypeError) as exc:
                self.recorder.emit("metrics_rejected", pid=self.process.pid, error=str(exc))

    def _output(self):
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        pending = ""
        try:
            while not self.cancel.is_set():
                try:
                    chunk = os.read(self.process.stdout.fileno(), 4096)
                except BlockingIOError:
                    self.cancel.wait(.02)
                    continue
                if not chunk:
                    break
                pending += decoder.decode(chunk)
                while "\n" in pending:
                    line, pending = pending.split("\n", 1)
                    self._line(line)
                while len(pending) > 8192:
                    self._line(pending[:8192])
                    pending = pending[8192:]
            pending += decoder.decode(b"", final=True)
            if pending:
                self._line(pending)
        except Exception as exc:
            self.error.set()
            self.recorder.emit("reader_error", pid=self.process.pid, phase=self.phase, error=str(exc))

    def _signal(self, sig):
        try:
            if os.name == "posix":
                os.killpg(self.process.pid, sig)
            elif self.process.poll() is None:
                self.process.kill() if sig == KILL_SIGNAL else self.process.terminate()
        except ProcessLookupError:
            pass

    def finish(self, reason, timeout=1.0, stop_file=None):
        child = self.process
        stop_error = None
        if child.poll() is None and stop_file is not None:
            try:
                Path(stop_file).write_text("stop\n", encoding="utf-8")
            except OSError as exc:
                stop_error = str(exc)
            else:
                try:
                    child.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    pass
        # Also clean up descendants retaining stdout after their parent has exited (POSIX).
        self._signal(signal.SIGTERM)
        try:
            child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self._signal(KILL_SIGNAL)
            child.wait(timeout=2)
        self.reader.join(timeout=.3)
        if self.reader.is_alive():
            self.cancel.set()
            self.reader.join(timeout=1)
        child.stdout.close()
        if self.reader.is_alive():
            raise RuntimeError("output reader did not stop")
        if stop_error:
            self.recorder.emit("stop_request_failed", pid=child.pid, error=stop_error)
        self.recorder.emit("child_stopped", pid=child.pid, phase=self.phase, reason=reason,
                           exit_code=child.returncode, reader_alive=False)
        return child.returncode


def supervise(command, paths, recorder, max_restarts=3, interval=.2, debounce=.4, prepare=None,
              *, stop_event=None, cwd=ROOT, env=None, backoff=.5, max_backoff=5,
              prepare_timeout=60, shutdown_timeout=1, stop_file=None, echo=True):
    """One session-wide failure budget covers preparation, launch and runtime failures.

    Source edits request process restarts, not state-preserving hot reload. Edits do not reset the
    failure budget. An explicit stop is successful; exhausted failures remain nonzero.
    """
    if max_restarts < 0 or not all(math.isfinite(n) and n > 0 for n in
                                  (interval, backoff, max_backoff, prepare_timeout, shutdown_timeout)) \
            or not math.isfinite(debounce) or debounce < 0:
        raise ValueError("invalid supervisor timing/restart configuration")
    stop = stop_event if stop_event is not None else threading.Event()
    old_handlers = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            old_handlers[sig] = signal.signal(sig, lambda *_: stop.set())
    process = None
    restarts = 0
    generation = 0
    retry_at = 0.0
    changed_at = None
    last_heartbeat = 0.0

    def failed(code, phase):
        nonlocal restarts, retry_at
        code = code if code > 0 else 128 + abs(code)
        if restarts >= max_restarts:
            recorder.emit("restart_limit", count=restarts, phase=phase, exit_code=code)
            return code
        restarts += 1
        delay = min(backoff * 2 ** min(restarts - 1, 20), max_backoff)
        retry_at = time.monotonic() + delay
        recorder.emit("restarting", attempt=restarts, phase=phase, delay_seconds=delay)
        return None

    def preparation():
        child = ManagedProcess(prepare, recorder, "prepare", cwd, env, echo)
        deadline = time.monotonic() + prepare_timeout
        try:
            recorder.emit("prepare_started", pid=child.process.pid)
            while child.process.poll() is None and not child.error.is_set() and not stop.is_set():
                if time.monotonic() >= deadline:
                    recorder.emit("prepare_timeout", pid=child.process.pid)
                    return 124
                stop.wait(min(interval, .1))
        finally:
            code = child.finish("shutdown" if stop.is_set() else "prepared", shutdown_timeout)
        return (code or 1) if child.error.is_set() else code

    try:
        baseline = fingerprint(paths)
        while not stop.is_set():
            watch_errors = []
            current = fingerprint(paths, baseline, lambda path, exc: watch_errors.append((str(path), str(exc))))
            for path, error in watch_errors:
                recorder.emit("watch_retry", path=path, error=error)
            if current != baseline:
                baseline = current
                changed_at = time.monotonic()
                recorder.emit("source_changed")
            quiet = changed_at is None or time.monotonic() - changed_at >= debounce
            if process is not None and (process.process.poll() is not None or process.error.is_set()):
                code = process.finish("exited", shutdown_timeout)
                effective = (code or 1) if process.error.is_set() else code
                recorder.emit("exited", pid=process.process.pid, exit_code=code, effective_exit=effective,
                              output_error=process.error.is_set())
                process = None
                if effective == 0:
                    return 0
                exhausted = failed(effective, "runtime")
                if exhausted is not None:
                    return exhausted
            if process is not None and changed_at is not None and quiet:
                process.finish("source_reload", shutdown_timeout, stop_file)
                process = None
                generation += 1
                recorder.emit("source_reload", generation=generation, mode="process_restart")
                changed_at = None
            if process is None and quiet and time.monotonic() >= retry_at and not stop.is_set():
                try:
                    code = preparation() if prepare else 0
                    if stop.is_set():
                        break
                    recorder.emit("prepare", exit_code=code)
                    if code:
                        exhausted = failed(code, "prepare")
                        if exhausted is not None:
                            return exhausted
                        stop.wait(interval)
                        continue
                    if stop_file is not None:
                        Path(stop_file).unlink(missing_ok=True)
                    process = ManagedProcess(command, recorder, "runtime", cwd, env, echo)
                    recorder.emit("started", pid=process.process.pid, generation=generation)
                    changed_at = None
                except OSError as exc:
                    recorder.emit("launch_failed", error=str(exc))
                    exhausted = failed(127, "launch")
                    if exhausted is not None:
                        return exhausted
            if time.monotonic() - last_heartbeat >= 1:
                recorder.emit("heartbeat", metric_source="supervisor", pid=process.process.pid if process else None,
                              running=process is not None and process.process.poll() is None, restarts=restarts,
                              phase="runtime" if process else "backoff")
                last_heartbeat = time.monotonic()
            stop.wait(interval)
        return 0
    finally:
        try:
            if process is not None:
                process.finish("shutdown", shutdown_timeout, stop_file)
            recorder.emit("stopped", restarts=restarts)
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-restarts", type=int, default=3)
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, default=ROOT / "build/debug")
    parser.add_argument("--poll", type=float, default=.2)
    parser.add_argument("--debounce", type=float, default=.4)
    parser.add_argument("--backoff", type=float, default=.5)
    parser.add_argument("--prepare-timeout", type=float, default=60)
    parser.add_argument("--log-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--log-backups", type=int, default=3)
    parser.add_argument("--max-fps", type=int, default=60)
    parser.add_argument("--telemetry-interval", type=float, default=1)
    args = parser.parse_args()
    if args.max_restarts < 0 or args.max_fps < 1 or args.log_bytes < 1024 or not 1 <= args.log_backups <= 20 \
            or not all(math.isfinite(n) and n > 0 for n in (args.poll, args.backoff, args.prepare_timeout, args.telemetry_interval)) \
            or not math.isfinite(args.debounce) or args.debounce < 0 or not .1 <= args.telemetry_interval <= 60:
        parser.error("timings/FPS must be positive, debounce/restarts nonnegative, log size >=1024 and backups 1..20")
    source = args.source_root.resolve()
    output = args.output.resolve()
    if output == source or output in source.parents or any(output.is_relative_to(source / p) for p in ("workbench", "game", "tools", "docs", "tests", ".git")):
        parser.error("output must be a dedicated build directory, outside source folders")
    output.mkdir(parents=True, exist_ok=True)
    # Isolate engine saves, logs and settings from the owner's normal workbench/editor profile.
    env = dict(os.environ)
    for key, name in {"HOME": "home", "USERPROFILE": "home", "XDG_DATA_HOME": "user-data",
                      "XDG_CONFIG_HOME": "config", "XDG_CACHE_HOME": "cache", "APPDATA": "user-data",
                      "LOCALAPPDATA": "user-data"}.items():
        directory = output / name
        directory.mkdir(exist_ok=True)
        env[key] = str(directory)
    stop_file = output / "stop-request"
    command = [args.godot, "--path", str(output / "portable/project"), "--max-fps", str(args.max_fps)]
    if args.headless:
        command += ["--headless"]
    command += ["--", f"--debug-telemetry={args.telemetry_interval}", f"--debug-stop-file={stop_file}"]
    prepare = [sys.executable, str(ROOT / "tools/portable_release.py"), "stage", "--source-root", str(source),
               "--output", str(output / "portable"), "--disable-file-logging"]
    with Recorder(output / "events.jsonl", args.log_bytes, args.log_backups) as recorder:
        try:
            return supervise(command, [source / "workbench", source / "game/src/ext/loader"], recorder,
                             max_restarts=args.max_restarts, interval=args.poll, debounce=args.debounce,
                             backoff=args.backoff, prepare_timeout=args.prepare_timeout,
                             prepare=prepare, env=env, stop_file=stop_file, echo=sys.stdout.isatty())
        except (OSError, RuntimeError) as exc:
            recorder.emit("supervisor_failed", error=str(exc))
            print(f"Supervisor failed: {exc}", file=sys.stderr)
            return 1

if __name__ == "__main__":
    raise SystemExit(main())
