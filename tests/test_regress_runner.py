"""Exercise regression-runner failure accounting with a neutral fake engine, not gameplay."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE_ENGINE = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
if "--driver=res://debug/ext_checks.gd" in args:
    print("EXT CHECKS: 1 passed, 0 failed")
elif "--driver=res://debug/da_checks.gd" in args:
    print("DA CHECKS: 1 passed, 0 failed")
elif "--driver=res://debug/menu_checks.gd" in args:
    if os.environ["MODE"] != "menu_missing":
        print("MENU CHECKS: 1 passed, 0 failed")
    if os.environ["MODE"] == "menu_error":
        print("SCRIPT ERROR: neutral menu fixture failure")
        print("   at: fixture (menu_checks.gd:1)")
    sys.exit(7 if os.environ["MODE"] == "menu_exit" else 0)
elif "--driver=res://debug/stress_costumes.gd" in args:
    print("STRESS neutral fixture")
    sys.exit(7 if os.environ["MODE"] == "stress_exit" else 0)
else:
    out = Path(next(a.split("=", 1)[1] for a in args if a.startswith("--out=")))
    (out / "probe_one.json").write_text("one\\n")
    if os.environ["MODE"] != "missing_dump":
        (out / "probe_two.json").write_text("two\\n")
    sys.exit(9 if os.environ["MODE"] == "scenario_exit" else 0)
'''


@unittest.skipUnless(shutil.which("bash"), "requires the existing POSIX runner")
class RegressionAccounting(unittest.TestCase):
    def run_fixture(self, mode, stress=False):
        with tempfile.TemporaryDirectory(prefix="regress-runner-") as temp:
            root = Path(temp)
            (root / "tools").mkdir()
            (root / "tests/golden").mkdir(parents=True)
            (root / "tests/plugins/example").mkdir(parents=True)
            (root / "game").mkdir()
            (root / "tests/golden/probe_one.json").write_text("one\n")
            (root / "tests/golden/probe_two.json").write_text("two\n")
            script = root / "tools/regress.sh"
            shutil.copyfile(ROOT / "tools/regress.sh", script)
            engine = root / "fake-godot"
            engine.write_text(FAKE_ENGINE)
            engine.chmod(0o755)
            env = dict(os.environ, GODOT=str(engine), MODE=mode, TMPDIR=temp)
            result = subprocess.run(["bash", str(script), "probe"] + (["--stress"] if stress else []),
                                    env=env, capture_output=True, text=True, timeout=20)
            return result.returncode, result.stdout + result.stderr

    def test_complete_matching_outputs_pass(self):
        code, output = self.run_fixture("ok")
        self.assertEqual(code, 0, output)

    def test_nonzero_scenario_cannot_pass_on_matching_dumps(self):
        code, output = self.run_fixture("scenario_exit")
        self.assertNotEqual(code, 0, output)
        self.assertIn("scenario process exited", output)

    def test_partial_matching_dump_set_fails(self):
        code, output = self.run_fixture("missing_dump")
        self.assertNotEqual(code, 0, output)
        self.assertIn("expected dump missing", output)

    def test_menu_check_failure_is_not_hidden_by_matching_scenarios(self):
        for mode in ("menu_exit", "menu_missing", "menu_error"):
            with self.subTest(mode=mode):
                code, output = self.run_fixture(mode)
                self.assertNotEqual(code, 0, output)
                self.assertIn("FAIL", output)

    def test_stress_exit_propagates(self):
        code, output = self.run_fixture("stress_exit", stress=True)
        self.assertNotEqual(code, 0, output)


if __name__ == "__main__":
    unittest.main()
