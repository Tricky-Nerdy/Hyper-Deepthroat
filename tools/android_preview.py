#!/usr/bin/env python3
"""Local DEBUG APK packaging of the EXISTING game; no workbench substitution or device installation.

SDK packages, signing material, editor profile, staged sources and logs stay inside the build directory.
No gameplay/assets/dialogue are generated or modified. Only staged export/import settings are configured.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ID = "org.sdtgodot.preview"
VERSION_CODE = 2
VERSION_NAME = "0.1.1-debug-preview"
KNOWN_VERSIONS = {1: "0.1.0-debug-preview", 2: VERSION_NAME, 3: "0.1.2-debug-preview"}
ARCHITECTURES = {
    "arm64": {"abi": "arm64-v8a", "elf_machine": 183},
    "x86_64": {"abi": "x86_64", "elf_machine": 62},
}
DEFAULT_ARCHITECTURES = ("arm64", "x86_64")
ANDROID_NS = "http://schemas.android.com/apk/res/android"
FILE_PROVIDER = "androidx.core.content.FileProvider"
STARTUP_PROVIDER = "androidx.startup.InitializationProvider"
NDK = "28.1.13356709"
BUILD_TOOLS = "36.0.0"
# The installed 4.7.2 debug template reports compile/target API 36.
PACKAGES = ["platform-tools", "build-tools;" + BUILD_TOOLS, "platforms;android-36", "ndk;" + NDK]


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class BinaryManifest:
    """Bounded reader/editor for the unstyled UTF-16 AXML emitted by this Godot template.

    Existing attribute types/resource IDs and all non-manifest content are preserved. Unsupported
    encodings fail closed. Shared value strings get a new pool entry rather than changing other fields.
    """

    def __init__(self, original):
        self.data = bytearray(original)
        self.nodes, self.references, self.structural = [], {}, set()
        if len(original) < 36 or len(original) > 4 * 1024 * 1024:
            raise ValueError("Manifest size outside supported bounds")
        if struct.unpack_from("<HHI", original) != (3, 8, len(original)):
            raise ValueError("Unexpected binary XML header")
        kind, header, self.pool_size = struct.unpack_from("<HHI", original, 8)
        count, styles, flags, self.strings_start, styles_start = struct.unpack_from("<IIIII", original, 16)
        if kind != 1 or header != 28 or styles or flags or styles_start or count > 65536:
            raise ValueError("Expected an unstyled UTF-16 manifest string pool")
        if not 28 + count * 4 <= self.strings_start <= self.pool_size <= len(original) - 8:
            raise ValueError("Invalid manifest string pool bounds")
        self.original_count = count
        self.strings = []
        for index in range(count):
            position = 8 + self.strings_start + struct.unpack_from("<I", original, 36 + index * 4)[0]
            if position < 8 + self.strings_start or position + 2 > 8 + self.pool_size:
                raise ValueError("Manifest string offset outside pool")
            length = struct.unpack_from("<H", original, position)[0]
            end = position + 2 + length * 2
            if length >= 32768 or end + 2 > 8 + self.pool_size or original[end:end + 2] != b"\0\0":
                raise ValueError("Invalid manifest string encoding")
            self.strings.append(original[position + 2:end].decode("utf-16le"))
        offset = 8 + self.pool_size
        while offset < len(original):
            if offset + 8 > len(original):
                raise ValueError("Truncated XML chunk")
            kind, header, size = struct.unpack_from("<HHI", original, offset)
            if header < 8 or size < header or offset + size > len(original):
                raise ValueError("Malformed XML chunk")
            if kind == 0x102:
                if header != 16 or size < 36:
                    raise ValueError("Invalid element chunk")
                namespace, name, attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", original, offset + 16)
                self._structural(namespace, name)
                if attr_size != 20 or attr_start < 20 or 16 + attr_start + attr_size * attr_count > size:
                    raise ValueError("Invalid attribute bounds")
                attrs = {}
                for index in range(attr_count):
                    at = offset + 16 + attr_start + attr_size * index
                    ns, key, raw, value_size, reserved, typ, value = struct.unpack_from("<IIIHBBI", original, at)
                    self._structural(ns, key)
                    if value_size != 8 or reserved or self._string(key) in attrs:
                        raise ValueError("Unexpected/duplicate attribute encoding")
                    if raw != 0xffffffff:
                        self._reference(raw, at)
                    if typ == 3:
                        self._reference(value, at)
                    attrs[self._string(key)] = {"type": typ, "value": value, "raw": raw, "offset": at, "ns": ns}
                self.nodes.append({"name": self._string(name), "attrs": attrs})
            elif kind in (0x100, 0x101, 0x103):
                if size < 24:
                    raise ValueError("Truncated namespace/end-element chunk")
                self._structural(*struct.unpack_from("<II", original, offset + 16))
            offset += size
        roots = [n for n in self.nodes if n["name"] == "manifest"]
        if len(roots) != 1:
            raise ValueError("Expected one manifest root")
        self.root = roots[0]["attrs"]

    def _string(self, index):
        if not 0 <= index < len(self.strings):
            raise ValueError("Manifest string index outside pool")
        return self.strings[index]

    def _structural(self, *indexes):
        for index in indexes:
            if index != 0xffffffff:
                self._string(index)
                self.structural.add(index)

    def _reference(self, index, offset):
        self._string(index)
        self.references.setdefault(index, set()).add(offset)

    def text(self, attr):
        if attr["type"] != 3:
            raise ValueError("Expected a string-typed manifest attribute")
        return self._string(attr["value"])

    def set_text(self, attr, value):
        index = attr["value"]
        self.text(attr)
        if self.strings[index] == value:
            return
        if self.references.get(index) == {attr["offset"]} and index not in self.structural:
            self.strings[index] = value
        else:
            index = len(self.strings)
            self.strings.append(value)
            struct.pack_into("<I", self.data, attr["offset"] + 16, index)
            if attr["raw"] != 0xffffffff:
                struct.pack_into("<I", self.data, attr["offset"] + 8, index)
            attr["value"] = index

    def providers(self):
        result = []
        for node in self.nodes:
            if node["name"] == "provider":
                attrs = node["attrs"]
                if "name" not in attrs or "authorities" not in attrs:
                    raise ValueError("Provider class/authority is missing")
                result.append((self.text(attrs["name"]), self.text(attrs["authorities"]), attrs["authorities"]))
        return result

    def encode(self):
        payload, offsets = bytearray(), []
        for text in self.strings:
            encoded = text.encode("utf-16le")
            units = len(encoded) // 2
            if units >= 32768:
                raise ValueError("Manifest string too long")
            offsets.append(len(payload))
            payload.extend(struct.pack("<H", units) + encoded + b"\0\0")
        payload.extend(b"\0" * (-len(payload) % 4))
        start = self.strings_start + 4 * (len(offsets) - self.original_count)
        pool = bytearray(self.data[8:36])
        struct.pack_into("<I", pool, 4, start + len(payload))
        struct.pack_into("<I", pool, 8, len(offsets))
        struct.pack_into("<I", pool, 20, start)
        pool.extend(struct.pack("<" + "I" * len(offsets), *offsets))
        pool.extend(b"\0" * (start - len(pool)))
        pool.extend(payload)
        result = self.data[:8] + pool + self.data[8 + self.pool_size:]
        struct.pack_into("<I", result, 4, len(result))
        return bytes(result)


def validate_version(version_code, version_name):
    if not isinstance(version_code, int) or not 2 <= version_code <= 2100000000 \
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}", version_name):
        raise ValueError("Expected a supported positive preview version and a safe version name")
    if version_code in KNOWN_VERSIONS and KNOWN_VERSIONS[version_code] != version_name:
        raise ValueError("Version code/name disagree with the known preview history")


def manifest_identity(data, require_v2=True, *, version_code=VERSION_CODE, version_name=VERSION_NAME):
    # require_v2 is retained for compatibility; it now means require the supplied preview version.
    validate_version(version_code, version_name)
    manifest = BinaryManifest(data)
    if manifest.text(manifest.root["package"]) != PACKAGE_ID:
        raise ValueError("Unexpected APK package identity")
    code = manifest.root["versionCode"]
    name = manifest.text(manifest.root["versionName"])
    if code["type"] != 0x10 or (require_v2 and (code["value"] != version_code or name != version_name)):
        raise ValueError("Unexpected APK version metadata")
    authorities, providers = {}, {}
    for class_name, authority, _attr in manifest.providers():
        if class_name in providers:
            raise ValueError("Duplicate provider class")
        providers[class_name] = authority
        for item in authority.split(";"):
            if not item or item != item.strip() or item in authorities:
                raise ValueError("Duplicate or empty provider authority: " + item)
            authorities[item] = class_name
    expected = {FILE_PROVIDER: PACKAGE_ID + ".fileprovider", STARTUP_PROVIDER: PACKAGE_ID + ".androidx-startup"}
    if any(providers.get(key) != value for key, value in expected.items()):
        raise ValueError("Unexpected FileProvider/Startup authority")
    return {"package_id": PACKAGE_ID, "version_code": code["value"], "version_name": name, "provider_authorities": providers}


def repair_manifest(data, *, version_code=VERSION_CODE, version_name=VERSION_NAME):
    validate_version(version_code, version_name)
    manifest = BinaryManifest(data)
    if manifest.text(manifest.root["package"]) != PACKAGE_ID:
        raise ValueError("Refusing to repair a different package")
    code = manifest.root["versionCode"]
    if code["type"] != 0x10 or code["value"] > version_code:
        raise ValueError("Refusing unsupported version code/downgrade")
    name_attr = manifest.root["versionName"]
    allowed = dict(KNOWN_VERSIONS)
    allowed[version_code] = version_name
    if allowed.get(code["value"]) != manifest.text(name_attr):
        raise ValueError("Unexpected base version name")
    startup = [attr for name, authority, attr in manifest.providers() if name == STARTUP_PROVIDER]
    if len(startup) != 1 or manifest.text(startup[0]) not in (PACKAGE_ID + ".fileprovider", PACKAGE_ID + ".androidx-startup"):
        raise ValueError("Unexpected Startup provider authority")
    manifest.set_text(startup[0], PACKAGE_ID + ".androidx-startup")
    manifest.set_text(name_attr, version_name)
    struct.pack_into("<I", manifest.data, code["offset"] + 16, version_code)
    result = manifest.encode()
    manifest_identity(result, version_code=version_code, version_name=version_name)
    return result


def normalize_architectures(architectures):
    result = tuple(architectures)
    if not result or len(set(result)) != len(result) or any(a not in ARCHITECTURES for a in result):
        raise ValueError("Select distinct supported 64-bit architectures")
    return result


def set_ini_options(text, section, values):
    """Update only named generated options, preserving unrelated configuration verbatim."""
    lines, current, seen, found = [], "", set(), False
    for line in text.splitlines():
        header = re.fullmatch(r"\s*\[([^]]+)\]\s*", line)
        if header:
            if current == section:
                missing = [key for key in values if key not in seen]
                lines.extend(key + "=" + values[key] for key in missing)
                seen.update(missing)
            current = header[1]
            found |= current == section
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if current == section and key in values and not header:
            if key not in seen:
                lines.append(key + "=" + values[key])
                seen.add(key)
        else:
            lines.append(line)
    if not found:
        lines += ["", "[" + section + "]"]
    if current == section or not found:
        lines.extend(key + "=" + value for key, value in values.items() if key not in seen)
    return "\n".join(lines) + "\n"


def execute(command, log, env, cwd=ROOT, timeout=900, input_text=None):
    print("BUILD STEP:", log.stem, flush=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with log.open("wb") as output:
        child = subprocess.Popen([str(c) for c in command], cwd=cwd, env=env, stdout=output,
                                 stderr=subprocess.STDOUT, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                                 start_new_session=True)
        active = log.parent.parent / "active-step.json"
        active.write_text(json.dumps({"phase": log.stem, "pid": child.pid, "running": True}) + "\n")
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
            active.write_text(json.dumps({"phase": log.stem, "pid": child.pid, "running": False,
                                          "exit_code": child.returncode}) + "\n")
    if child.returncode:
        raise RuntimeError(f"{log.stem} exited {child.returncode}; see {log}")
    return {"exit_code": child.returncode, "seconds": round(time.monotonic() - started, 3), "log": log.name}


def game_inputs():
    inputs = []
    for path in sorted((ROOT / "game").rglob("*")):
        rel = path.relative_to(ROOT / "game")
        if ".godot" in rel.parts or not path.is_file() or path.is_symlink() or path.suffix == ".import":
            continue
        if path.name in ("export_presets.cfg", "export_credentials.cfg"):
            continue
        # Host library is useful for import, but platform binaries are separately classified below.
        inputs.append({"path": "game/" + rel.as_posix(), "bytes": path.stat().st_size, "sha256": sha(path)})
    native = [ROOT / "native/SConstruct", ROOT / "native/build_profile.json", ROOT / "native/extension_api.json"]
    native += sorted((ROOT / "native/src").glob("*.cpp")) + sorted((ROOT / "native/src").glob("*.h"))
    inputs += [{"path": p.relative_to(ROOT).as_posix(), "bytes": p.stat().st_size, "sha256": sha(p)} for p in native]
    return inputs


def stage(build, inputs, architectures=DEFAULT_ARCHITECTURES, *, version_code=VERSION_CODE, version_name=VERSION_NAME, enable_ai_network=False):
    staged = build / "stage"
    staged.mkdir(exist_ok=True)
    for entry in inputs:
        source, destination = ROOT / entry["path"], staged / entry["path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    # Copy only tracked binding sources, not prior generated objects, caches, or git metadata.
    binding = ROOT / "native/godot-cpp"
    tracked = subprocess.run(["git", "-C", str(binding), "ls-files", "-z"], capture_output=True, check=True).stdout
    for name in tracked.decode().split("\0"):
        if not name:
            continue
        source, destination = binding / name, staged / "native/godot-cpp" / name
        if source.is_file() and not source.is_symlink():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    write_export_preset(staged, build, architectures, version_code=version_code, version_name=version_name, enable_ai_network=enable_ai_network)
    return staged


def write_export_preset(staged, build, architectures=DEFAULT_ARCHITECTURES, *, version_code=VERSION_CODE, version_name=VERSION_NAME, enable_ai_network=False):
    validate_version(version_code, version_name)
    if enable_ai_network and version_code <= 3:
        raise ValueError("AI networking requires an incremented version code above frozen v3")
    architectures = normalize_architectures(architectures)
    preset = '''[preset.0]
name="Existing Game Android DEBUG"
platform="Android"
runnable=false
custom_features="%s"
export_filter="all_resources"
include_filter="*.json,*.bin,*.txt"
exclude_filter="export_presets.cfg,export_credentials.cfg,bin/*linux*,bin/*windows*,bin/*macos*"
export_path=""
script_export_mode=1

[preset.0.options]
custom_template/debug="%s"
gradle_build/use_gradle_build=false
architectures/armeabi-v7a=false
architectures/arm64-v8a=%s
architectures/x86=false
architectures/x86_64=%s
version/code=%d
version/name="%s"
package/unique_name="%s"
package/name="SDT Godot DEBUG Preview"
package/signed=true
package/app_category=0
permissions/internet=%s
screen/immersive_mode=true
launcher_icons/main_192x192="res://godot_export_template_icon.webp"
launcher_icons/adaptive_foreground_432x432="res://godot_export_template_icon_foreground.webp"
launcher_icons/adaptive_background_432x432="res://godot_export_template_icon_background.webp"
launcher_icons/adaptive_monochrome_432x432="res://godot_export_template_icon_monochrome.webp"
''' % ("local_ai_network" if enable_ai_network else "", (build / "templates/android_debug.apk").as_posix(), "true" if "arm64" in architectures else "false",
       "true" if "x86_64" in architectures else "false", version_code, version_name, PACKAGE_ID, "true" if enable_ai_network else "false")
    (staged / "game/export_presets.cfg").write_text(preset)
    return preset


def configure_editor(build, sdk, jdk, keystore):
    helper = build / "configure-editor"
    addon = helper / "addons/configure"
    addon.mkdir(parents=True, exist_ok=True)
    (helper / "project.godot").write_text('''config_version=5
[application]
config/name="Android Toolchain Configuration"
[editor_plugins]
enabled=PackedStringArray("res://addons/configure/plugin.cfg")
[rendering]
renderer/rendering_method="gl_compatibility"
''')
    (addon / "plugin.cfg").write_text('[plugin]\nname="Local Android build settings"\ndescription="Isolated toolchain paths"\nauthor="Build tooling"\nversion="1"\nscript="plugin.gd"\n')
    settings = {"export/android/java_sdk_path": str(jdk), "export/android/android_sdk_path": str(sdk),
                "export/android/debug_keystore": str(keystore), "export/android/debug_keystore_user": "androiddebugkey",
                "export/android/debug_keystore_pass": "android"}
    (addon / "plugin.gd").write_text('''@tool
extends EditorPlugin
func _enter_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	for key in %s:
		settings.set_setting(key, %s[key])
	call_deferred("_done")
func _done() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	print("ANDROID_TOOLCHAIN_CONFIGURED")
	get_tree().quit(0)
''' % (json.dumps(list(settings)), json.dumps(settings)))
    return helper


def configure_game_import(project, template):
    # Android export requires mobile texture import support; change only the staged copy.
    path = project / "project.godot"
    text = path.read_text()
    for key, value in {"textures/vram_compression/import_etc2_astc": "true",
                       "renderer/rendering_method": '"gl_compatibility"',
                       "renderer/rendering_method.mobile": '"gl_compatibility"'}.items():
        if re.search(r"(?m)^" + re.escape(key) + r"\s*=", text):
            text = re.sub(r"(?m)^" + re.escape(key) + r"\s*=.*$", key + "=" + value, text)
        else:
            text = text.replace("[rendering]", "[rendering]\n" + key + "=" + value, 1)
    text = text.replace('"Forward Plus"', '"GL Compatibility"')
    # Reuse bytes already present in the official template; no new game art is authored.
    with zipfile.ZipFile(template) as archive:
        for suffix in ("", "_foreground", "_background", "_monochrome"):
            icon = "res/mipmap-xxxhdpi-v4/icon" + suffix + ".webp"
            (project / ("godot_export_template_icon" + suffix + ".webp")).write_bytes(archive.read(icon))
    text = set_ini_options(text, "application", {"config/icon": '"res://godot_export_template_icon.webp"'})
    path.write_text(text)


def configure_android_library(staged, architecture="arm64"):
    normalize_architectures((architecture,))
    source = staged / f"game/bin/sdt_native.android.template_debug.{architecture}.so"
    target = source.with_name("lib" + source.name)
    shutil.copy2(source, target)
    extension = staged / "game/bin/sdt_native.gdextension"
    # This stage is DEBUG-preview-only. Keep desktop mappings intact, but do not retain an
    # Android release entry pointing at an unbuilt library. A template's DEBUG_ENABLED need
    # not agree with Android's debuggable manifest flag; match the ABI in either case.
    text = re.sub(r"(?m)^android\.release\." + re.escape(architecture) + r"\s*=.*\n?", "", extension.read_text())
    extension.write_text(set_ini_options(text, "libraries", {
        "android.debug." + architecture: json.dumps("res://bin/" + target.name),
        "android." + architecture: json.dumps("res://bin/" + target.name)}))
    return {"architecture": architecture, "abi": ARCHITECTURES[architecture]["abi"],
            "path": str(target.relative_to(staged)), "sha256": sha(target), "bytes": target.stat().st_size}


def jar_signing_entry(name):
    name = name.upper()
    return name.startswith("META-INF/") and (name.endswith((".SF", ".RSA", ".DSA", ".EC")) or name == "META-INF/MANIFEST.MF")


def prepare_apk_for_signing(source, destination, template, *, version_code=VERSION_CODE, version_name=VERSION_NAME):
    """Non-destructively repair metadata and strip stale JAR records before final APK signing."""
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError("Signing preparation requires a distinct new output; input APK is immutable")
    resource = "res/mipmap-anydpi-v26/themed_icon.xml"
    removed, preserved = [], 0
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError("Duplicate ZIP entry names")
        patched = repair_manifest(archive.read("AndroidManifest.xml"), version_code=version_code, version_name=version_name)
        restored = resource not in names
        with zipfile.ZipFile(destination, "w") as output:
            for info in archive.infolist():
                if jar_signing_entry(info.filename):
                    removed.append(info.filename)
                    continue
                data = patched if info.filename == "AndroidManifest.xml" else archive.read(info.filename)
                output.writestr(copy.copy(info), data)
                preserved += info.filename != "AndroidManifest.xml"
            if restored:
                with zipfile.ZipFile(template) as original_template:
                    output.writestr(resource, original_template.read(resource), compress_type=zipfile.ZIP_DEFLATED)
    return {"manifest": manifest_identity(patched, version_code=version_code, version_name=version_name), "removed_jar_signing_entries": removed,
            "non_manifest_non_signer_entries_preserved": preserved, "themed_resource_restored": restored,
            "source_sha256": sha(source), "prepared_sha256": sha(destination)}


def finalize_apk(source, destination, build, sdk, env, *, version_code=VERSION_CODE, version_name=VERSION_NAME):
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError("Final signing requires a distinct new output; frozen APKs are never replaced")
    unsigned = destination.with_name(destination.stem + "-unsigned.apk")
    aligned = destination.with_name(destination.stem + "-aligned.apk")
    if unsigned.exists() or aligned.exists():
        raise ValueError("Remove only the previous owned temporary signing outputs before retrying")
    result = prepare_apk_for_signing(source, unsigned, build / "templates/android_debug.apk",
                                     version_code=version_code, version_name=version_name)
    tools = sdk / "build-tools" / BUILD_TOOLS
    execute([tools / "zipalign", "-f", "-P", "16", "4", unsigned, aligned], build / f"logs/v{version_code}-align.log", env)
    execute([tools / "apksigner", "sign", "--ks", build / "keys/debug.keystore", "--ks-pass", "pass:android",
             "--ks-key-alias", "androiddebugkey", "--v1-signing-enabled", "false", "--v2-signing-enabled", "true",
             "--v3-signing-enabled", "true", "--v4-signing-enabled", "false", "--out", destination, aligned],
             build / f"logs/v{version_code}-sign.log", env)
    unsigned.unlink()
    aligned.unlink()
    return result


def verify_native_archive(archive, staged, architectures=DEFAULT_ARCHITECTURES, *, require_runtime_fallback=False):
    architectures = normalize_architectures(architectures)
    names = archive.namelist()
    abis = sorted({n.split("/")[1] for n in names if n.startswith("lib/") and len(n.split("/")) >= 3})
    if abis != sorted(ARCHITECTURES[a]["abi"] for a in architectures):
        raise RuntimeError("APK ABIs do not exactly match the requested 64-bit architectures")
    mapping_name = "assets/bin/sdt_native.gdextension"
    if mapping_name not in names:
        raise RuntimeError("APK is missing the native extension mapping")
    mappings = archive.read(mapping_name).decode("utf-8")
    native = []
    for arch in architectures:
        library = f"libsdt_native.android.template_debug.{arch}.so"
        entry = "lib/" + ARCHITECTURES[arch]["abi"] + "/" + library
        if entry not in names:
            raise RuntimeError("APK is missing the native game library for " + arch)
        data = archive.read(entry)
        if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != ARCHITECTURES[arch]["elf_machine"]:
            raise RuntimeError("Game native library has an incorrect 64-bit ELF architecture: " + arch)
        compiled = staged / f"game/bin/sdt_native.android.template_debug.{arch}.so"
        if not compiled.exists():
            compiled = staged / "game/bin" / library
        if not compiled.is_file() or hashlib.sha256(data).hexdigest() != sha(compiled):
            raise RuntimeError("Packaged native library differs from the compiled staged library: " + arch)
        if not re.search(r'(?m)^android\.debug\.' + re.escape(arch) + r'\s*=\s*"res://bin/' + re.escape(library) + r'"\s*$', mappings):
            raise RuntimeError("APK is missing the correct extension reference for " + arch)
        if require_runtime_fallback:
            if not re.search(r'(?m)^android\.' + re.escape(arch) + r'\s*=\s*"res://bin/' + re.escape(library) + r'"\s*$', mappings) \
                    or re.search(r'(?m)^android\.release\.' + re.escape(arch) + r'\s*=', mappings):
                raise RuntimeError("DEBUG preview requires an ABI fallback without a dangling release mapping: " + arch)
        native.append(entry)
    return {"abis": abis, "native_game_libraries": native}


def verify_apk(apk, build, sdk, jdk, env, architectures=DEFAULT_ARCHITECTURES, *, version_code=VERSION_CODE, version_name=VERSION_NAME, enable_ai_network=None):
    architectures = normalize_architectures(architectures)
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names) or any(jar_signing_entry(name) for name in names):
            raise RuntimeError("APK contains duplicate names or stale JAR signing metadata")
        manifest_bytes = archive.read("AndroidManifest.xml")
        identity = manifest_identity(manifest_bytes, version_code=version_code, version_name=version_name)
        binary_manifest = BinaryManifest(manifest_bytes)
        internet = any(node["name"] == "uses-permission" and "name" in node["attrs"]
                       and binary_manifest.text(node["attrs"]["name"]) == "android.permission.INTERNET"
                       for node in binary_manifest.nodes)
        if enable_ai_network is not None and internet != enable_ai_network:
            raise RuntimeError("INTERNET permission differs from the explicit AI networking build option")
    tools = sdk / "build-tools" / BUILD_TOOLS
    logs = build / "logs"
    execute([tools / "aapt2", "dump", "xmltree", apk, "--file", "AndroidManifest.xml"], logs / "apk-manifest.log", env)
    execute([tools / "aapt2", "dump", "badging", apk], logs / "apk-badging.log", env)
    execute([tools / "apksigner", "verify", "--verbose", "--print-certs", apk], logs / "apk-signature.log", env)
    execute([tools / "zipalign", "-c", "-P", "16", "-v", "4", apk], logs / "apk-alignment.log", env)
    badging = (logs / "apk-badging.log").read_text()
    manifest = (logs / "apk-manifest.log").read_text()
    signature = (logs / "apk-signature.log").read_text()
    if "warn:" in badging.lower() or "warn:" in manifest.lower() or "error:" in manifest.lower():
        raise RuntimeError("APK manifest/resource inspection reported a warning or error")
    if f"package: name='{PACKAGE_ID}'" not in badging or "application-debuggable" not in badging:
        raise RuntimeError("APK package ID/debuggable marker did not match the requested preview")
    declared = re.search(r"(?m)^native-code:\s*(.+)$", badging)
    if declared is None or sorted(re.findall(r"'([^']+)'", declared[1])) != sorted(ARCHITECTURES[a]["abi"] for a in architectures):
        raise RuntimeError("APK badging does not match the requested 64-bit ABIs")
    if f"versionCode='{version_code}'" not in badging or f"versionName='{version_name}'" not in badging:
        raise RuntimeError("APK badging version does not match the requested preview metadata")
    if "CN=Android Debug" not in signature:
        raise RuntimeError("APK was not signed by the isolated Android debug identity")
    if "Verified using v2 scheme (APK Signature Scheme v2): true" not in signature \
            or "Verified using v3 scheme (APK Signature Scheme v3): true" not in signature:
        raise RuntimeError("Both APK v2 and v3 signatures must verify")
    if "vulkan" in manifest.lower() or not re.search(r":required\(0x0101028e\)=true", manifest):
        raise RuntimeError("Compatibility preview must have a typed GLES required flag and no injected Vulkan features")
    certificate = build / "keys/debug-certificate.der"
    execute([jdk / "bin/keytool", "-exportcert", "-keystore", build / "keys/debug.keystore", "-storepass", "android",
             "-alias", "androiddebugkey", "-file", certificate], logs / "debug-certificate.log", env)
    certificate_sha = sha(certificate)
    if certificate_sha not in signature.lower().replace(":", ""):
        raise RuntimeError("APK certificate fingerprint differs from the generated debug key")
    with zipfile.ZipFile(apk) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise RuntimeError(f"APK archive CRC failed: {corrupt}")
        natives = verify_native_archive(archive, build / "stage", architectures, require_runtime_fallback=version_code >= 3)
        game_assets = [n for n in names if n.endswith("assets/sdt/library.json")]
        packs = [n for n in names if n.endswith(".pck")]
        if not game_assets and not packs:
            raise RuntimeError("No existing-game asset library or game pack found inside APK")
    return {**identity, **natives, "debuggable": True, "internet_permission_declared": internet, "debug_certificate_sha256": certificate_sha,
            "debug_signature_verified": True, "archive_crc_ok": True, "alignment_verified": True,
            "signature_v2_verified": True, "signature_v3_verified": True, "manifest_resources_clean": True,
            "typed_gles_feature_verified": True, "packaged_native_matches_build": True,
            "stale_jar_signing_metadata_absent": True, "unique_provider_authorities_verified": True,
            "game_asset_library_entries": game_assets, "game_packs": packs,
            "bytes": apk.stat().st_size, "sha256": sha(apk), "device_tested": False, "installation_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-manager", type=Path, required=True)
    parser.add_argument("--jdk", type=Path, required=True)
    parser.add_argument("--scons", type=Path, required=True)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--version-code", type=int, default=VERSION_CODE)
    parser.add_argument("--version-name", default=VERSION_NAME)
    parser.add_argument("--enable-ai-network", action="store_true", help="opt in to INTERNET permission and the local_ai_network feature for a new version above v3")
    parser.add_argument("--output", type=Path, default=ROOT / "build/android-game-preview")
    parser.add_argument("--reuse-stage", action="store_true", help="reuse verified staged inputs, compiled objects and the completed import cache")
    parser.add_argument("--finish-export", action="store_true", help="repair/reverify the existing source-matched exported APK without importing/exporting again")
    parser.add_argument("--architectures", nargs="+", choices=tuple(ARCHITECTURES), default=list(DEFAULT_ARCHITECTURES),
                        help="requested native architectures (default: arm64 and x86_64)")
    args = parser.parse_args()
    validate_version(args.version_code, args.version_name)
    version = {"version_code": args.version_code, "version_name": args.version_name}
    if args.enable_ai_network and args.version_code <= 3:
        parser.error("AI networking requires --version-code above 3 and a matching new version name")
    architectures = normalize_architectures(args.architectures)
    label = "dual64" if set(architectures) == set(DEFAULT_ARCHITECTURES) else architectures[0]
    build = args.output.resolve()
    if args.enable_ai_network and build.is_relative_to(ROOT / "build/android-game-preview"):
        parser.error("Choose a separate --output outside the frozen Android review directory")
    if not build.is_relative_to(ROOT / "build") or build == ROOT / "build":
        parser.error("use a dedicated directory under this repository's ignored build/")
    marker = build / ".existing-game-android-preview"
    if build.exists() and any(build.iterdir()) and not marker.exists():
        parser.error("nonempty output directory is not owned by this build tool")
    build.mkdir(parents=True, exist_ok=True)
    marker.write_text("1\n")
    stem = f"sdt-godot-android-debug-preview-v{args.version_code}-{label}"
    apk = build / (stem + ".apk")
    raw_apk = build / (stem + "-export-raw.apk")
    report_path = build / f"report-v{args.version_code}-{label}.json"
    manifest_path = build / f"source-manifest-v{args.version_code}.json"
    if apk.exists():
        raise FileExistsError("Refusing to replace a versioned APK: " + str(apk))
    logs = build / "logs"
    logs.mkdir(exist_ok=True)
    sdk = build / "sdk"
    sdk.mkdir(exist_ok=True)
    env = dict(os.environ, JAVA_HOME=str(args.jdk.resolve()), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    for key, name in {"XDG_DATA_HOME": "profile/data", "XDG_CONFIG_HOME": "profile/config",
                      "XDG_CACHE_HOME": "profile/cache", "ANDROID_USER_HOME": "profile/android", "TMPDIR": "profile/tmp"}.items():
        path = build / name
        path.mkdir(parents=True, exist_ok=True)
        env[key] = str(path)
    env["PATH"] = str(args.jdk / "bin") + os.pathsep + env.get("PATH", "")
    report = {"scope": "existing_game_android_debug_preview", "package_id": PACKAGE_ID, "ok": False,
              "device_tested": False, "installation_verified": False, "validation_scope": "static packaging, not installer/runtime",
               **version, "architectures": list(architectures), "ai_network_enabled": args.enable_ai_network,
              "steps": {}, "sdk_packages": PACKAGES,
              "build_tools_version": BUILD_TOOLS, "target_sdk": 36, "preview_renderer": "gl_compatibility",
              "child_home_unchanged": env.get("HOME") == os.environ.get("HOME"),
              "staged_configuration_changes": ["Android debug export preset", "ETC2/ASTC import enabled",
                                                "existing template launcher icons reused", "Android native filename/reference prefixed with lib",
                                                "Compatibility renderer for staged Android preview only",
                                                 "unique Startup authority, preview version metadata and stale JAR signature removal"],
              "base_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
    inputs = game_inputs()
    if args.reuse_stage:
        previous_path = manifest_path if manifest_path.exists() else build / "source-manifest.json"
        previous = json.loads(previous_path.read_text())
        if previous != inputs or not (build / "stage/game/.godot").is_dir():
            raise RuntimeError("Cannot reuse stage: source identity changed or completed import cache is missing")
    manifest_path.write_text(json.dumps(inputs, indent=2) + "\n")
    report["source_identity"] = {"file_count": len(inputs), "bytes": sum(p["bytes"] for p in inputs),
                                 "manifest_path": manifest_path.name, "manifest_sha256": sha(manifest_path),
                                 "game_project_sha256": sha(ROOT / "game/project.godot"),
                                 "godot_cpp_revision": subprocess.check_output(["git", "-C", str(ROOT / "native/godot-cpp"), "rev-parse", "HEAD"], text=True).strip(),
                                 "worktree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))}
    try:
        if args.finish_export:
            previous_report = json.loads(report_path.read_text())
            if previous_report.get("source_identity", {}).get("manifest_sha256") != report["source_identity"]["manifest_sha256"] \
                    or previous_report.get("raw_export", {}).get("sha256") != sha(raw_apk) \
                    or previous_report.get("architectures") != list(architectures):
                raise RuntimeError("Refusing to finalize an artifact that differs from the prior source/build report")
            if bool(previous_report.get("ai_network_enabled", False)) != args.enable_ai_network:
                raise RuntimeError("Networking option differs from the recorded raw export")
            report = previous_report
            report["ok"] = False
            report["finalization"] = finalize_apk(raw_apk, apk, build, sdk, env, **version)
            report["apk"] = verify_apk(apk, build, sdk, args.jdk.resolve(), env, architectures, **version, enable_ai_network=args.enable_ai_network)
            report["ok"] = True
            return
        report["steps"]["java"] = execute([args.jdk / "bin/java", "-version"], logs / "java-version.log", env)
        report["steps"]["engine"] = execute([args.godot, "--version"], logs / "engine-version.log", env)
        report["steps"]["licenses"] = execute([args.sdk_manager, "--sdk_root=" + str(sdk), "--licenses"], logs / "sdk-licenses.log", env,
                                              input_text="y\n" * 100)
        report["steps"]["sdk"] = execute([args.sdk_manager, "--sdk_root=" + str(sdk), "--install", *PACKAGES], logs / "sdk-install.log", env,
                                         input_text="y\n" * 100)
        template = Path.home() / ".local/share/godot/export_templates/4.7.2.stable/android_debug.apk"
        (build / "templates").mkdir(exist_ok=True)
        shutil.copy2(template, build / "templates/android_debug.apk")
        report["template_sha256"] = sha(template)
        staged = build / "stage" if args.reuse_stage else stage(build, inputs, architectures, **version, enable_ai_network=args.enable_ai_network)
        if args.reuse_stage:
            write_export_preset(staged, build, architectures, **version, enable_ai_network=args.enable_ai_network)
        configure_game_import(staged / "game", template)
        report["native_android"] = []
        for architecture in architectures:
            report["steps"]["native-" + architecture] = execute(
                [args.scons, "platform=android", "arch=" + architecture, "target=template_debug",
                 "ANDROID_HOME=" + str(sdk), "ndk_version=" + NDK, "-j4"],
                logs / ("native-android-" + architecture + ".log"), env, cwd=staged / "native")
            report["native_android"].append(configure_android_library(staged, architecture))
        keys = build / "keys"
        keys.mkdir(exist_ok=True)
        keystore = keys / "debug.keystore"
        if not keystore.exists():
            report["steps"]["key"] = execute([args.jdk / "bin/keytool", "-genkeypair", "-keystore", keystore,
                                               "-storepass", "android", "-keypass", "android", "-alias", "androiddebugkey",
                                               "-dname", "CN=Android Debug,O=Android,C=US", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000"],
                                              logs / "debug-key.log", env)
        helper = configure_editor(build, sdk, args.jdk.resolve(), keystore)
        report["steps"]["settings"] = execute([args.godot, "--headless", "--editor", "--path", helper], logs / "configure-editor.log", env, timeout=60)
        if args.reuse_stage:
            report["steps"]["import"] = {"reused": True, "log": "game-import.log"}
        else:
            report["steps"]["import"] = execute([args.godot, "--headless", "--editor", "--path", staged / "game", "--import"],
                                                 logs / "game-import.log", env, timeout=900)
        if raw_apk.exists():
            raise FileExistsError("Refusing to replace an existing raw export: " + str(raw_apk))
        report["steps"]["export"] = execute([args.godot, "--headless", "--path", staged / "game", "--export-debug",
                                               "Existing Game Android DEBUG", raw_apk], logs / f"game-export-v{args.version_code}.log", env, timeout=900)
        if not raw_apk.exists():
            raise RuntimeError("Godot reported success but produced no APK")
        report["raw_export"] = {"path": raw_apk.name, "sha256": sha(raw_apk), "bytes": raw_apk.stat().st_size}
        report["finalization"] = finalize_apk(raw_apk, apk, build, sdk, env, **version)
        report["apk"] = verify_apk(apk, build, sdk, args.jdk.resolve(), env, architectures, **version, enable_ai_network=args.enable_ai_network)
        report["staged_game_project_sha256"] = sha(staged / "game/project.godot")
        report["staged_main_scene"] = "res://scenes/main.tscn"
        report["ok"] = True
    except BaseException as exc:
        report["blocker"] = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        report["original_inputs_unchanged"] = all((ROOT / entry["path"]).is_file() and sha(ROOT / entry["path"]) == entry["sha256"] for entry in inputs)
        if not report["original_inputs_unchanged"]:
            report["ok"] = False
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({k: v for k, v in report.items() if k != "steps"}, indent=2), flush=True)


if __name__ == "__main__":
    # Ensure command-level termination unwinds and reaps the owned SDK/engine subprocess group.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    main()
