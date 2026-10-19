"""Packaging-only regression checks. No game execution, SDK downloads, or device operations."""
import importlib.util
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("android_preview", ROOT / "tools/android_preview.py")
preview = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preview)


def manifest_fixture(*, version=1, shared_authority=False, startup_authority=None, shared_version=False):
    """Small AXML metadata fixture; not an executable Android application."""
    strings = []

    def index(text, fresh=False):
        if not fresh and text in strings:
            return strings.index(text)
        strings.append(text)
        return len(strings) - 1

    ns = index(preview.ANDROID_NS)
    prefix = index("android")

    def string_attr(key, text, *, android=True, fresh=False):
        value = index(text, fresh)
        return struct.pack("<IIIHBBI", ns if android else 0xffffffff, index(key), value, 8, 0, 3, value)

    def integer_attr(key, value):
        return struct.pack("<IIIHBBI", ns, index(key), 0xffffffff, 8, 0, 0x10, value)

    def start(name, attrs):
        name_index = index(name)
        return struct.pack("<HHIII", 0x102, 16, 36 + len(attrs) * 20, 1, 0xffffffff) \
            + struct.pack("<IIHHHHHH", 0xffffffff, name_index, 20, 20, len(attrs), 0, 0, 0) + b"".join(attrs)

    def end(name):
        return struct.pack("<HHIIIII", 0x103, 16, 24, 1, 0xffffffff, 0xffffffff, index(name))

    version_name = "0.1.0-debug-preview" if version == 1 else preview.VERSION_NAME
    root = start("manifest", [string_attr("package", preview.PACKAGE_ID, android=False),
                              integer_attr("versionCode", version), string_attr("versionName", version_name)])
    provider1 = start("provider", [string_attr("name", preview.FILE_PROVIDER),
                                   string_attr("authorities", preview.PACKAGE_ID + ".fileprovider")]) + end("provider")
    authority = startup_authority or preview.PACKAGE_ID + ".fileprovider"
    provider2 = start("provider", [string_attr("name", preview.STARTUP_PROVIDER),
                                   string_attr("authorities", authority, fresh=not shared_authority)]) + end("provider")
    extra = start("meta-data", [string_attr("name", "keep-version"), string_attr("value", version_name)]) + end("meta-data") if shared_version else b""
    body = root + provider1 + provider2 + extra + end("manifest")
    encoded, offsets = bytearray(), []
    for text in strings:
        payload = text.encode("utf-16le")
        offsets.append(len(encoded))
        encoded += struct.pack("<H", len(payload) // 2) + payload + b"\0\0"
    encoded += b"\0" * (-len(encoded) % 4)
    start_offset = 28 + len(strings) * 4
    pool = struct.pack("<HHIIIIII", 1, 28, start_offset + len(encoded), len(strings), 0, 0, start_offset, 0)
    pool += struct.pack("<" + "I" * len(offsets), *offsets) + encoded
    namespace_start = struct.pack("<HHIIIII", 0x100, 16, 24, 1, 0xffffffff, prefix, ns)
    namespace_end = struct.pack("<HHIIIII", 0x101, 16, 24, 1, 0xffffffff, prefix, ns)
    return struct.pack("<HHI", 3, 8, 8 + len(pool) + len(namespace_start) + len(body) + len(namespace_end)) + pool + namespace_start + body + namespace_end


def native_fixture(root, *, missing_map=False, wrong_x86=False):
    entries = {}
    mappings = ["[libraries]"]
    (root / "game/bin").mkdir(parents=True)
    for arch, info in preview.ARCHITECTURES.items():
        header = bytearray(64)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, 183 if wrong_x86 and arch == "x86_64" else info["elf_machine"])
        library = f"libsdt_native.android.template_debug.{arch}.so"
        entries["lib/" + info["abi"] + "/" + library] = bytes(header)
        (root / f"game/bin/sdt_native.android.template_debug.{arch}.so").write_bytes(header)
        if not missing_map or arch != "x86_64":
            mappings.append(f'android.debug.{arch}="res://bin/{library}"')
    entries["assets/bin/sdt_native.gdextension"] = ("\n".join(mappings) + "\n").encode()
    apk = root / "native-fixture.apk"
    with zipfile.ZipFile(apk, "w") as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return apk


class AndroidPreviewPackaging(unittest.TestCase):
    def test_native_prefix_and_reference_are_changed_only_in_stage(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "game/bin/sdt_native.android.template_debug.arm64.so"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"compiled fixture")
            extension = binary.parent / "sdt_native.gdextension"
            extension.write_text('[libraries]\nandroid.debug.arm64="res://bin/sdt_native.android.template_debug.arm64.so"\n')
            result = preview.configure_android_library(root)
            self.assertEqual((root / result["path"]).read_bytes(), b"compiled fixture")
            self.assertEqual(binary.read_bytes(), b"compiled fixture")
            self.assertIn('"res://bin/libsdt_native.android.template_debug.arm64.so"', extension.read_text())

    def test_compatibility_and_icons_are_packaging_settings_not_game_code(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            project = root / "project"
            project.mkdir()
            (project / "project.godot").write_text('config_version=5\n[application]\nconfig/features=PackedStringArray("4.7", "Forward Plus")\n[rendering]\n')
            original_script = b"# existing game script\n"
            (project / "main.gd").write_bytes(original_script)
            template = root / "template.apk"
            with zipfile.ZipFile(template, "w") as archive:
                for suffix in ("", "_foreground", "_background", "_monochrome"):
                    archive.writestr("res/mipmap-xxxhdpi-v4/icon" + suffix + ".webp", b"existing icon")
            preview.configure_game_import(project, template)
            config = (project / "project.godot").read_text()
            self.assertIn('renderer/rendering_method="gl_compatibility"', config)
            self.assertIn('renderer/rendering_method.mobile="gl_compatibility"', config)
            self.assertNotIn("Forward Plus", config)
            self.assertEqual((project / "main.gd").read_bytes(), original_script)
            self.assertEqual((project / "godot_export_template_icon.webp").read_bytes(), b"existing icon")

    def test_manifest_repair_separates_authorities_and_updates_versions(self):
        original = manifest_fixture()
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            preview.manifest_identity(original, require_v2=False)
        repaired = preview.repair_manifest(original)
        identity = preview.manifest_identity(repaired)
        self.assertEqual(identity["version_code"], 2)
        self.assertEqual(identity["version_name"], "0.1.1-debug-preview")
        self.assertEqual(identity["provider_authorities"][preview.FILE_PROVIDER], preview.PACKAGE_ID + ".fileprovider")
        self.assertEqual(identity["provider_authorities"][preview.STARTUP_PROVIDER], preview.PACKAGE_ID + ".androidx-startup")
        self.assertEqual(preview.repair_manifest(repaired), repaired)
        self.assertEqual(preview.BinaryManifest(original).root["versionCode"]["value"], 1)

    def test_shared_string_pool_values_do_not_change_other_provider_or_metadata(self):
        original = manifest_fixture(shared_authority=True, shared_version=True)
        repaired = preview.BinaryManifest(preview.repair_manifest(original))
        identity = preview.manifest_identity(repaired.encode())
        self.assertEqual(identity["provider_authorities"][preview.FILE_PROVIDER], preview.PACKAGE_ID + ".fileprovider")
        metadata = next(n for n in repaired.nodes if n["name"] == "meta-data")
        self.assertEqual(repaired.text(metadata["attrs"]["value"]), "0.1.0-debug-preview")

    def test_v3_upgrade_preserves_v2_and_is_idempotent_without_global_overrides(self):
        original = preview.repair_manifest(manifest_fixture())
        version = {"version_code": 3, "version_name": "0.1.2-debug-preview"}
        repaired = preview.repair_manifest(original, **version)
        self.assertEqual(preview.manifest_identity(repaired, **version)["version_code"], 3)
        self.assertEqual(preview.repair_manifest(repaired, **version), repaired)
        self.assertEqual(preview.manifest_identity(original)["version_code"], 2)
        with self.assertRaisesRegex(ValueError, "downgrade"):
            preview.repair_manifest(repaired)

    def test_invalid_version_or_name_cannot_be_exported_or_injected_into_configuration(self):
        for code, name in ((0, "0"), (3, "wrong-v3-name"), (4, 'name"\n[autoload]'), (4, "")):
            with self.subTest(code=code, name=name), self.assertRaises(ValueError):
                preview.validate_version(code, name)

    def test_explicit_v3_preset_keeps_v2_defaults_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "game").mkdir()
            preset = preview.write_export_preset(root, root, version_code=3, version_name="0.1.2-debug-preview")
            self.assertIn("version/code=3", preset)
            self.assertIn('version/name="0.1.2-debug-preview"', preset)
            self.assertIn("version/code=2", preview.write_export_preset(root, root))

    def test_manifest_bounds_and_unsupported_pool_encoding_are_rejected(self):
        original = manifest_fixture()
        with self.assertRaises(ValueError):
            preview.repair_manifest(original[:-1])
        utf8 = bytearray(original)
        struct.pack_into("<I", utf8, 24, 0x100)
        with self.assertRaisesRegex(ValueError, "UTF-16"):
            preview.repair_manifest(utf8)

    def test_unknown_authority_is_not_silently_rewritten(self):
        with self.assertRaisesRegex(ValueError, "Startup"):
            preview.repair_manifest(manifest_fixture(startup_authority="unexpected.authority"))

    def test_missing_compiled_resource_and_stale_jar_records_are_prepared_before_signing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "templates").mkdir()
            resource = "res/mipmap-anydpi-v26/themed_icon.xml"
            with zipfile.ZipFile(root / "templates/android_debug.apk", "w") as template:
                template.writestr(resource, b"existing compiled XML")
            apk = root / "preview.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", manifest_fixture())
                archive.writestr("resources.arsc", b"existing table")
                archive.writestr("classes.dex", b"existing dex bytes")
                for name in ("ANDROIDD.RSA", "ANDROIDD.SF", "MANIFEST.MF"):
                    archive.writestr("META-INF/" + name, b"old signer")
                archive.writestr("META-INF/services/keep", b"existing service")
            original_hash = preview.sha(apk)
            target = root / "prepared.apk"
            result = preview.prepare_apk_for_signing(apk, target, root / "templates/android_debug.apk")
            self.assertTrue(result["themed_resource_restored"])
            self.assertEqual(len(result["removed_jar_signing_entries"]), 3)
            self.assertEqual(preview.sha(apk), original_hash)
            with zipfile.ZipFile(target) as archive:
                self.assertEqual(archive.read(resource), b"existing compiled XML")
                self.assertEqual(archive.read("classes.dex"), b"existing dex bytes")
                self.assertEqual(archive.read("META-INF/services/keep"), b"existing service")
                self.assertFalse(any(preview.jar_signing_entry(n) for n in archive.namelist()))
                self.assertEqual(archive.getinfo("resources.arsc").compress_type, zipfile.ZIP_STORED)
            with self.assertRaises(ValueError):
                preview.prepare_apk_for_signing(apk, apk, root / "templates/android_debug.apk")

    def test_finalization_is_non_destructive_and_explicitly_uses_only_v2_v3_signing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "templates").mkdir()
            with zipfile.ZipFile(root / "templates/android_debug.apk", "w") as archive:
                archive.writestr("res/mipmap-anydpi-v26/themed_icon.xml", b"compiled template XML")
            source, target = root / "source.apk", root / "final.apk"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("AndroidManifest.xml", manifest_fixture())
            original_hash = preview.sha(source)
            calls = []

            def execute(command, *_args, **_kwargs):
                calls.append(command)
                if Path(command[0]).name == "zipalign":
                    shutil.copyfile(command[-2], command[-1])
                else:
                    shutil.copyfile(command[-1], command[command.index("--out") + 1])

            with mock.patch.object(preview, "execute", execute):
                preview.finalize_apk(source, target, root, root / "sdk", {})
                with self.assertRaises(ValueError):
                    preview.finalize_apk(source, target, root, root / "sdk", {})
            self.assertEqual(preview.sha(source), original_hash)
            self.assertEqual(len(calls), 2)
            self.assertIn("16", calls[0])
            for flag, value in (("--v1-signing-enabled", "false"), ("--v2-signing-enabled", "true"),
                                ("--v3-signing-enabled", "true"), ("--v4-signing-enabled", "false")):
                self.assertEqual(calls[1][calls[1].index(flag) + 1], value)

    def test_preset_defaults_to_version2_dual64(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "game").mkdir()
            preset = preview.write_export_preset(root, root)
            for line in ('architectures/arm64-v8a=true', 'architectures/x86_64=true', 'version/code=2',
                         'version/name="0.1.1-debug-preview"', 'architectures/armeabi-v7a=false'):
                self.assertIn(line, preset)
            self.assertEqual(preview.write_export_preset(root, root), preset)

    def test_both_native_builds_get_correct_nonduplicated_extension_references(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary_dir = root / "game/bin"
            binary_dir.mkdir(parents=True)
            extension = binary_dir / "sdt_native.gdextension"
            extension.write_text('[configuration]\nentry_symbol="sdt_native_init"\n[libraries]\n[dependencies]\n')
            for arch in preview.DEFAULT_ARCHITECTURES:
                (binary_dir / f"sdt_native.android.template_debug.{arch}.so").write_bytes(arch.encode())
                preview.configure_android_library(root, arch)
                preview.configure_android_library(root, arch)
                line = f'android.debug.{arch}="res://bin/libsdt_native.android.template_debug.{arch}.so"'
                self.assertEqual(extension.read_text().count(line), 1)
                self.assertEqual(extension.read_text().count(f'android.{arch}="res://bin/libsdt_native.android.template_debug.{arch}.so"'), 1)
            self.assertIn('entry_symbol="sdt_native_init"', extension.read_text())

    def test_android_preview_fallback_drops_only_its_dangling_release_mapping(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "game/bin/sdt_native.android.template_debug.arm64.so"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"compiled fixture")
            extension = binary.parent / "sdt_native.gdextension"
            desktop = 'linux.release.x86_64="res://bin/desktop.so"'
            extension.write_text('[libraries]\nandroid.release.arm64="res://bin/unbuilt.so"\n' + desktop + '\n')
            preview.configure_android_library(root)
            self.assertNotIn("android.release.arm64", extension.read_text())
            self.assertIn(desktop, extension.read_text())
            self.assertIn('android.arm64="res://bin/libsdt_native.android.template_debug.arm64.so"', extension.read_text())

    def test_v3_native_verifier_does_not_accept_debug_only_mappings(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apk = native_fixture(root)
            with zipfile.ZipFile(apk) as archive:
                with self.assertRaisesRegex(RuntimeError, "ABI fallback"):
                    preview.verify_native_archive(archive, root, require_runtime_fallback=True)

    def test_dual64_elf_mapping_and_build_hash_verification(self):
        for failure in (None, "mapping", "elf"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                apk = native_fixture(root, missing_map=failure == "mapping", wrong_x86=failure == "elf")
                with zipfile.ZipFile(apk) as archive:
                    if failure:
                        with self.assertRaises(RuntimeError):
                            preview.verify_native_archive(archive, root)
                    else:
                        self.assertEqual(preview.verify_native_archive(archive, root)["abis"], ["arm64-v8a", "x86_64"])

    def test_architecture_selection_rejects_32bit_duplicate_or_empty_values(self):
        for architectures in ((), ("arm32",), ("arm64", "arm64")):
            with self.assertRaises(ValueError):
                preview.normalize_architectures(architectures)

    def verify_fixture(self, signature, warning=""):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            logs = root / "logs"
            logs.mkdir()
            (logs / "apk-badging.log").write_text(warning + f"package: name='{preview.PACKAGE_ID}' versionCode='2' versionName='{preview.VERSION_NAME}'\napplication-debuggable\nnative-code: 'arm64-v8a' 'x86_64'\n")
            (logs / "apk-manifest.log").write_text('android:required(0x0101028e)=true\n')
            (logs / "apk-signature.log").write_text(signature)
            with zipfile.ZipFile(root / "fixture.apk", "w") as archive:
                archive.writestr("AndroidManifest.xml", preview.repair_manifest(manifest_fixture()))
            with mock.patch.object(preview, "execute", return_value={}):
                with self.assertRaises(RuntimeError) as error:
                    preview.verify_apk(root / "fixture.apk", root, root / "sdk", root / "jdk", {})
            return str(error.exception)

    def test_resource_warning_cannot_pass_even_when_inspector_exit_is_zero(self):
        self.assertIn("warning or error", self.verify_fixture("CN=Android Debug", "warn: missing resource\n"))

    def test_both_v2_and_v3_signatures_are_required(self):
        self.assertIn("Both APK v2 and v3", self.verify_fixture("CN=Android Debug\nVerified using v2 scheme (APK Signature Scheme v2): true\n"))

    def test_verifier_rejects_duplicate_provider_authorities_before_external_tools(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            apk = root / "duplicate-providers.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", manifest_fixture(version=2))
            with mock.patch.object(preview, "execute") as execute:
                with self.assertRaisesRegex(ValueError, "Duplicate"):
                    preview.verify_apk(apk, root, root, root, {})
                execute.assert_not_called()

    def test_frozen_baseline_repair_matches_exact_candidate_manifest_read_only(self):
        build = ROOT / "build/android-game-preview"
        baseline, candidate = build / "luma-audit-c552-delivered.apk", build / "luma-candidate-v2-arm64.apk"
        if not baseline.exists() or not candidate.exists():
            self.skipTest("frozen local audit artifacts are optional")
        expected = {baseline: "c552fd7ceab2048589e63736e05b8fbe2d7517dad4380850f288fc062bbd164e",
                    candidate: "4258ae928e36cf4f48f33083470ec4b006e580c8742d19ee6972bf9756754cfe"}
        for path, digest in expected.items():
            self.assertEqual(preview.sha(path), digest)

        with zipfile.ZipFile(baseline) as old, zipfile.ZipFile(candidate) as fixed:
            self.assertEqual(preview.repair_manifest(old.read("AndroidManifest.xml")), fixed.read("AndroidManifest.xml"))
        for path, digest in expected.items():
            self.assertEqual(preview.sha(path), digest)


if __name__ == "__main__":
    unittest.main()
