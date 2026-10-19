# Existing-game Android DEBUG previews

**Game completion remains unverified.** These are builds of the existing game, not the neutral workbench.
The October 19 follow-up now includes actual emulator runtime tests. The original phone parsing error is
still **unreproduced and unexplained**; no physical phone has been tested. No new art or dialogue was created.

## Current v3 phone-review APK: host-GPU emulator runtime passed

- **APK:** `build/android-game-preview/sdt-godot-android-debug-preview-v3.apk`
- **SHA-256:** `ce65907f0e0cf0216a094d0ecc2f08ad22ba2081f2dee248aafb65b22940fc0b`
- **Size:** 221,489,408 bytes. Package `org.sdtgodot.preview`, code **3**, name **0.1.2-debug-preview**.
- **Targets:** arm64-v8a + x86_64; minimum API 24, target/compile API 36. Debug-signed with the same
  isolated identity as v2. This is not a production/store-signed release.
- **Checksums:** adjacent `.apk.sha256` and `build/android-game-preview/SHA256SUMS-v3`.
- **Delivery record:** `build/android-game-preview/final-delivery-v3.json`.

Actual test of these exact bytes: isolated Android 13/API-33 x86_64 emulator, NVIDIA host-GPU GLES backend,
private adb server/AVD and no external routes. The artifact copied to the delivery path hashes identically
to the tested file under `runtime-v3-final/`.

| Runtime gate | Verified result |
|---|---|
| Install/upgrade from exact v2 | Success; a neutral app-private marker survived the upgrade |
| Cold activity start | `Status: ok`; same process survived the 90-second observation |
| Native extension | Library present in process maps; `SDTNative` and `SWFFile` registered |
| Existing main scene | `res://scenes/main.tscn` ready, with a populated Flash stage |
| Rendering progress | Ready-scene drawn-frame counter advanced **7 → 1,352** |
| Android Home/resume | Same app process resumed successfully |
| Private mod storage | All six `files/Mods/` subdirectories exist; no root-directory creation errors |
| Captured app engine/script/fatal errors | **0** on the host-GPU run |
| Cleanup/integrity | Owned emulator reaped; APK unchanged |

This proves a bounded real launch/runtime smoke test, **not** manual visual correctness, playable-control
acceptance, touch/audio quality, a performance benchmark, actual game-save migration or game completion.
The upgrade check used a neutral marker, not a user's real saves. No screenshots or gameplay inputs were used.

### Corrections, preservation and remaining failures

- The game is freshly exported with both ABIs instead of manually adding architecture data to an arm64
  export. Staged Android debug mappings include ABI fallbacks and no dangling release-library reference.
  The original source `.gdextension` and the frozen v2 APK remain untouched. The exact cause of v2's native
  selection failure has not been isolated; do not repeat the earlier incorrect claim about three-part keys.
- The only game-source changes are the pure path policy in `game/flash/content_paths.gd` and its call from
  `game/flash/flash_runtime.gd`. Android/iOS/Web resolve user content in writable app-private data; existing
  desktop/editor path behavior is retained. Real iOS/browser storage persistence and import UI are untested.
- **17,394 packaged game asset entries are byte-identical to v2.** Existing user `game/project.godot` changes
  are hash-identical to the v2 input. Other pre-existing workbench/tooling edits were retained. Native C++ and
  godot-cpp are unchanged; the exact previously compiled v2 native binaries were verified and reused.
- The debug-only staged observer logs native registration, scene readiness and engine frame counters.
  It neither generates content nor injects gameplay inputs or changes saves.
- **Software rendering still fails** shader linking (`GL_MAX_FRAGMENT_UNIFORM_VECTORS`, 261). Both the older
  `swiftshader_indirect` candidate test and final `software` test are recorded as failed, despite a live
  process, ready scene and advancing draw count. Reduced 3D-light limits did not fix it and were removed
  from the final build. Host-GPU success must not be generalized to all phone GPUs.
- No physical phone/arm64 execution occurred; the original reported phone parse error remains unresolved.
  Linux headless testing also exposed shutdown resource leaks. See [platform gates](platform-completion-plan.md).

### Reproduce the v3 workflow

These commands use the existing local v2 SDK/template/native cache and preserve frozen artifacts. Choose
new output directories/labels: helpers refuse to replace an existing build or test run. No SDK download,
license acceptance, SCons run, public upload or personal-device operation is performed by this workflow.

```sh
unshare -Urn python3 -W error::ResourceWarning tools/android_runtime_preview.py \
  --output build/android-game-preview/runtime-v3-rebuild

unshare -Urn python3 -W error::ResourceWarning tools/android_runtime_check.py \
  --apk build/android-game-preview/sdt-godot-android-debug-preview-v3.apk \
  --label v3-review-rerun --gpu host --seconds 90 \
  --upgrade-from build/android-game-preview/sdt-godot-android-debug-preview-v2.apk \
  --home-resume
```

JDK actually used: `/usr/lib/jvm/default` → OpenJDK 27. Godot/template 4.7.2, SDK build-tools 36.0.0.
The standalone original `android_preview.py` now also accepts explicit `--version-code`/`--version-name`,
retaining v2 defaults and frozen-manifest tests. APK finalization is version-aware and refuses downgrades.

Current evidence (relative to `build/android-game-preview/`):

- `runtime-v3-final/report.json`: source/native provenance and actual import/export/signature/CRC/alignment checks.
- `runtime-v3-final/preservation-report.json`: source and packaged-asset comparisons.
- `runtime-v3-final/elf-16k-report.json`: all six native libraries have 16-KiB-compatible ELF load segments,
  in addition to the SDK ZIP-alignment check. Actual 16-KiB-page-device execution is unverified.
- `runtime-test/v3-final-host-20261019/report.json`: passing real runtime/upgrade/Home-resume evidence.
- `runtime-test/v3-final-software-20261019/report.json`: recorded software shader failure, not a pass.
- `logs/runtime-v3-unit-tests.log`: **74 passed, 1 skipped** (75 total); live editor lifecycle is opt-in.
  Separate neutral verification: `build/neutral-validation-20261019/results/`, **44 passed, 0 failed**.
  Those neutral checks are not evidence of full-game or authoring-feature completion.

A local allowlisted evidence bundle is `build/android-game-preview/verification-v3.zip`, with an adjacent
SHA-256 file. It includes reports, selected logs and handoff documentation, not signing keys or emulator data.

### Physical phone review still required

Transfer **v3**, verify the transferred file's SHA-256, and use a 64-bit Android device at API 24 or newer.
Keep real saves backed up; do not uninstall an existing app just to work around an error. Review launch,
touch/menu reachability, resize/rotation, Home/resume, audio and save/restart/load. If parsing/install fails,
record the device model, Android/API version, advertised ABIs, exact installer error and transferred hash.
An authorized `adb install -r` diagnostic can expose the real PackageManager error; no such phone operation
was performed here. Mod file-import/export usability is also unverified; private folders alone are not an
implemented mobile mod manager.

## v2 baseline: installed, but runtime errors reproduced

- Path: `build/android-game-preview/sdt-godot-android-debug-preview-v2.apk`
- Size: **221,480,894 bytes**.
- SHA-256: **`a08966caffdc565ce82ea585592406fc85a2edb58fb5eedd370087ec7a332dcd`**.
- Package: `org.sdtgodot.preview`; version code **2**, version name **`0.1.1-debug-preview`**; debuggable.
- ABIs: **arm64-v8a + x86_64**, with the existing game extension compiled for each and matching extension
  references. The x86_64 code was compiled from the same staged native sources; no gameplay was changed.
- Provider authorities are distinct: FileProvider uses `org.sdtgodot.preview.fileprovider`; Startup uses
  `org.sdtgodot.preview.androidx-startup`.
- Stale `META-INF/ANDROIDD.RSA`, `ANDROIDD.SF` and `MANIFEST.MF` were removed before fresh APK v2/v3 signing.
- Root's exact-APK emulator install returned **`Success`**, exit **0**. Evidence records
  `app_process_absent=true`, `game_launched=false`, `physical_device_used=false`, and no external routes.
- Historical delivery evidence: `final-delivery-v2.json`, `luma-v2-dual64-report.json`, and
  `installation-test/dual64-v2-report.json`, all under `build/android-game-preview/`.

**October 19 runtime update:** `runtime-test/v2-baseline-20261019/report.json` reproduces a successful cold
activity start and a surviving process for 60 seconds, but the native game library is absent from process
maps. Godot reports an extension selection failure, GLES shader linking failures and six unwritable
`Mods/` directories. Later game-tick messages demonstrate running fallback game code; the earlier statement
that the game could only be an empty shell was not established and is retracted. v2 is not a clean runtime
preview and should not be used as the new review build.

The `android.x86_64` error label is **not** proof that `android.debug.x86_64` keys are invalid. The matching
Godot source selects libraries by feature tags and prints only OS/architecture in this diagnostic. A fresh
dual64 candidate export with debug and ABI fallback mappings loads both native classes successfully. Its
runtime reports `debug=true`, `template_debug=true`, `release=false`, and its engine libraries hash-identically
to v2. Re-export and mapping changes have not been isolated to a single root cause of v2's selection failure.

The exact frozen c552 baseline was tried on the same API-33 image first. It reached native extraction and
failed with **`INSTALL_FAILED_NO_MATCHING_ABIS` (`res=-113`)** because that image advertises **only x86_64**.
The arm64-only candidate was likewise unsuitable for that emulator ABI. Neither result reproduces a
manifest/phone parsing error. The duplicate-authority rewrite is an observed exporter defect, but it is
**not proven to have caused the reported phone failure**. Do not infer phone compatibility from this
installation-only x86_64 result, and do not call the game complete.

## Superseded v1 archive-only audit

- Path: `build/android-game-preview/sdt-godot-android-debug-preview-arm64.apk`
- Size: **195,692,425 bytes** (approximately 186.6 MiB).
- SHA-256: **`c552fd7ceab2048589e63736e05b8fbe2d7517dad4380850f288fc062bbd164e`**.
- Package: `org.sdtgodot.preview`; version `0.1.0-debug-preview`; debuggable.
- ABI: **arm64-v8a only**. The compiled game's `libsdt_native.android.template_debug.arm64.so` is present,
  is AArch64 ELF and exactly matches the staged native build.
- SDK: minimum 24, compile/target 36. Engine/template: Godot 4.7.2.
- Android debug certificate SHA-256:
  `e149df0da61a4b7e8b7414336318b0be165b9094b1063f7a6e2c4c5e205c00e3`.
- APK **v2 and v3 signatures**, **16-KiB ZIP alignment**, archive CRC and API-36 aapt2 inspection passed.
  Final manifest/resource inspection reports no warnings/errors. The GLES `required` flag is typed boolean;
  faulty Vulkan feature nodes are absent in this Compatibility-renderer preview.
- **Not installed on a personal device and not device-tested.** Touch usability, mobile performance, runtime
  native loading and overall gameplay are not established by archive/signature verification.

The first APK (`e78771c8…`, 190,501,317 bytes) lacked the native extension. The intermediate `620fd36c…`
build retained a dangling icon resource. The c552 build above passed static checks but was subsequently
reported to fail parsing on a phone and is superseded. **Do not deliver these old artifacts.**
`report.json` records the c552 static audit, not the current delivery status. The c552 baseline remains
frozen as `luma-audit-c552-delivered.apk`. The arm64 v2 candidate remains frozen as
`luma-candidate-v2-arm64.apk` (192,108,226 bytes, SHA-256
`4258ae928e36cf4f48f33083470ec4b006e580c8742d19ee6972bf9756754cfe`). None of these files was modified by
the helper/source integration pass.

## Packaging corrections and source identity

The build uses a separate copied `stage/game`, not `workbench/`. It retains the real main scene
`res://scenes/main.tscn` and the game asset library `assets/assets/sdt/library.json` inside the APK.

Staged platform-only changes:

1. Generated Android debug export preset, unique preview package ID and existing debug template.
2. Enabled ETC2/ASTC import support and explicitly selected **Compatibility** for both renderer settings,
   avoiding this engine exporter's malformed string-typed Vulkan manifest attributes.
3. Added the required `lib` prefix to the compiled Android extension filename and its staged `.gdextension`
   reference. Original game/native sources and mappings remain untouched.
4. Reused existing default launcher icon bytes from the official export template. Godot's export renamed
   the compiled themed icon XML but left its original resource-table reference; the build restored that
    **existing compiled XML**, then re-aligned and re-signed the APK. No icon art was generated.
5. Version-2 finalization repairs only the known Startup authority and version fields in AXML, strips
   stale JAR signing records, then ZIP-aligns and explicitly signs with v2/v3 (v1/v4 disabled). Unknown
   authorities/encodings fail closed. Shared string-pool values are not overwritten in unrelated fields.
6. Dual64 configuration enables both native architectures, compiles the same sources for both, prefixes
   each library name with `lib`, and supplies `android.debug.arm64` / `android.debug.x86_64` references.

Toolchain: existing OpenJDK 26, local SDK build-tools **36.0.0**, platform 36, NDK **28.1.13356709** and SCons.
The actual installed template reports API 36, so matching tools were used instead of the generic SDK-35
recipe. Real `HOME` is inherited unchanged. SDK, XDG settings/cache, Android user data, explicit debug key,
staged imports and logs are confined to the ignored build directory. Completed imports/objects were reused.

Base revision: `4b45ed071f80d15b046f32551a23fabeea07cfef`, with local working-tree changes. The manifest records
**17,908 input files**, 169,991,981 bytes, with manifest SHA-256
`9a7412cb911ca27109de3a4a2165435638dbe4d26d8763cb5b0d5c7303123e6f`.
The original inputs, including the pre-existing `game/project.godot` edit, hash-identically after the build.

## Reproduce and evidence

The following is the historical v2 workflow, not the October 19 runtime-preview command. Root owned all
actual native builds, APK creation and emulator checks during the v2 task split. The source
integration pass ran **unit tests only** and did not regenerate or replace any frozen/final APK or mutate
the real stage. The future helper command is:

```sh
python3 tools/android_preview.py \
  --sdk-manager "$HOME/.local/android-sdk/cmdline-tools/latest/bin/sdkmanager" \
  --jdk /usr/lib/jvm/java-26-openjdk \
  --scons /tmp/opencode/sdt-build-tools/bin/scons \
  --reuse-stage --architectures arm64 x86_64
```

Omit `--reuse-stage` for a fresh build. It requires the previous input identity and completed cache when
reusing. SDK installation may need downloads/license acceptance; all installs are local to the build tree.
`--reuse-stage` still invokes SCons; it does **not** skip native compilation. The October 19 GDScript path
fix intentionally changes the v2 input identity, so do not use this historical reuse command for the new
sources. `tools/android_runtime_preview.py` instead copies the cache, overlays current game inputs and
reuses only the hash-verified v2 native binaries when native sources/binding revision are unchanged.
The helper defaults to version 2 / `0.1.1-debug-preview` and dual64. It writes a separate
`sdt-godot-android-debug-preview-v2-dual64.apk` with `report-v2-dual64.json` and refuses to overwrite an
existing final output. This future build path was not rerun in the source-only pass and need not reproduce
Root's exact signed ZIP bytes. The frozen `a08966ca…` artifact is retained as a baseline, not a clean runtime delivery.

`--finish-export` finalizes only a source-matched **v2 raw export** recorded in the v2 report. It does not
silently patch c552 or a frozen candidate in place. `prepare_apk_for_signing()` and `finalize_apk()` require
distinct new destinations, preserve non-manifest/non-signer data, repair a missing existing template icon
resource when necessary and remove stale JAR records **before** alignment/signing. Private debug signing
material stays under `build/.../keys/` and is not a production identity or delivery asset.

`verify_apk()` rejects duplicate provider authorities, old version metadata, stale signing records,
duplicate ZIP names, missing/wrong ABI libraries, wrong ELF64 machine IDs, mismatched native build hashes,
and missing per-ABI extension references. Expected ABIs are explicit; default verification requires both.
It continues to verify APK v2/v3 signatures, 16-KiB ZIP alignment, CRC and clean SDK inspection. Its result
is explicitly **static packaging verification**, not a replacement for Android's PackageParser/installer.

Evidence under `build/android-game-preview/`:

- `final-delivery-v2.json`: authoritative final v2 artifact and installation scope.
- `luma-v2-dual64-report.json`: dual64 packaging provenance and uncompressed-entry comparisons.
- `installation-test/dual64-v2-report.json`: exact baseline failure and successful final Android install.
- `helper-smoke-v2.json`: Root independently verified manifest byte identity, idempotence, old-authority
  rejection and native archive verification against the actual stage.
- `logs/packaging-unit-v2-root.log`: Root's independent **16 focused tests passed**, ResourceWarning as error.
- `report.json`: superseded c552 static artifact/build audit, retained for history.
- `source-manifest.json`: input file hashes.
- `logs/game-export.log`, `logs/native-android.log`, `logs/game-import.log`: actual export/build/import evidence.
- `logs/apk-manifest.log`, `apk-badging.log`, `apk-signature.log`, `apk-alignment.log`: final SDK verification.
- `logs/resource-repair-align.log`, `resource-repair-sign.log`: final resource packaging repair.

The initial long wrapper timed out after import while export continued; the cached rerun completed export
and report creation. The final icon repair required no repeated game import or export. No public publishing
or device installation was performed. The older Android-blocked entry in `docs/release-results.md` concerns
the earlier neutral-workbench release attempt, not this new existing-game preview artifact.

## Historical v2 source-helper tests and tooling limits

```sh
python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_android_preview.py' -v
```

**16 tests passed locally and independently under Root.** They cover version/authority repair, exact
read-only frozen-manifest comparison, idempotence, shared strings, malformed/unsupported string pools,
stale metadata cleanup, immutable inputs/outputs, explicit signing flags, dual64 preset/mappings/ELFs,
architecture selection and verifier rejection gates. SDK calls are mocked; no build/emulator is run by
these unit tests. Root additionally confirmed the repaired manifest is byte-identical to the APK accepted
by Android 13 and both native entries verify against the actual stage.

The AXML helper deliberately supports this template's unstyled UTF-16 format, not arbitrary UTF-8/styled
manifests. The integrated full helper CLI was not exercised end-to-end during the source-only split;
Root's independently built exact APK has that split's install evidence. Runtime evidence now exists in the
October 19 follow-up above; physical phone testing and the original parsing failure remain unresolved.
