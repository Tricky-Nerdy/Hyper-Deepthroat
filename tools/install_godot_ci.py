#!/usr/bin/env python3
"""Install official, checksum-verified desktop Godot tooling for manually invoked CI jobs.

Does not edit editor settings. Uses the standard export-template directory, and a chosen binary directory.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import platform
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import urllib.request
import zipfile


def download(url: str, path: Path) -> None:
    with urllib.request.urlopen(url, timeout=120) as response, path.open("wb") as output:
        shutil.copyfileobj(response, output)


def verify(path: Path, sums: str) -> None:
    entries = {}
    for line in sums.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            entries[parts[1].strip().lstrip("*").removeprefix("./")] = parts[0].lower()
    with path.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha512").hexdigest()
    if entries.get(path.name) != actual:
        raise ValueError(f"Official SHA-512 verification failed: {path.name}")


def engine_spec(version: str, system: str, machine: str) -> tuple[str, str]:
    arch = machine.lower()
    if system == "Linux" and arch in ("x86_64", "amd64", "aarch64", "arm64"):
        target = "x86_64" if arch in ("x86_64", "amd64") else "arm64"
        binary = f"Godot_v{version}-stable_linux.{target}"
        return binary + ".zip", binary
    if system == "Windows" and arch in ("x86_64", "amd64"):
        return f"Godot_v{version}-stable_win64.exe.zip", f"Godot_v{version}-stable_win64_console.exe"
    if system == "Darwin" and arch in ("x86_64", "amd64", "aarch64", "arm64"):
        return f"Godot_v{version}-stable_macos.universal.zip", "Godot.app/Contents/MacOS/Godot"
    raise ValueError(f"Unsupported CI host: {system}/{machine}")


def template_root(version: str, system: str) -> Path:
    if system == "Windows":
        data = Path(os.environ.get("APPDATA", Path.home() / "AppData/Roaming")) / "Godot"
    elif system == "Darwin":
        data = Path.home() / "Library/Application Support/Godot"
    else:
        data = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "godot"
    return data / "export_templates" / f"{version}.stable"


def extract_engine(archive: Path, destination: Path, binary: str, system: str) -> Path:
    with zipfile.ZipFile(archive) as package:
        for info in package.infolist():
            parts = PurePosixPath(info.filename).parts
            if not parts or info.filename.startswith("/") or ".." in parts or "\\" in info.filename \
                    or any(":" in part for part in parts) or stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError("Unsafe engine archive member")
        if system == "Linux":
            target = destination / "godot"
            if target.exists():
                raise FileExistsError(target)
            with package.open(binary) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(0o755)
        else:
            # Preserve the macOS app bundle and the Windows console/main executable pairing.
            if (destination / binary).exists():
                raise FileExistsError(destination / binary)
            for info in package.infolist():
                if info.is_dir():
                    continue
                target = destination.joinpath(*PurePosixPath(info.filename).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.open(info) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                if system == "Darwin":
                    target.chmod((info.external_attr >> 16) & 0o777 or 0o644)
            target = destination / binary
            if not target.is_file():
                raise ValueError("Engine archive does not contain the expected executable")
            if system == "Darwin":
                target.chmod(0o755)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="4.7.2")
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--engine-only", action="store_true", help="do not download/install export templates")
    parser.add_argument("--template-scope", choices=("portable", "all"), default="portable")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("version must have three numeric components")
    base = f"https://github.com/godotengine/godot-builds/releases/download/{args.version}-stable/"
    system = platform.system()
    engine_archive, binary = engine_spec(args.version, system, platform.machine())
    names = [engine_archive]
    if not args.engine_only:
        names.append(f"Godot_v{args.version}-stable_export_templates.tpz")
    args.bin_dir.mkdir(parents=True, exist_ok=True)
    templates = template_root(args.version, system)
    if not args.engine_only:
        templates.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="godot-install-") as temp:
        temp_path = Path(temp)
        sums_path = temp_path / "SHA512-SUMS.txt"
        download(base + sums_path.name, sums_path)
        sums = sums_path.read_text()
        for name in names:
            archive = temp_path / name
            download(base + name, archive)
            verify(archive, sums)
        executable = extract_engine(temp_path / names[0], args.bin_dir, binary, system).resolve()
        if not args.engine_only:
            with zipfile.ZipFile(temp_path / names[1]) as archive:
                for entry in archive.infolist():
                    parts = PurePosixPath(entry.filename).parts
                    if len(parts) != 2 or parts[0] != "templates" or entry.is_dir():
                        continue
                    if args.template_scope != "all" and not parts[1].startswith(("linux_", "windows_", "web_")):
                        continue
                    if parts[1] in (".", "..") or "\\" in parts[1] or ":" in parts[1] or stat.S_ISLNK(entry.external_attr >> 16):
                        raise ValueError("Unsafe template archive member")
                    with archive.open(entry) as source, (templates / parts[1]).open("wb") as output:
                        shutil.copyfileobj(source, output)
    if os.environ.get("GITHUB_PATH"):
        with Path(os.environ["GITHUB_PATH"]).open("a") as output:
            output.write(str(args.bin_dir.resolve()) + "\n")
    if os.environ.get("GITHUB_ENV"):
        with Path(os.environ["GITHUB_ENV"]).open("a") as output:
            output.write(f"GODOT={executable}\n")
    print(f"Verified Godot {args.version} for {system}; executable: {executable}; templates: {not args.engine_only}.")


if __name__ == "__main__":
    main()
