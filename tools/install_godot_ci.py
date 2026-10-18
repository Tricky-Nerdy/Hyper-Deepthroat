#!/usr/bin/env python3
"""Install official, checksum-verified Linux Godot tooling for the portable CI job.

Does not edit editor settings. Uses the standard export-template directory, and a chosen binary directory.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="4.7.2")
    parser.add_argument("--bin-dir", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("version must have three numeric components")
    base = f"https://github.com/godotengine/godot-builds/releases/download/{args.version}-stable/"
    names = [f"Godot_v{args.version}-stable_linux.x86_64.zip", f"Godot_v{args.version}-stable_export_templates.tpz"]
    args.bin_dir.mkdir(parents=True, exist_ok=True)
    data_root = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    templates = data_root / "godot/export_templates" / f"{args.version}.stable"
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
        with zipfile.ZipFile(temp_path / names[0]) as archive:
            binary = f"Godot_v{args.version}-stable_linux.x86_64"
            with archive.open(binary) as source, (args.bin_dir / "godot").open("wb") as output:
                shutil.copyfileobj(source, output)
        (args.bin_dir / "godot").chmod(0o755)
        with zipfile.ZipFile(temp_path / names[1]) as archive:
            for entry in archive.infolist():
                parts = PurePosixPath(entry.filename).parts
                if len(parts) != 2 or parts[0] != "templates" or entry.is_dir():
                    continue
                # The CI job exports only these platforms. All members are flattened after strict checks.
                if not parts[1].startswith(("linux_", "windows_", "web_")):
                    continue
                with archive.open(entry) as source, (templates / parts[1]).open("wb") as output:
                    shutil.copyfileobj(source, output)
    if os.environ.get("GITHUB_PATH"):
        with Path(os.environ["GITHUB_PATH"]).open("a") as output:
            output.write(str(args.bin_dir.resolve()) + "\n")
    print(f"Verified Godot {args.version} and Linux/Windows/Web export templates installed.")


if __name__ == "__main__":
    main()
