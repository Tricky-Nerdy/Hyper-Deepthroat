#!/usr/bin/env python3
"""Prepare six-target game export configuration, never export/install/deploy anything.

Default is a plan only; --stage copies current game source/assets into a new owned build directory.
Network capability requires --enable-ai-network. Android review artifacts are a protected location.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
PROTECTED = ROOT / "build/android-game-preview"
TARGETS = {
    "linux": ("Linux", "linux/sdt-godot.x86_64", {"binary_format/architecture": "x86_64"}),
    "windows": ("Windows Desktop", "windows/sdt-godot.exe", {"binary_format/architecture": "x86_64"}),
    "macos": ("macOS", "macos/sdt-godot.zip", {"application/bundle_identifier": "org.sdtgodot.preview", "codesign/codesign": 0}),
    "android": ("Android", "android/sdt-godot.apk", {"package/unique_name": "org.sdtgodot.preview", "version/code": 4,
                "version/name": "0.1.3-local-ai-review", "architectures/armeabi-v7a": False,
                "architectures/arm64-v8a": True, "architectures/x86": False, "architectures/x86_64": True}),
    "ios": ("iOS", "ios/sdt-godot.zip", {"application/bundle_identifier": "org.sdtgodot.preview"}),
    "web": ("Web", "web/index.html", {"variant/thread_support": False, "variant/extensions_support": False}),
}


def export_presets(network_enabled=False):
    lines = []
    for index, (target, (platform, relative, options)) in enumerate(TARGETS.items()):
        opts = dict(options)
        if target == "android":
            opts["permissions/internet"] = network_enabled
        if target == "ios" and network_enabled:
            # Purpose string only; do not disable ATS or add global cleartext exceptions.
            opts["application/additional_plist_content"] = '<key>NSLocalNetworkUsageDescription</key><string>Connect to the AI worker you explicitly approve for text and image review.</string>'
        lines += [f"[preset.{index}]", f'name="{target}"', f"platform={json.dumps(platform)}", "runnable=false",
                  'custom_features="local_ai_network"' if network_enabled else 'custom_features=""',
                  'export_filter="all_resources"', 'include_filter="*.json,*.bin,*.txt"',
                  'exclude_filter="export_presets.cfg,export_credentials.cfg,local_ai/*,*.keystore,*.p12,*.pem,*.key"',
                  f"export_path={json.dumps('../' + relative)}", "script_export_mode=1", "", f"[preset.{index}.options]"]
        lines += [key + "=" + json.dumps(value) for key, value in opts.items()]
        lines.append("")
    return "\n".join(lines)


def plan(network_enabled=False):
    blockers = {
        "linux": ["remaining shutdown resources; exported/rendered game acceptance pending"],
        "windows": ["real Windows game/native/input/save acceptance pending"],
        "macos": ["native universal library, Apple toolchain/signing/notarization and Mac acceptance pending"],
        "android": ["Android build/install freeze; SDK/native packaging and owner-controlled signing required", "physical arm64 phone and cleartext/TLS/LAN acceptance pending"],
        "ios": ["macOS/Xcode/team signing required; native integration not configured", "ATS/local-network consent and physical-device acceptance pending"],
        "web": ["game native/SWF capabilities not configured; CORS/HTTPS/private-network browser testing pending"],
    }
    return {"schema": 1, "scope": "existing_game_configuration_not_a_release", "network_capability_requested": network_enabled,
            "exports_performed": False, "all_platform_runtime_verified": False,
            "targets": {name: {"configured": True, "status": "configured_not_verified", "runtime_verified": False,
                                "blockers": blockers[name]} for name in TARGETS}}


def prepare(output: Path, *, copy_game=False, network_enabled=False):
    output = output.resolve()
    if not output.is_relative_to(ROOT / "build") or output == ROOT / "build" \
            or output.is_relative_to(PROTECTED) or PROTECTED.is_relative_to(output):
        raise ValueError("Use a new dedicated build directory outside the protected Android review tree")
    output.mkdir(parents=True, exist_ok=False)
    text = export_presets(network_enabled)
    report = plan(network_enabled)
    if copy_game:
        staged = output / "game"
        shutil.copytree(ROOT / "game", staged, ignore=shutil.ignore_patterns(
            ".godot", "export_presets.cfg", "export_credentials.cfg", "*.keystore", "*.p12", "*.pem", "*.key"))
        (staged / "export_presets.cfg").write_text(text)
        report["game_staged"] = True
        report["staged_main_scene"] = "res://scenes/main.tscn"
    else:
        (output / "export-presets.plan.cfg").write_text(text)
        report["game_staged"] = False
    report["provider_sources"] = {}
    for path in sorted((ROOT / "game/src/integrations/ai").glob("*.gd")):
        with path.open("rb") as stream:
            report["provider_sources"][path.relative_to(ROOT).as_posix()] = hashlib.file_digest(stream, "sha256").hexdigest()
    (output / "plan.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/platform-plan")
    parser.add_argument("--stage", action="store_true", help="copy the actual game into the new build directory; never export")
    parser.add_argument("--enable-ai-network", action="store_true", help="opt in to future networking export capability; does not grant runtime LAN consent")
    args = parser.parse_args()
    print(json.dumps(prepare(args.output, copy_game=args.stage, network_enabled=args.enable_ai_network), indent=2))


if __name__ == "__main__":
    main()
