"""Neutral actual-Godot path-policy check. Does not load the game's autoloads or third-party assets."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ContentPaths(unittest.TestCase):
    @unittest.skipUnless(shutil.which("godot"), "Godot is not installed")
    def test_sandboxed_targets_use_private_data_and_desktop_paths_remain_unchanged(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="content-path-check-", dir=build) as temp:
            project = Path(temp)
            shutil.copy2(ROOT / "game/flash/content_paths.gd", project / "content_paths.gd")
            (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Neutral content path checks"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            (project / "checks.gd").write_text('''extends SceneTree

func _initialize() -> void:
	var policy = load("res://content_paths.gd")
	var cases := [
		["Android", false, "/project/game/", "/system/bin/app_process64", "/data/user/0/example/files", "/data/user/0/example/files"],
		["iOS", false, "/project/game/", "/app/Game", "/private/app/Documents", "/private/app/Documents"],
		["Web", false, "/project/game/", "", "/userfs/data", "/userfs/data"],
		["Linux", false, "/project/game/", "/opt/game/game", "/home/user/data", "/opt/game"],
		["Windows", false, "C:/project/game/", "C:/Games/Game.exe", "C:/Users/User/Data", "C:/Games"],
		["macOS", false, "/project/game/", "/Apps/Game.app/Contents/MacOS/Game", "/Users/user/data", "/Apps/Game.app/Contents/MacOS"],
		["Linux", true, "/project/game/", "/usr/bin/godot", "/home/user/data", "/project"],
		["Windows", true, "C:/project/game/", "C:/Godot.exe", "C:/Users/User/Data", "C:/project"],
	]
	for item in cases:
		var actual: String = policy.root(item[0], item[1], item[2], item[3], item[4])
		if actual != item[5]:
			push_error("Path policy: %s != %s" % [actual, item[5]])
			quit(1)
			return
	print("CONTENT_PATH_CHECKS_OK 8")
	quit(0)
''')
            env = dict(os.environ)
            for name in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
                env[name] = str(project / name)
            result = subprocess.run(["godot", "--headless", "--path", str(project), "--script", "checks.gd"],
                                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("CONTENT_PATH_CHECKS_OK 8", result.stdout)
            self.assertNotIn("SCRIPT ERROR", result.stderr)


if __name__ == "__main__":
    unittest.main()
