"""Actual headless Godot, staged source and generated neutral library; no Android tools or artifacts."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ModShutdown(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("godot"), "requires Linux and Godot")
    def test_neutral_mod_cycles_are_released_and_shutdown_is_repeatable(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        # Unique staging directory; never reuse or modify a packaged preview or original import cache.
        with tempfile.TemporaryDirectory(prefix="independent-mod-shutdown-", dir=build) as temp:
            work = Path(temp)
            project = work / "game"
            shutil.copytree(ROOT / "game", project, ignore=shutil.ignore_patterns(
                ".godot", "assets", "export_presets.cfg", "export_credentials.cfg"))
            library = project / "assets/sdt"
            library.mkdir(parents=True)
            (library / "library.json").write_text(json.dumps({"chars": {}, "classes": {}, "root": {}}))
            shutil.copy2(ROOT / "tools/fixtures/mod_shutdown_checks.gd", project / "mod_shutdown_checks.gd")
            (project / "mod_shutdown_checks.tscn").write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://mod_shutdown_checks.gd" id="1"]\n[node name="NeutralOwnershipChecks" type="Node"]\nscript=ExtResource("1")\n')
            (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Neutral ownership checks"\nrun/main_scene="res://mod_shutdown_checks.tscn"\n[autoload]\nFlash="*res://flash/flash_runtime.gd"\ng="*res://src/g.gd"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            env = dict(os.environ, TMPDIR=str(work))
            for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
                env[key] = str(work / key)
            for label, extra in (("import", ["--editor", "--import"]), ("ownership", ["--quit-after", "5"])):
                try:
                    result = subprocess.run(["godot", "--headless", "--path", str(project), *extra],
                                            cwd=ROOT, env=env, capture_output=True, text=True, timeout=20)
                except subprocess.TimeoutExpired as exc:
                    text = (exc.stdout or b"") + (exc.stderr or b"")
                    self.fail("Godot timed out: " + text.decode(errors="replace")[-6000:])
                text = result.stdout + result.stderr
                details = "\n".join(text.splitlines()[-30:])
                self.assertEqual(result.returncode, 0, details)
                self.assertFalse("SCRIPT ERROR" in text or "ERROR:" in text, details)
                if label == "ownership":
                    self.assertIn("MOD_SHUTDOWN_CHECKS_OK", text)


if __name__ == "__main__":
    unittest.main()
