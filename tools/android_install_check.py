#!/usr/bin/env python3
"""Isolated Android API-33 installation check. Never launches the APK's activities/content.

Provision first outside a network namespace; check inside `unshare -Urn` to prohibit outbound traffic.
Uses a private AVD, private adb server, exact emulator serial and a verified qemu device property.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

import android_preview

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "system-images;android-33;google_apis;x86_64"
AVD = "sdt_packaging_api33"


def command(args, log, env, timeout=300, input_text=None, allow_failure=False):
    print("INSTALL CHECK:", log.stem, flush=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("wb") as output:
        child = subprocess.Popen([str(a) for a in args], env=env, cwd=ROOT, stdout=output,
                                 stderr=subprocess.STDOUT, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                                 start_new_session=True)
        try:
            child.communicate(input_text.encode() if input_text is not None else None, timeout=timeout)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            if child.stdin is not None:
                child.stdin.close()
    text = log.read_text(errors="replace")
    if child.returncode and not allow_failure:
        raise RuntimeError(f"{log.stem}: exit {child.returncode}; see {log}")
    return {"exit_code": child.returncode, "output": text}


def run(args):
    build = args.build.resolve()
    if not build.is_relative_to(ROOT / "build"):
        raise ValueError("Use this repository's ignored build directory")
    state = build / "installation-test"
    state.mkdir(parents=True, exist_ok=True)
    sdk = build / "sdk"
    env = dict(os.environ, JAVA_HOME=str(args.jdk), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    for key, name in {"ANDROID_AVD_HOME": "avd", "ANDROID_USER_HOME": "android-user", "ANDROID_EMULATOR_HOME": "emulator-user",
                      "XDG_CACHE_HOME": "cache", "TMPDIR": "tmp"}.items():
        path = state / name
        path.mkdir(exist_ok=True)
        env[key] = str(path)
    env["PATH"] = str(args.jdk / "bin") + os.pathsep + env.get("PATH", "")
    logs = state / "logs"
    logs.mkdir(exist_ok=True)
    if args.action == "provision":
        cmdline = sdk / "cmdline-tools/latest"
        if not cmdline.exists():
            shutil.copytree(args.sdk_manager.parent.parent, cmdline)
        command([cmdline / "bin/sdkmanager", "--sdk_root=" + str(sdk), "--install", "emulator", IMAGE],
                logs / "provision.log", env, timeout=900, input_text="y\n" * 100)
        avd = Path(env["ANDROID_AVD_HOME"]) / (AVD + ".avd")
        if not avd.exists():
            command([cmdline / "bin/avdmanager", "create", "avd", "--name", AVD, "--package", IMAGE,
                     "--path", avd, "--device", "pixel_5"], logs / "create-avd.log", env, input_text="no\n")
        print("Provisioned isolated API-33 emulator; no APK launched.")
        return
    if not args.apk:
        raise ValueError("check requires --apk")
    # A network namespace with no external route is mandatory for the running test.
    route = command(["ip", "-j", "route"], logs / "network-routes.log", env)
    if json.loads(route["output"]):
        raise RuntimeError("Run check under unshare --user --map-root-user --net (no external routes)")
    command(["ip", "link", "set", "lo", "up"], logs / "loopback.log", env)
    serial, adb_port = "emulator-5580", "5042"
    env.update(ADB_SERVER_SOCKET="tcp:127.0.0.1:" + adb_port, ANDROID_ADB_SERVER_PORT=adb_port,
               ADB_VENDOR_KEYS=str(Path(env["ANDROID_USER_HOME"])))
    adb = sdk / "platform-tools/adb"
    adb_base = [adb, "-P", adb_port]
    device = adb_base + ["-s", serial]
    emulator = None
    report = {"apk": str(args.apk.resolve()), "apk_sha256": android_preview.sha(args.apk),
              "api": 33, "serial": serial, "private_adb_port": int(adb_port), "no_external_routes": True,
              "game_launched": False, "physical_device_used": False, "child_home_unchanged": env.get("HOME") == os.environ.get("HOME")}
    label = args.label or args.apk.stem
    try:
        command(adb_base + ["start-server"], logs / (label + "-adb-start.log"), env)
        emulator_log = (logs / (label + "-emulator.log")).open("wb")
        emulator = subprocess.Popen([str(sdk / "emulator/emulator"), "-avd", AVD, "-port", "5580",
                        "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot", "-no-metrics", "-wipe-data",
                        "-gpu", "swiftshader_indirect", "-feature", "-Vulkan", "-accel", "on", "-memory", "2048", "-cores", "2"],
                       env=env, stdout=emulator_log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 240
        booted = False
        while time.monotonic() < deadline:
            if emulator.poll() is not None:
                raise RuntimeError(f"Emulator exited {emulator.returncode}; see emulator log")
            result = command(device + ["shell", "getprop", "sys.boot_completed"], logs / (label + "-boot.log"), env,
                             timeout=10, allow_failure=True)
            if result["exit_code"] == 0 and result["output"].strip() == "1":
                booted = True
                break
            time.sleep(2)
        if not booted:
            raise TimeoutError("Isolated emulator did not boot")
        qemu = command(device + ["shell", "getprop", "ro.kernel.qemu"], logs / (label + "-qemu.log"), env)
        if qemu["output"].strip() != "1":
            raise RuntimeError("Refusing installation on anything other than the owned qemu emulator")
        report["abi_list"] = command(device + ["shell", "getprop", "ro.product.cpu.abilist"], logs / (label + "-abis.log"), env)["output"].strip()
        report["build_fingerprint"] = command(device + ["shell", "getprop", "ro.build.fingerprint"], logs / (label + "-fingerprint.log"), env)["output"].strip()
        command(device + ["logcat", "-c"], logs / (label + "-logcat-clear.log"), env)
        result = command(device + ["install", "--no-streaming", "-r", "-t", args.apk.resolve()], logs / (label + "-install.log"),
                         env, timeout=180, allow_failure=True)
        report["install"] = result
        command(device + ["logcat", "-d", "-b", "all"], logs / (label + "-logcat.log"), env, timeout=30)
        if result["exit_code"] == 0 and "Success" in result["output"]:
            report["package_dump"] = command(device + ["shell", "dumpsys", "package", android_preview.PACKAGE_ID],
                                             logs / (label + "-package.log"), env)["output"]
            running = command(device + ["shell", "pidof", android_preview.PACKAGE_ID], logs / (label + "-app-pid.log"),
                              env, allow_failure=True)
            report["app_process_absent"] = not running["output"].strip()
            report["installation_verified"] = report["app_process_absent"]
        else:
            report["installation_verified"] = False
    finally:
        if emulator is not None:
            command(device + ["emu", "kill"], logs / (label + "-emulator-stop.log"), env, timeout=10, allow_failure=True)
            try:
                emulator.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(emulator.pid, signal.SIGKILL)
                emulator.wait()
            emulator_log.close()
        command(adb_base + ["kill-server"], logs / (label + "-adb-stop.log"), env, timeout=10, allow_failure=True)
        (state / (label + "-report.json")).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({k: v for k, v in report.items() if k != "package_dump"}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("provision", "check"))
    parser.add_argument("--build", type=Path, default=ROOT / "build/android-game-preview")
    parser.add_argument("--sdk-manager", type=Path, default=Path.home() / ".local/android-sdk/cmdline-tools/latest/bin/sdkmanager")
    parser.add_argument("--jdk", type=Path, default=Path("/usr/lib/jvm/java-26-openjdk"))
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--label")
    run(parser.parse_args())


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    main()
