#!/usr/bin/env python3
"""Bounded real Android launch test on an owned, offline API-33 x86_64 emulator.

Run with `unshare -Urn python3 tools/android_runtime_check.py --apk <apk> --label <new-label>`.
Never targets a physical phone or the default adb server. No screenshots or game inputs are collected.
Process presence alone does NOT pass: readiness, drawn frames and native classes require probe evidence.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time

import android_preview as preview

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = preview.PACKAGE_ID
ACTIVITY = PACKAGE + "/com.godot.game.GodotAppLauncher"
AVD = "sdt_runtime_api33"
SERIAL, ADB_PORT = "emulator-5582", "5043"


def analyze_log(text, pids):
    """Filter exact logcat PID fields; ignore unrelated OS errors and numeric substrings."""
    app = []
    for line in text.splitlines():
        fields = line.split(maxsplit=6)
        if len(fields) >= 6 and fields[2] in pids:
            app.append(line)
    probes = []
    for line in app:
        if "SDT_RUNTIME_PROBE " in line:
            try:
                record = json.loads(line.split("SDT_RUNTIME_PROBE ", 1)[1])
                if isinstance(record, dict):
                    probes.append(record)
            except (ValueError, TypeError):
                pass
    errors = [line for line in app if re.search(r"\bERROR:|SCRIPT ERROR:|FATAL EXCEPTION|Fatal signal|shader failed to compile", line)]
    ready = [p for p in probes if p.get("main_scene") == "res://scenes/main.tscn"
             and p.get("main_ready") is True and p.get("flash_stage_children", 0) > 0]
    native = any(p.get("sdt_native_class") is True and p.get("swf_file_class") is True
                 and "res://bin/sdt_native.gdextension" in p.get("extensions", []) for p in ready)
    rendered = len(ready) >= 2 and ready[-1].get("drawn_frames", 0) > ready[0].get("drawn_frames", 0) > 0
    return {"probes": probes, "app_errors": errors, "main_scene_ready_verified": bool(ready),
            "native_extension_verified": native, "rendered_frames_advancing_verified": rendered,
            "app_log_lines": len(app)}


def command(args, log, env, *, timeout=30, input_text=None, check=True):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, input=input_text,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write_text(result.stdout)
    if check and result.returncode:
        raise RuntimeError(f"{log.name}: exit {result.returncode}; see {log}")
    return {"exit_code": result.returncode, "output": result.stdout}


def stop(child):
    if child is None:
        return
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass  # It may exit between poll() and signaling; still reap it below.
    try:
        child.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=10)


def run(args):
    build, apk = args.build.resolve(), args.apk.resolve()
    if not build.is_relative_to(ROOT / "build") or build == ROOT / "build":
        raise ValueError("Use a dedicated build directory in this repository")
    if not apk.is_relative_to(ROOT / "build") or not apk.is_file():
        raise ValueError("Test only an existing APK under this repository's build/")
    upgrade_from = args.upgrade_from.resolve() if args.upgrade_from else None
    if upgrade_from is not None and (not upgrade_from.is_relative_to(ROOT / "build") or not upgrade_from.is_file()):
        raise ValueError("Upgrade baseline must be an existing APK under this repository's build/")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,80}", args.label):
        raise ValueError("Use a simple new label without path separators")
    if not 20 <= args.seconds <= 300:
        raise ValueError("Observation must be between 20 and 300 seconds")
    state = build / "runtime-test" / args.label
    state.mkdir(parents=True, exist_ok=False)
    sdk = build / "sdk"
    env = dict(os.environ, JAVA_HOME=str(args.jdk), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    env["PATH"] = str(args.jdk / "bin") + os.pathsep + env.get("PATH", "")
    for key, directory in {"ANDROID_AVD_HOME": "avd", "ANDROID_USER_HOME": "android-user",
                           "ANDROID_EMULATOR_HOME": "emulator-user", "XDG_CACHE_HOME": "cache", "TMPDIR": "tmp"}.items():
        path = state / directory
        path.mkdir()
        env[key] = str(path)
    env.update(ADB_SERVER_SOCKET="tcp:127.0.0.1:" + ADB_PORT, ANDROID_ADB_SERVER_PORT=ADB_PORT,
               ADB_VENDOR_KEYS=env["ANDROID_USER_HOME"])
    adb = [sdk / "platform-tools/adb", "-P", ADB_PORT]
    device = adb + ["-s", SERIAL]
    report = {"started_utc": datetime.now(timezone.utc).isoformat(), "apk": str(apk),
              "apk_sha256": preview.sha(apk), "api": 33, "serial": SERIAL, "private_adb_port": int(ADB_PORT),
              "physical_device_used": False, "game_completion_verified": False, "runtime_smoke_passed": False,
              "child_home_unchanged": env.get("HOME") == os.environ.get("HOME"), "observation_seconds": args.seconds}
    report["gpu_mode"] = args.gpu
    if upgrade_from:
        report.update(upgrade_from=str(upgrade_from), upgrade_from_sha256=preview.sha(upgrade_from))
    emulator, logcat = None, None
    emulator_output = logcat_output = None
    adb_started = False
    try:
        # Fail closed: a private network namespace must have no non-loopback interfaces or routes.
        links = command(["ip", "-j", "link"], state / "network-links.json", env)["output"]
        if any(link["ifname"] != "lo" for link in json.loads(links)):
            raise RuntimeError("Run under unshare -Urn; a network-isolated namespace is mandatory")
        for family in ("-4", "-6"):
            routes = command(["ip", family, "-j", "route"], state / (family + "-routes.json"), env)["output"]
            if json.loads(routes):
                raise RuntimeError("Unexpected routes: emulator test refuses external network access")
        report["no_external_routes"] = True
        command(["ip", "link", "set", "lo", "up"], state / "loopback.log", env)
        command([sdk / "cmdline-tools/latest/bin/avdmanager", "create", "avd", "--name", AVD,
                 "--package", "system-images;android-33;google_apis;x86_64", "--path", state / "avd" / (AVD + ".avd"),
                 "--device", "pixel_5"], state / "create-avd.log", env, timeout=60, input_text="no\n")
        command(adb + ["start-server"], state / "adb-start.log", env)
        adb_started = True
        emulator_output = (state / "emulator.log").open("wb")
        emulator = subprocess.Popen([str(sdk / "emulator/emulator"), "-avd", AVD, "-port", "5582",
                                    "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot", "-no-metrics",
                                    "-gpu", args.gpu, "-feature", "-Vulkan", "-accel", "on", "-memory", "2048", "-cores", "2"],
                                   cwd=ROOT, env=env, stdout=emulator_output, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
        deadline = time.monotonic() + 240
        while True:
            if emulator.poll() is not None:
                raise RuntimeError(f"Owned emulator exited {emulator.returncode}; see {state / 'emulator.log'}")
            boot = command(device + ["shell", "getprop", "sys.boot_completed"], state / "boot.log", env,
                           timeout=10, check=False)
            if boot["exit_code"] == 0 and boot["output"].strip() == "1":
                break
            if time.monotonic() > deadline:
                raise TimeoutError("Owned emulator did not finish booting")
            time.sleep(2)
        qemu = command(device + ["shell", "getprop", "ro.kernel.qemu"], state / "qemu.log", env)
        if qemu["output"].strip() != "1":
            raise RuntimeError("Refusing to operate on anything other than the owned emulator")
        for key, prop in (("abi_list", "ro.product.cpu.abilist"), ("fingerprint", "ro.build.fingerprint")):
            report[key] = command(device + ["shell", "getprop", prop], state / (key + ".log"), env)["output"].strip()
        if upgrade_from:
            command(device + ["install", "--no-streaming", "-t", upgrade_from], state / "baseline-install.log", env, timeout=180)
            command(device + ["shell", "run-as", PACKAGE, "mkdir", "-p", "files"], state / "baseline-data-dir.log", env)
            marker = "printf %s sdt-runtime-upgrade-sentinel > files/__sdt_runtime_upgrade_probe.txt"
            command(device + ["shell", shlex.join(["run-as", PACKAGE, "sh", "-c", marker])], state / "baseline-marker-write.log", env)
        report["install"] = command(device + ["install", "--no-streaming", "-r", "-t", apk], state / "install.log", env,
                                    timeout=180, check=False)
        report["installation_verified"] = report["install"]["exit_code"] == 0 and "Success" in report["install"]["output"]
        if not report["installation_verified"]:
            raise RuntimeError("APK installation failed")
        if upgrade_from:
            marker = command(device + ["shell", "run-as", PACKAGE, "cat", "files/__sdt_runtime_upgrade_probe.txt"], state / "upgrade-marker-read.log", env)
            report["upgrade_data_preserved"] = marker["output"].strip() == "sdt-runtime-upgrade-sentinel"
            if not report["upgrade_data_preserved"]:
                raise RuntimeError("Upgrade failed to preserve the neutral app-private marker")
        command(device + ["shell", "dumpsys", "package", PACKAGE], state / "package.log", env)
        command(device + ["logcat", "-c"], state / "logcat-clear.log", env)
        logcat_output = (state / "logcat.txt").open("wb")
        logcat = subprocess.Popen([str(a) for a in device + ["logcat", "-b", "all", "-v", "threadtime"]],
                                  cwd=ROOT, env=env, stdout=logcat_output, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL, start_new_session=True)
        report["launch"] = command(device + ["shell", "am", "start", "-W", "-n", ACTIVITY], state / "launch.log", env,
                                   timeout=120, check=False)
        report["activity_start_verified"] = report["launch"]["exit_code"] == 0 and "Status: ok" in report["launch"]["output"]
        print(f"Installed and started {apk.name}; observing for {args.seconds}s", flush=True)
        deadline = time.monotonic() + args.seconds
        samples, pids = [], set()
        while time.monotonic() < deadline:
            result = command(device + ["shell", "pidof", PACKAGE], state / "pid.log", env, check=False)
            pid = result["output"].strip()
            samples.append({"elapsed": round(args.seconds - (deadline - time.monotonic()), 2), "pid": pid})
            if pid.isdecimal():
                pids.add(pid)
            time.sleep(2)
        report["pid_samples"] = samples
        report["same_process_survived"] = len(pids) == 1 and bool(samples) and all(s["pid"] in pids for s in samples)
        if args.home_resume:
            command(device + ["shell", "input", "keyevent", "KEYCODE_HOME"], state / "home.log", env)
            time.sleep(3)
            resumed = command(device + ["shell", "am", "start", "-W", "-n", ACTIVITY], state / "resume.log", env, timeout=60, check=False)
            time.sleep(12)
            after = command(device + ["shell", "pidof", PACKAGE], state / "resume-pid.log", env, check=False)
            report["home_resume_same_process_verified"] = resumed["exit_code"] == 0 and "Status: ok" in resumed["output"] \
                and bool(samples) and after["output"].strip() == samples[-1]["pid"] and samples[-1]["pid"].isdecimal()
        if samples and samples[-1]["pid"].isdecimal():
            pid = samples[-1]["pid"]
            maps = command(device + ["shell", "run-as", PACKAGE, "cat", f"/proc/{pid}/maps"], state / "native-maps.log", env, check=False)
            report["native_library_mapped"] = maps["exit_code"] == 0 and "libsdt_native.android.template_debug.x86_64.so" in maps["output"]
        folders = command(device + ["shell", "run-as", PACKAGE, "ls", "files/Mods"], state / "private-mod-directories.log", env, check=False)
        report["private_mod_storage_verified"] = folders["exit_code"] == 0 and set(folders["output"].split()) >= {
            "Clothing", "Hair", "Backgrounds", "Characters", "Dialogue", "Plugins"}
        command(device + ["shell", "dumpsys", "activity", "activities"], state / "activities.log", env)
        stop(logcat)
        logcat = None
        logcat_output.close()
        logcat_output = None
        report.update(analyze_log((state / "logcat.txt").read_text(errors="replace"), pids))
        report["runtime_smoke_passed"] = all(report.get(k) is True for k in (
            "activity_start_verified", "same_process_survived", "main_scene_ready_verified",
            "native_extension_verified", "rendered_frames_advancing_verified", "native_library_mapped", "private_mod_storage_verified")) and not report["app_errors"]
        if args.home_resume:
            report["runtime_smoke_passed"] &= report.get("home_resume_same_process_verified", False)
        if not report["runtime_smoke_passed"]:
            report["blocker"] = "Runtime readiness/native/render/error gates did not all pass; see probe records and app_errors"
    except BaseException as exc:
        report["blocker"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        stop(logcat)
        if logcat_output is not None:
            logcat_output.close()
        try:
            if emulator is not None and emulator.poll() is None and adb_started:
                command(device + ["emu", "kill"], state / "emulator-stop.log", env, timeout=10, check=False)
        finally:
            stop(emulator)
            report["emulator_reaped"] = emulator is None or emulator.poll() is not None
            if emulator_output is not None:
                emulator_output.close()
            if adb_started:
                command(adb + ["kill-server"], state / "adb-stop.log", env, timeout=10, check=False)
            report["apk_unchanged"] = preview.sha(apk) == report["apk_sha256"]
            if upgrade_from:
                report["upgrade_baseline_unchanged"] = preview.sha(upgrade_from) == report["upgrade_from_sha256"]
            if not report["apk_unchanged"] or not report["emulator_reaped"] or report.get("upgrade_baseline_unchanged") is False:
                report["runtime_smoke_passed"] = False
                report["blocker"] = "Artifact immutability or owned emulator cleanup failed"
            report["finished_utc"] = datetime.now(timezone.utc).isoformat()
            (state / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({k: v for k, v in report.items() if k not in ("pid_samples", "probes", "app_errors")}, indent=2), flush=True)
    return 0 if report["runtime_smoke_passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=ROOT / "build/android-game-preview")
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--jdk", type=Path, default=Path("/usr/lib/jvm/default"))
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--upgrade-from", type=Path, help="install an older preview first and verify a neutral private-data marker survives the upgrade")
    parser.add_argument("--home-resume", action="store_true", help="also send Android Home and resume the owned app")
    parser.add_argument("--gpu", choices=("swiftshader_indirect", "swiftshader", "software", "swangle", "host"), default="software")
    return run(parser.parse_args())


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    raise SystemExit(main())
