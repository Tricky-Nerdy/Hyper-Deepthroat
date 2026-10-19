# SDT-Godot

A port of the Flash game *SDT* to the Godot engine (4.7). It aims to stay faithful to the original while being
easier to extend (mods, new features) and running much faster than the Flash version.

**Adult content (18+).** The game is sexually explicit.

The game's art, sounds and fonts are included, already converted from the original `SDT.swf` into
`game/assets/sdt/`, so the original game is not needed to play. Art and sounds from community mods whose features
the port reimplements are included in `game/assets/mods/` (for example DialogueActions' voice clips). They belong
to their authors (the original game's author, and the mods' authors) and are not covered by this repository's
license. If you are a rights holder and want something removed, please open an issue.

## Loader maintenance fork

This branch extends the existing Godot loader with validated plugin manifests, dependency diagnostics,
dependency-aware enable/disable, managed replacement restoration and runtime capability reports.
See [the compatibility contract](docs/loader-compatibility.md) for implemented behavior and unverified legacy
targets. Broad TemplateExtension/ExtraMod parity and pixel-perfect rendering are not established.

A [portable neutral workbench](docs/portable-workbench.md) exercises the shared loader core, exact-name asset
commands and branching dialogue without exporting third-party game assets. Run
`python3 tools/portable_release.py verify` from the repository root. Cross-platform export attempts produce
machine-readable results and logs, including failed targets.
See [release results](docs/release-results.md) for measured checks and deployment blockers.
Existing-game Android review builds have separate [APK/runtime evidence](docs/android-preview.md).
See the [platform and authoring completion plan](docs/platform-completion-plan.md) for remaining release gates;
neither a packaged preview nor the neutral workbench establishes that the whole game is complete.
An opt-in [local AI provider foundation](docs/local-ai-providers.md) supports LM Studio, ComfyUI and optional
AUTOMATIC1111 protocol adapters with mock tests; game UI wiring, real-server and phone verification remain pending.

## Layout

- `game/`: the Godot project.
  - `game/flash/`: a small Flash runtime (display list, timelines, filters, text, SharedObject; an ActionScript
    interpreter for mod scripts).
  - `game/src/`: the game, ported class by class from the original ActionScript (same class and method names).
  - `game/scenes/main.gd`: entry point, plus the scripted test harness options.
- `native/`: source of the C++ GDExtension for hot paths (see [native/README.md](native/README.md)).
- `game/assets/sdt/`: the converted game assets (shapes, sounds, fonts, timelines in `library.json`).
- `game/assets/mods/`: art and sounds from community mods whose features the port reimplements.
- `game/bin/`: the native extension, prebuilt for Windows (debug and release DLLs).
- `tools/swfconv/`: converts `SDT.swf` into the asset library (only needed to regenerate `game/assets/sdt/`).
- `tools/porting/`: one-off scripts used while porting the ActionScript (kept for reference).
- `Mods/`: created on first run in the repository root (next to `run_debug.bat`; next to the executable in an
  exported build), with `Clothing`, `Hair`, `Backgrounds`, `Characters`, `Dialogue` and `Plugins` folders.
  Vanilla SDT `.swf` mods placed there show up in the in-game pickers.

## Running

1. Install [Godot 4.7.2](https://godotengine.org/download/archive/4.7.2-stable/) (the standard version, not .NET).
2. Tell `run_debug.bat` where Godot is, in one of these ways:
   - create `run_debug.local.bat` next to it containing
     `set GODOT=C:\path\to\Godot_v4.7.2-stable_win64_console.exe` (the console version shows the log), or
   - set the `GODOT` environment variable to that path, or
   - copy or rename the Godot executable to `godot.exe` in a folder on PATH.
3. Run `run_debug.bat`. The first run imports the assets once (a few minutes), then the game starts.

You can also open `game/` in the Godot editor and press F5.

The prebuilt setup is for **Windows** (the launcher and the included native extension). On Linux or macOS, run
`godot --headless --path game --import` once, then `godot --path game`. There is no prebuilt native extension for
those systems in the repository: build the native library using [native/README.md](native/README.md).
Some simulation paths fall back to GDScript, but runtime SWF conversion specifically requires `SWFFile`.

## Regenerating the assets (optional)

Only needed to rebuild `game/assets/sdt/` from an original `SDT.swf`. Requirements: Python 3 with `pillow` and
`numpy`, Java and [JPEXS FFDec](https://github.com/jindrapetrik/jpexs-decompiler).

```
python tools/swfconv/convert.py original/SDT.swf game/assets/sdt --scale 2 [--ffdec path/to/ffdec.jar]
python tools/swfconv/fix_hitmasks.py original/SDT.swf game/assets/sdt
python tools/swfconv/supersample.py original/SDT.swf game/assets/sdt
```

The native extension can be rebuilt from source too, see `native/README.md`. Without it the game falls back to
slower GDScript code.

## Testing

`game/scenes/main.gd` documents the command-line options for scripted runs (`--eval`, `--driver`, `--shot`,
`--frames`, `--deterministic`, ...). Always pass `--save-dir=<folder>` to test runs so they don't overwrite your
own save. Example:

```
godot --headless --path game -- --save-dir=/tmp/sdt-test --driver=res://debug/stress_costumes.gd
```

`tools/regress.sh` runs the regression tests (Git Bash or any POSIX shell, with `GODOT` set). It plays fixed
scenarios headless (menu, idle, grab and stroking, costume changes, every character, cumming) with sound and timers
following game time, so runs repeat exactly. It compares dumps of the display list and character state with the
references in `tests/golden/`. It runs without mods and with a throwaway save. Options:
- `--update` accepts the current output as the new reference; check `git diff tests/golden` first;
- `--stress` adds the costume stress test and reports memory per round;
- `--mods=<folder>` load-tests every `.swf` mod in a folder.

An intended change to the game's behaviour shows up as a difference: review it, then run `--update`.

`tools/check_all.sh` parse-checks every script. It reports "Identifier not found: Flash / g" for autoloads, which
can be ignored.

## Contributing

Code contributions are licensed under the MIT license (see `LICENSE`).
