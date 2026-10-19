#!/usr/bin/env python3
"""Export an incremented DEBUG runtime preview from the verified v2 source/cache, fully offline.

Does not rebuild native code: validates and reuses the exact v2 compiled binaries. Copies the stage,
preserves the original/frozen artifacts and source tree, and installs a read-only readiness observer.
Not a production release, rights clearance, gameplay completion check or physical-device test.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import zipfile

import android_preview as preview

ROOT = preview.ROOT
V2_SHA = "a08966caffdc565ce82ea585592406fc85a2edb58fb5eedd370087ec7a332dcd"
VERSION = {"version_code": 4, "version_name": "0.1.3-local-ai-review"}


def configure_observer(project):
    probe = project / "__android_preview_probe.gd"
    shutil.copy2(ROOT / "tools/fixtures/android_runtime_probe.gd", probe)
    path = project / "project.godot"
    text = path.read_text()
    if "AndroidPreviewProbe=" in text or "[autoload]" not in text:
        raise ValueError("Expected an uninstrumented game stage with autoloads")
    text = text.replace("[autoload]", '[autoload]\nAndroidPreviewProbe="*res://__android_preview_probe.gd"', 1)
    path.write_text(text)
    return {"path": probe.name, "sha256": preview.sha(probe), "read_only": True}


def run(args):
    base, build = args.base.resolve(), args.output.resolve()
    version = {"version_code": args.version_code, "version_name": args.version_name}
    preview.validate_version(**version)
    protected = ROOT / "build/android-game-preview"
    if build.is_relative_to(protected):
        raise ValueError("Frozen Android review directory is protected; choose a separate build output")
    if args.enable_ai_network and args.version_code <= 3:
        raise ValueError("AI networking requires a new version above frozen v3")
    if not base.is_relative_to(ROOT / "build") or not build.is_relative_to(ROOT / "build") \
            or base == build or build == ROOT / "build":
        raise ValueError("Use distinct dedicated directories in this repository's build/")
    if build.exists():
        raise FileExistsError("Refusing to replace a previous runtime-preview build: " + str(build))
    source_apk = base / "sdt-godot-android-debug-preview-v2.apk"
    if preview.sha(source_apk) != V2_SHA:
        raise ValueError("Frozen v2 artifact does not match the recorded SHA-256")
    inputs = preview.game_inputs()
    old_inputs = json.loads((base / "source-manifest.json").read_text())
    # Source fixes in GDScript do not require new native compilation. All native inputs and
    # the binding revision, however, must still match the original native build provenance.
    if [i for i in inputs if i["path"].startswith("native/")] != [i for i in old_inputs if i["path"].startswith("native/")]:
        raise ValueError("Native source changed; rebuild it instead of reusing compiled v2 libraries")
    previous = json.loads((base / "final-delivery-v2.json").read_text())
    bindings = subprocess.check_output(["git", "-C", str(ROOT / "native/godot-cpp"), "rev-parse", "HEAD"], text=True).strip()
    if bindings != previous["source_identity"]["godot_cpp_revision"]:
        raise ValueError("godot-cpp revision changed; a new native build is required")
    # Cached scripts/assets must match source too, not merely have the same filenames.
    exceptions = {"game/project.godot", "game/bin/sdt_native.gdextension"}
    for item in old_inputs:
        if not item["path"].startswith("game/") or item["path"] in exceptions:
            continue
        cached = base / "stage" / item["path"]
        if not cached.is_file() or preview.sha(cached) != item["sha256"]:
            raise ValueError("Cached game input changed: " + item["path"])
    with zipfile.ZipFile(source_apk) as archive:
        preview.manifest_identity(archive.read("AndroidManifest.xml"))
        preview.verify_native_archive(archive, base / "stage")
    sdk = base / "sdk"
    jdk = args.jdk.resolve()
    for required in (sdk / "build-tools/36.0.0/aapt2", sdk / "build-tools/36.0.0/zipalign",
                     sdk / "build-tools/36.0.0/apksigner", jdk / "bin/java", jdk / "bin/keytool"):
        if not required.is_file():
            raise FileNotFoundError(required)
    build.mkdir(parents=True)
    logs = build / "logs"
    logs.mkdir()
    env = dict(os.environ, JAVA_HOME=str(jdk), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    env["PATH"] = str(jdk / "bin") + os.pathsep + env.get("PATH", "")
    for key, name in {"XDG_DATA_HOME": "profile/data", "XDG_CONFIG_HOME": "profile/config", "XDG_CACHE_HOME": "profile/cache",
                      "ANDROID_USER_HOME": "profile/android", "TMPDIR": "profile/tmp"}.items():
        path = build / name
        path.mkdir(parents=True)
        env[key] = str(path)
    report = {"scope": "existing_game_debug_runtime_preview", **version, "ok": False, "ai_network_enabled": args.enable_ai_network,
              "base_apk_sha256": V2_SHA, "source_file_count": len(inputs), "native_rebuilt": False,
              "native_reused_from_exact_v2": True, "game_launched": False, "physical_device_tested": False,
              "game_completion_verified": False, "steps": {},
              "base_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    report["tool_sha256"] = {p.relative_to(ROOT).as_posix(): preview.sha(p) for p in
                            (Path(__file__).resolve(), ROOT / "tools/android_preview.py", ROOT / "tools/fixtures/android_runtime_probe.gd")}
    old_by_path, current_by_path = ({i["path"]: i for i in entries} for entries in (old_inputs, inputs))
    report["source_changes_from_v2"] = sorted(path for path in old_by_path.keys() | current_by_path.keys()
                                               if old_by_path.get(path) != current_by_path.get(path))
    report["godot_cpp_revision"] = bindings
    manifest = build / "source-manifest.json"
    manifest.write_text(json.dumps(inputs, indent=2) + "\n")
    report["source_manifest_sha256"] = preview.sha(manifest)
    try:
        staged = build / "stage"
        shutil.copytree(base / "stage/game", staged / "game")
        # All edits/deletions are confined to this newly owned copy; reuse import caches, not stale sources.
        for path in old_by_path.keys() - current_by_path.keys():
            if path.startswith("game/"):
                (staged / path).unlink(missing_ok=True)
        for item in inputs:
            if item["path"].startswith("game/"):
                destination = staged / item["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / item["path"], destination)
        project = staged / "game"
        for folder, filename in (("templates", "android_debug.apk"), ("keys", "debug.keystore")):
            (build / folder).mkdir()
            shutil.copy2(base / folder / filename, build / folder / filename)
        report["template_sha256"] = preview.sha(build / "templates/android_debug.apk")
        preview.write_export_preset(staged, build, **version, enable_ai_network=args.enable_ai_network)
        report["native"] = [preview.configure_android_library(staged, arch) for arch in preview.DEFAULT_ARCHITECTURES]
        preview.configure_game_import(project, build / "templates/android_debug.apk")
        report["observer"] = configure_observer(project)
        helper = preview.configure_editor(build, sdk, jdk, build / "keys/debug.keystore")
        for name, cmd, timeout in (
                ("java", [jdk / "bin/java", "-version"], 30),
                ("engine", [args.godot, "--version"], 30),
                ("settings", [args.godot, "--headless", "--editor", "--path", helper], 60),
                ("import", [args.godot, "--headless", "--editor", "--path", project, "--import"], 600)):
            report["steps"][name] = preview.execute(cmd, logs / (name + ".log"), env, timeout=timeout)
        raw, apk = build / "export-raw.apk", build / f"sdt-godot-android-debug-preview-v{args.version_code}.apk"
        report["steps"]["export"] = preview.execute([args.godot, "--headless", "--path", project, "--export-debug",
                                                     "Existing Game Android DEBUG", raw], logs / "export.log", env, timeout=600)
        report["raw_export_sha256"] = preview.sha(raw)
        report["finalization"] = preview.finalize_apk(raw, apk, build, sdk, env, **version)
        report["apk"] = preview.verify_apk(apk, build, sdk, jdk, env, **version, enable_ai_network=args.enable_ai_network)
        (apk.with_suffix(".apk.sha256")).write_text(preview.sha(apk) + "  " + apk.name + "\n")
        report["ok"] = True
    except BaseException as exc:
        report["blocker"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        report["original_inputs_unchanged"] = preview.game_inputs() == inputs
        report["frozen_v2_unchanged"] = preview.sha(source_apk) == V2_SHA
        report["ok"] &= report["original_inputs_unchanged"] and report["frozen_v2_unchanged"]
        (build / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=ROOT / "build/android-game-preview")
    parser.add_argument("--output", type=Path, default=ROOT / "build/game-runtime-preview-v4")
    parser.add_argument("--version-code", type=int, default=VERSION["version_code"])
    parser.add_argument("--version-name", default=VERSION["version_name"])
    parser.add_argument("--enable-ai-network", action="store_true")
    parser.add_argument("--jdk", type=Path, default=Path("/usr/lib/jvm/default"))
    parser.add_argument("--godot", default="godot")
    run(parser.parse_args())


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    main()
