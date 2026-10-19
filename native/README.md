# SDT native extension

C++ (GDExtension) implementations of the hottest paths of the Flash runtime / game simulation, loaded by the game
from `game/bin/sdt_native.gdextension`. The GDScript code checks `ClassDB.class_exists("SDTNative")` and falls back
to its own (identical, slower) implementation when the library is missing; `--nonative` on the game's command line
forces the GDScript paths (for A/B tests), `--checknative` cross-checks native hit tests against GDScript.

Currently native:
- `SDTNative.build_strand` - Strand.renderStrand / generateInterpolationPoints as one vertex-coloured mesh (gradient
  stops reproduced exactly by splitting triangles at the stop lines).
- `SDTNative.hit_shape` - shape-flag hit testing (FlashSprite / FlashShape `_hit_shape`) over the display tree;
  `hit_flat` tests against a tree flattened once per tick (many tests of the same body part).
- `SDTFluids` (fluids.cpp) - the spit / cum strands simulated as plain data and drawn as one mesh per strand layer
  (used by StrandControl, with NativeStrand handles for the game).
- `SDTSweat` (sweat.cpp) - the sweat droplets, drawn by one SweatBatch node per body part (used by Sweat.gd).

Objects are built per target in `build/template_debug` and `build/template_release`.
- `SWFFile` - runtime SWF reading and rasterization for mod conversion. This is a required capability for
  runtime conversion, not an optional acceleration of a complete GDScript converter.

## Linux and other target builds

Initialize `native/godot-cpp` with `git submodule update --init native/godot-cpp` from the repository root.
Install SCons in an isolated Python environment. From `native/`:

```sh
scons platform=linux arch=x86_64 target=template_debug -j4
scons platform=linux arch=x86_64 target=template_release -j4
```

The `.gdextension` maps Linux x86-64/arm64, macOS universal and Android arm64 filenames in addition to the
existing Windows entries. Each platform still needs its matching compiler/SDK and built library; a mapping
is not a shipped binary or evidence of platform support. iOS/Web native integration is not configured.

`build_profile.json` trims godot-cpp to the classes used by this extension and required binding infrastructure.
Both debug and release Linux builds are verified separately. Shared-library prefixes are normalized so Unix
output matches the configured `sdt_native.<platform>.<target>.<arch>` filenames.

## Building (Windows)

Requirements: MinGW-w64 g++ (e.g. the one in Strawberry Perl, `C:\Strawberry\c\bin`, on PATH) and SCons
(`tools/.venv`: `pip install scons`). godot-cpp is a git submodule (`git submodule update --init`).

```
cd native
../tools/.venv/Scripts/scons platform=windows use_mingw=yes target=template_debug -j8     # running from the editor binary
../tools/.venv/Scripts/scons platform=windows use_mingw=yes target=template_release -j8   # exported builds
```

The first build compiles godot-cpp (several minutes). `extension_api.json` is dumped from the engine binary the game
uses (`godot --headless --dump-extension-api`); regenerate it when updating Godot. After the first build, run the
editor or `godot --headless --path game --import` once so Godot registers the extension (.godot/extension_list.cfg).
