"""Guard and fixture tests for compositor-level neutral GUI input. No desktop input is sent here."""
import hashlib
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gui_debug", ROOT / "tools/gui_debug.py")
gui = importlib.util.module_from_spec(spec)
with mock.patch.object(sys, "path", [str(ROOT / "tools")] + sys.path):
    spec.loader.exec_module(gui)


class Recorder:
    def __init__(self, fail_down=False):
        self.events = []
        self.fail_down = fail_down

    def emit(self, event, **fields):
        if self.fail_down and fields.get("state") == "down":
            raise OSError("fixture log write failure")
        self.events.append(dict(event=event, **fields))


class GuiInputGuards(unittest.TestCase):
    def test_key_down_guards_focus_pid_and_address_with_explicit_modifiers(self):
        lua = gui.key_lua("0xabc", 123, "a", "CTRL", "down")
        self.assertIn("w.pid==123", lua)
        self.assertIn("a.address==w.address", lua)
        self.assertIn('mods="CTRL"', lua)
        self.assertIn('window="address:0xabc"', lua)
        up = gui.key_lua("0xabc", 123, "a", "CTRL", "up")
        self.assertIn("w.pid==123", up)
        self.assertIn('state="up"', up)
        self.assertNotIn("get_active_window", up)

    def test_invalid_identity_keys_and_modifiers_are_rejected(self):
        for arguments in (("0x1;hl.exit()", 1, "a", "", "down"), ("0x1", True, "a", "", "down"),
                          ("0x1", 0, "a", "", "down"), ("0x1", 1, "Super_L", "", "down"),
                          ("0x1", 1, "a", "SUPER", "down"), ("0x1", 1, "a", "", "held")):
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                gui.key_lua(*arguments)

    def test_window_discovery_never_selects_another_pid_or_ambiguous_surface(self):
        owned = {"pid": 123, "address": "0xabc", "mapped": True, "hidden": False}
        foreign = dict(owned, pid=999, address="0xdef")
        self.assertEqual(gui.owned_window([foreign, owned], 123), owned)
        for clients in ([foreign], [owned, dict(owned, address="0x123")], [dict(owned, hidden=True)]):
            with self.assertRaises(RuntimeError):
                gui.owned_window(clients, 123)

    def test_lua_error_text_is_failure_even_with_zero_cli_exit(self):
        result = SimpleNamespace(returncode=0, stdout="error: FOCUS_CHANGED", stderr="")
        with mock.patch.object(gui.subprocess, "run", return_value=result), self.assertRaises(RuntimeError):
            gui.shell(["hyprctl", "eval", "fixture"])

    def test_interruption_releases_key_to_the_same_owned_window(self):
        keyboard = gui.Keyboard({"address": "0xabc", "pid": 123}, Recorder())
        with mock.patch.object(gui, "shell", return_value="ok") as send, \
                mock.patch.object(gui.time, "sleep", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                keyboard.press("a", "CTRL")
        self.assertEqual(send.call_count, 2)
        self.assertIn('state="down"', send.call_args_list[0].args[0][-1])
        self.assertIn('state="up"', send.call_args_list[1].args[0][-1])
        self.assertTrue(all('window="address:0xabc"' in call.args[0][-1] for call in send.call_args_list))

    def test_log_failure_after_key_down_still_sends_key_up(self):
        keyboard = gui.Keyboard({"address": "0xabc", "pid": 123}, Recorder(fail_down=True))
        with mock.patch.object(gui, "shell", return_value="ok") as send:
            with self.assertRaises(OSError):
                keyboard.press("a", "CTRL")
        self.assertEqual(send.call_count, 2)
        self.assertIn('state="up"', send.call_args_list[1].args[0][-1])

    def test_save_path_must_stay_inside_the_temporary_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = root / "data/workbench.json"
            self.assertEqual(gui.isolated_save_path({"save_path": str(expected)}, root), expected)
            with self.assertRaises(ValueError):
                gui.isolated_save_path({"save_path": "/outside/workbench.json"}, root)
            with self.assertRaises(ValueError):
                gui.isolated_save_path({"save_path": str(root / "data/other.json")}, root)

    def test_observer_fixture_keeps_original_handlers_and_shared_core_unchanged(self):
        main = ROOT / "workbench/main.gd"
        before = hashlib.sha256(main.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            gui.fixture(project)
            self.assertEqual((project / "main.gd").read_bytes(), main.read_bytes())
            self.assertEqual((project / "core/asset_commands.gd").read_bytes(), (ROOT / "game/src/ext/loader/asset_commands.gd").read_bytes())
            self.assertIn('name="GuiObserver"', (project / "main.tscn").read_text())
        self.assertEqual(hashlib.sha256(main.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
