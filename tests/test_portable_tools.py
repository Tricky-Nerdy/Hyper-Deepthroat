"""Verify staging boundaries and publisher-checksum validation without downloads or model execution."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


class PortableToolBoundaries(unittest.TestCase):
    def test_source_directory_is_not_an_output(self):
        result = subprocess.run([sys.executable, str(ROOT / "tools/portable_release.py"), "stage",
                                 "--output", str(ROOT / "workbench")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("separate build directory", result.stderr)

    def test_nonempty_unowned_directory_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            sentinel = Path(temp) / "keep.txt"
            sentinel.write_text("unrelated work")
            result = subprocess.run([sys.executable, str(ROOT / "tools/portable_release.py"), "stage",
                                     "--output", temp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(sentinel.read_text(), "unrelated work")
            self.assertEqual(list(Path(temp).iterdir()), [sentinel])

    def test_staging_has_only_declared_sources(self):
        tool = module("portable_release", "portable_release.py")
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp)
            tool.stage(destination)
            expected = set(tool.WORKBENCH) | {"core/" + name for name in tool.CORE} | {"LICENSE.txt", "export_presets.cfg"}
            actual = {p.relative_to(destination).as_posix() for p in destination.rglob("*") if p.is_file()}
            self.assertEqual(actual, expected)

    def test_checksum_must_match_named_artifact(self):
        installer = module("install_godot_ci", "install_godot_ci.py")
        with tempfile.TemporaryDirectory() as temp:
            artifact = Path(temp) / "engine.zip"
            artifact.write_bytes(b"test toolchain")
            digest = hashlib.sha512(artifact.read_bytes()).hexdigest()
            installer.verify(artifact, digest + "  engine.zip\n")
            with self.assertRaises(ValueError):
                installer.verify(artifact, digest + "  unrelated.zip\n")
            artifact.write_bytes(b"changed toolchain")
            with self.assertRaises(ValueError):
                installer.verify(artifact, digest + "  engine.zip\n")


if __name__ == "__main__":
    unittest.main()
