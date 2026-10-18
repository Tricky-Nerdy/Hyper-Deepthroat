#!/usr/bin/env python3
"""Stage, verify and export the neutral workbench. Python standard library only.

Only explicitly allowlisted loader code and workbench fixtures are copied. Never exports game assets,
user mods, credentials, editor configuration, or personal source inventories.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CORE = (
    "package_manifest.gd", "package_resolver.gd", "owned_slots.gd", "runtime_capabilities.gd",
    "asset_commands.gd", "story_runtime.gd", "atomic_json.gd",
)
WORKBENCH = ("project.godot", "main.tscn", "main.gd", "checks.gd", "fixtures/arrival.json", "fixtures/assets.json")
TARGETS = {
    "linux": ("Linux", "linux/workbench.x86_64", {"binary_format/architecture": "x86_64"}),
    "windows": ("Windows Desktop", "windows/workbench.exe", {"binary_format/architecture": "x86_64"}),
    "macos": ("macOS", "macos/workbench.zip", {"application/bundle_identifier": "org.portablemod.workbench", "codesign/codesign": 0}),
    "android": ("Android", "android/workbench.apk", {"package/unique_name": "org.portablemod.workbench", "architectures/armeabi-v7a": False, "architectures/arm64-v8a": True}),
    "ios": ("iOS", "ios/workbench.zip", {"application/bundle_identifier": "org.portablemod.workbench"}),
    "web": ("Web", "web/index.html", {"variant/extensions_support": False, "variant/thread_support": False, "html/canvas_resize_policy": 2}),
}


def clean(text: str) -> str:
    return text.replace(str(ROOT), "<repo>").replace(str(Path.home()), "<home>")


def run(command: list[str], cwd: Path, timeout: int = 180) -> dict:
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return {"exit_code": result.returncode, "output": clean(result.stdout + result.stderr)}
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or b"") + (exc.stderr or b"")
        return {"exit_code": 124, "output": clean(output.decode(errors="replace")) + "\nTimed out."}
    except OSError as exc:
        return {"exit_code": 127, "output": clean(str(exc))}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_manifest() -> list[dict]:
    paths = [ROOT / "workbench" / name for name in WORKBENCH]
    paths += [ROOT / "game/src/ext/loader" / name for name in CORE]
    paths += [ROOT / "LICENSE", Path(__file__).resolve()]
    return [{"path": path.relative_to(ROOT).as_posix(), "sha256": digest(path)} for path in sorted(paths)]


def copy(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"Expected regular source file: {source.relative_to(ROOT)}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def stage(destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for name in WORKBENCH:
        copy(ROOT / "workbench" / name, destination / name)
    for name in CORE:
        copy(ROOT / "game/src/ext/loader" / name, destination / "core" / name)
    copy(ROOT / "LICENSE", destination / "LICENSE.txt")
    lines = []
    for i, (target, (platform, _, options)) in enumerate(TARGETS.items()):
        lines.extend([
            f"[preset.{i}]", f'name="{target}"', f"platform={json.dumps(platform)}", "runnable=false",
            'export_filter="all_resources"', 'include_filter="fixtures/*.json,LICENSE.txt"',
            'exclude_filter="checks.gd"', 'export_path=""', "script_export_mode=1", "",
            f"[preset.{i}.options]",
        ])
        for key, value in options.items():
            lines.append(f"{key}={json.dumps(value)}")
        lines.append("")
    (destination / "export_presets.cfg").write_text("\n".join(lines), encoding="utf-8")


def verify(godot: str, staged: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    report_file = output / "checks.json"
    report_file.unlink(missing_ok=True)
    notices = output / "ENGINE-LICENSES.txt"
    notices.unlink(missing_ok=True)
    imported = run([godot, "--headless", "--path", str(staged), "--editor", "--import"], ROOT)
    checks = run([godot, "--headless", "--path", str(staged), "--script", "res://checks.gd", "--",
                  f"--licenses={notices}", f"--report={report_file}"], ROOT)
    smoke = run([godot, "--headless", "--path", str(staged), "--", "--smoke"], ROOT, timeout=30)
    for name, result in [("import", imported), ("checks", checks), ("smoke", smoke)]:
        (output / f"{name}.log").write_text(result["output"], encoding="utf-8")
    try:
        data = json.loads(report_file.read_text()) if report_file.exists() else {}
    except (ValueError, OSError):
        data = {}
    ok = all(r["exit_code"] == 0 and "SCRIPT ERROR" not in r["output"] and "\nERROR:" not in r["output"]
             for r in [imported, checks, smoke])
    ok = ok and data.get("failed") == 0 and data.get("passed", 0) >= 40 and "WORKBENCH SMOKE: ready" in smoke["output"]
    ok = ok and notices.is_file() and notices.stat().st_size > 0
    return {"ok": ok, "passed": data.get("passed", 0), "failed": data.get("failed"),
            "import_exit": imported["exit_code"], "checks_exit": checks["exit_code"], "smoke_exit": smoke["exit_code"]}


def export(godot: str, staged: Path, output: Path, target: str) -> dict:
    _, relative, _ = TARGETS[target]
    path = output / relative
    # Fresh target directory prevents an older artifact from being mistaken for a successful export.
    if path.parent.exists():
        shutil.rmtree(path.parent)
    path.parent.mkdir(parents=True)
    archive = output / f"workbench-{target}.zip"
    archive.unlink(missing_ok=True)
    mode = "--export-debug" if target in ("android", "ios") else "--export-release"
    result = run([godot, "--headless", "--path", str(staged), mode, target, str(path)], ROOT, timeout=300)
    (output / f"export-{target}.log").write_text(result["output"], encoding="utf-8")
    ok = result["exit_code"] == 0 and path.is_file() and "SCRIPT ERROR" not in result["output"] \
        and "\nERROR:" not in result["output"]
    status = "exported_unverified" if ok else "failed"
    smoke = None
    if ok and target == "linux" and sys.platform.startswith("linux") and os.uname().machine == "x86_64":
        smoke = run([str(path), "--headless", "--", "--smoke"], path.parent, timeout=30)
        (output / "linux-runtime.log").write_text(smoke["output"], encoding="utf-8")
        if smoke["exit_code"] == 0 and "WORKBENCH SMOKE: ready" in smoke["output"] \
                and "SCRIPT ERROR" not in smoke["output"] and "\nERROR:" not in smoke["output"]:
            status = "headless_smoke_passed"
        else:
            status = "runtime_failed"
    files = []
    if ok:
        shutil.copyfile(staged / "LICENSE.txt", path.parent / "LICENSE.txt")
        shutil.copyfile(output / "ENGINE-LICENSES.txt", path.parent / "ENGINE-LICENSES.txt")
        for file in sorted(path.parent.rglob("*")):
            if file.is_file():
                files.append({"path": file.relative_to(output).as_posix(), "bytes": file.stat().st_size,
                              "sha256": digest(file)})
    if ok and target in ("linux", "windows", "web"):
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for file in sorted(path.parent.rglob("*")):
                if file.is_file():
                    bundle.write(file, file.relative_to(path.parent))
    artifacts = []
    artifact = archive if archive.exists() else path
    if ok and artifact.is_file():
        artifacts.append({"path": artifact.relative_to(output).as_posix(), "sha256": digest(artifact), "bytes": artifact.stat().st_size})
    return {"status": status, "exit_code": result["exit_code"], "files": files, "artifacts": artifacts}


def integration(godot: str, output: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="loader-integration-") as temp:
        result = run([godot, "--headless", "--path", str(ROOT / "game"),
                      "res://debug/loader_integration_checks.tscn", "--", f"--save-dir={temp}"], ROOT, timeout=60)
    (output / "loader-integration.log").write_text(result["output"], encoding="utf-8")
    match = re.search(r"LOADER INTEGRATION: (\d+) passed, (\d+) failed", result["output"])
    passed, failed = map(int, match.groups()) if match else (0, -1)
    paths = [ROOT / "game/src/ext/extensions.gd", ROOT / "game/src/ext/sdt_extension.gd",
             ROOT / "game/debug/loader_integration_checks.gd"]
    paths += [ROOT / "game/src/ext/loader" / name for name in CORE]
    return {"ok": result["exit_code"] == 0 and failed == 0 and passed >= 17
            and "SCRIPT ERROR" not in result["output"] and "ERROR:" not in result["output"],
            "exit_code": result["exit_code"], "passed": passed, "failed": failed,
            "source_manifest": [{"path": p.relative_to(ROOT).as_posix(), "sha256": digest(p)} for p in paths]}


def package_results(output: Path) -> None:
    report = json.loads((output / "results.json").read_text())
    integrated = json.loads((output / "loader-integration.json").read_text())
    if report.get("source_manifest") != source_manifest() or not report.get("verification", {}).get("ok") \
            or not integrated.get("ok") or not integrated.get("source_manifest"):
        raise ValueError("Successful verification of the current sources is required before packaging")
    for entry in integrated.get("source_manifest", []):
        path = (ROOT / entry["path"]).resolve()
        if not path.is_relative_to(ROOT) or digest(path) != entry["sha256"]:
            raise ValueError("Integration sources changed after verification")
    artifacts = []
    for target in report["targets"].values():
        for entry in target.get("artifacts", []):
            path = (output / entry["path"]).resolve()
            if not path.is_relative_to(output) or digest(path) != entry["sha256"]:
                raise ValueError("Artifact changed after export")
            artifacts.append(path)
    if not artifacts:
        raise ValueError("No exported artifacts in the report")
    for entry in report["source_manifest"] + integrated["source_manifest"]:
        committed = subprocess.run(["git", "show", "HEAD:" + entry["path"]], cwd=ROOT,
                                   capture_output=True)
        if committed.returncode != 0 or hashlib.sha256(committed.stdout).hexdigest() != entry["sha256"]:
            raise ValueError("Verified source inputs must match committed HEAD before release packaging")
    report["release_revision"] = run(["git", "rev-parse", "HEAD"], ROOT)["output"].strip()
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    evidence = ["results.json", "checks.json", "loader-integration.json", "loader-integration.log",
                "import.log", "checks.log", "smoke.log", "linux-runtime.log", "ENGINE-LICENSES.txt"]
    evidence += [f"export-{target}.log" for target in report["targets"]]
    archive = output / "verification-results.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for name in evidence:
            path = output / name
            if path.is_file():
                bundle.write(path, name)
    artifacts.append(archive)
    (output / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in artifacts), encoding="utf-8")
    print("Packaged verified artifacts and results; failed target evidence is retained.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stage", "verify", "export", "integration", "package"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/portable")
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--target", action="append", choices=(*TARGETS, "all"))
    args = parser.parse_args()
    output = args.output.resolve()
    # Never delete/overwrite a source tree through --output.
    if output in ROOT.parents or (output.is_relative_to(ROOT) and not output.is_relative_to(ROOT / "build")):
        parser.error("output must be a separate build directory")
    marker = output / ".portable-workbench-output"
    if output.exists() and any(output.iterdir()) and not marker.is_file():
        parser.error("nonempty output directory is not owned by the portable build tool")
    output.mkdir(parents=True, exist_ok=True)
    marker.write_text("1\n", encoding="utf-8")
    if args.action == "package":
        package_results(output)
        return 0
    if args.action == "integration":
        report = integration(args.godot, output)
        (output / "loader-integration.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 0 if report["ok"] else 1
    with tempfile.TemporaryDirectory(prefix="portable-stage-") as temp:
        staged = Path(temp)
        stage(staged)
        if args.action == "stage":
            destination = output / "project"
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(staged, destination)
            print(f"Staged neutral project at {destination}")
            return 0
        checks = verify(args.godot, staged, output)
        version = run([args.godot, "--version"], ROOT)
        revision = run(["git", "rev-parse", "HEAD"], ROOT)
        report = {"schema": 1, "scope": "neutral_workbench", "engine": version["output"].strip(),
                  "source_revision": revision["output"].strip(), "source_manifest": source_manifest(),
                  "verification": checks, "targets": {}}
        targets = list(TARGETS) if "all" in (args.target or []) else list(dict.fromkeys(args.target or ["linux"]))
        if args.action == "export" and checks["ok"]:
            for target in targets:
                report["targets"][target] = export(args.godot, staged, output, target)
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        return 0 if checks["ok"] and all(t["status"] in ("exported_unverified", "headless_smoke_passed")
                                        for t in report["targets"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
