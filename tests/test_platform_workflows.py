"""Build configuration and installer boundaries only; no export, SDK, device or external network calls."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


planner = load("game_build_plan")
installer = load("install_godot_ci")
android_packaging = load("android_preview")


class PlatformWorkflows(unittest.TestCase):
    def test_future_android_presets_opt_in_without_running_android_tools(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "game").mkdir()
            version = {"version_code": 4, "version_name": "0.1.3-local-ai-review"}
            offline = android_packaging.write_export_preset(root, root, **version)
            self.assertIn("permissions/internet=false", offline)
            online = android_packaging.write_export_preset(root, root, **version, enable_ai_network=True)
            self.assertIn("permissions/internet=true", online)
            self.assertIn('custom_features="local_ai_network"', online)
            with self.assertRaises(ValueError):
                android_packaging.write_export_preset(root, root, version_code=3,
                                                     version_name="0.1.2-debug-preview", enable_ai_network=True)

    def test_all_six_targets_are_configured_not_claimed_tested(self):
        plan = planner.plan(True)
        self.assertEqual(set(plan["targets"]), {"linux", "windows", "macos", "android", "ios", "web"})
        self.assertFalse(plan["exports_performed"])
        self.assertFalse(plan["all_platform_runtime_verified"])
        for target in plan["targets"].values():
            self.assertTrue(target["configured"])
            self.assertFalse(target["runtime_verified"])
            self.assertTrue(target["blockers"])

    def test_network_permission_requires_an_explicit_build_option(self):
        offline = planner.export_presets(False)
        online = planner.export_presets(True)
        self.assertIn("permissions/internet=false", offline)
        self.assertNotIn('custom_features="local_ai_network"', offline)
        self.assertIn("permissions/internet=true", online)
        self.assertIn('custom_features="local_ai_network"', online)
        self.assertIn("NSLocalNetworkUsageDescription", online)
        self.assertNotIn("NSAllowsArbitraryLoads", online)
        self.assertEqual(online.count('export_filter="all_resources"'), 6)

    def test_protected_android_and_source_directories_are_rejected_before_writes(self):
        for path in (ROOT / "game", ROOT / "build", planner.PROTECTED / "must-not-create"):
            with self.assertRaises(ValueError):
                planner.prepare(path)

    def test_plan_has_source_hashes_without_exporting_or_overwriting(self):
        (ROOT / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="platform-plan-test-", dir=ROOT / "build") as temp:
            output = Path(temp) / "plan"
            result = planner.prepare(output, network_enabled=True)
            self.assertTrue(result["provider_sources"])
            self.assertFalse(result["game_staged"])
            self.assertEqual(json.loads((output / "plan.json").read_text()), result)
            self.assertFalse(list(output.rglob("*.apk")))
            with self.assertRaises(FileExistsError):
                planner.prepare(output)

    def test_engine_selection_covers_desktop_hosts_and_rejects_unknown_hosts(self):
        for system, arch in (("Linux", "x86_64"), ("Linux", "aarch64"), ("Windows", "AMD64"), ("Darwin", "arm64"), ("Darwin", "x86_64")):
            archive, executable = installer.engine_spec("4.7.2", system, arch)
            self.assertTrue(archive.endswith(".zip"))
            self.assertTrue(executable)
        with self.assertRaises(ValueError):
            installer.engine_spec("4.7.2", "Windows", "unknown")

    def test_archive_traversal_symlink_and_overwrite_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "bin"
            output.mkdir()
            for filename, symlink in (("../escape", False), ("C:/escape", False), ("bad\\escape", False), ("link", True)):
                archive = root / "malicious.zip"
                with zipfile.ZipFile(archive, "w") as z:
                    info = zipfile.ZipInfo(filename)
                    if symlink:
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    z.writestr(info, b"target")
                with self.assertRaises(ValueError):
                    installer.extract_engine(archive, output, "engine", "Linux")
            archive = root / "valid.zip"
            with zipfile.ZipFile(archive, "w") as z:
                z.writestr("engine", b"fixture executable, not run")
            installed = installer.extract_engine(archive, output, "engine", "Linux")
            self.assertEqual(installed.read_bytes(), b"fixture executable, not run")
            with self.assertRaises(FileExistsError):
                installer.extract_engine(archive, output, "engine", "Linux")

    def test_engine_only_install_verifies_without_fetching_templates(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            name = "Godot_v4.7.2-stable_linux.x86_64.zip"
            archive = root / "fixture.zip"
            with zipfile.ZipFile(archive, "w") as z:
                z.writestr(name.removesuffix(".zip"), b"fixture executable, not run")
            digest = hashlib.sha512(archive.read_bytes()).hexdigest()
            requests = []

            def download(url, destination):
                requests.append(destination.name)
                if destination.name == "SHA512-SUMS.txt":
                    destination.write_text(digest + "  " + name + "\n")
                else:
                    shutil.copyfile(archive, destination)

            with mock.patch.object(installer, "download", download), mock.patch.object(installer.platform, "system", return_value="Linux"), \
                    mock.patch.object(installer.platform, "machine", return_value="x86_64"), \
                    mock.patch.object(sys, "argv", ["installer", "--engine-only", "--bin-dir", str(root / "bin")]), \
                    mock.patch.dict(os.environ, {"GITHUB_ENV": str(root / "github-env"), "GITHUB_PATH": str(root / "github-path")}):
                installer.main()
            self.assertEqual(requests, ["SHA512-SUMS.txt", name])
            self.assertIn("GODOT=", (root / "github-env").read_text())
            with self.assertRaises(ValueError):
                installer.verify(root / "bin/godot", "0" * 128 + "  godot\n")


if __name__ == "__main__":
    unittest.main()
