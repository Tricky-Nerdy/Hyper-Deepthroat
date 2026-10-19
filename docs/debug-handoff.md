# Debug and Android handoff

## Current priority: existing-game Android review, October 19

The following older neutral-workbench milestones are historical, not a request to replace the game.
Project identity: Super Deep Throat One Shot Chain / Hyper Deep Throat, **not Aurora Bay or Neon Pursuit**.

- New delivery: `build/android-game-preview/sdt-godot-android-debug-preview-v3.apk`, **221,489,408 bytes**,
  SHA-256 `ce65907f0e0cf0216a094d0ecc2f08ad22ba2081f2dee248aafb65b22940fc0b`.
- Actual API-33/x86_64 **host-GPU** runtime smoke passed: upgrade/install, native classes, real main-scene
  readiness, advancing drawn frames, 90-second process survival, app-private mod directories and Home/resume;
  no captured app engine/script/fatal errors. A neutral upgrade marker survived, not a real save-migration test.
- Evidence: `build/android-game-preview/final-delivery-v3.json` and
  `runtime-test/v3-final-host-20261019/report.json` beneath that build directory. Emulator reaped; no external routes.
- Real game-source fix: sandboxed content paths use writable user data. Desktop/editor paths and existing
  user project edits preserved. All 17,394 packaged game asset entries are byte-identical to v2. No new art,
  dialogue, third-party imports, publishing, commits or pushes were performed.
- Both native game libraries were reused from the exact verified v2 build after source/binding/hash checks.
  Fresh dual64 export and staged ABI mappings now load the extension; v2's original native selection failure
  is not isolated to a single cause. Its OS/architecture error label did not prove three-part keys invalid.
- Remaining: physical phone/arm64 testing and original parse error; software-emulator shader failures;
  Linux shutdown resource/RID leaks; full functional/input/performance and other-OS acceptance. Do not call
  this the completed game or claim iOS/Web/Windows/macOS game releases are verified.
- Current checks: **74 Python tests passed, 1 opt-in live test skipped**, plus **44 neutral checks passed**.
  Eight pure path-policy cases ran on actual headless Godot; these are not iOS/browser runtime tests.
- Next: phone review of this exact v3 hash, then Linux cleanup and per-target release gates. Authoring,
  controls and mod/editor integration are planned in `docs/platform-completion-plan.md`, not newly implemented.

Full details, reproduction and limitations: `docs/android-preview.md`. Frozen v2 evidence below remains
historical and is not overwritten by the v3 delivery.

## Scope and edits

Local tooling milestone on Godot `4.7.2.stable.arch_linux.ed1daf0bf`, Linux/POSIX. The supplied debug files
were retained and expanded. Files changed in this pass:

- `tools/dev_debug.py`: race-tolerant watching, debounced process restart, shared preparation/launch/crash
  retry budget, cancellable preparation/backoff, owned output readers/pipes, signal cleanup, rotating bounded
  JSONL, isolated runtime profiles and separate engine metrics.
- `tests/test_dev_debug.py`: original three checks retained; now 20 tests covering reload, failure recovery,
  copy/swap rollback, termination/signals, restart bounds, reader cleanup and log retention.
- `tests/test_dev_debug_live.py`: opt-in actual-Godot temporary-fixture lifecycle check and evidence summary.
- `tools/portable_release.py`: staging-only fixture root and duplicate-log override; complete-copy/swap
  installation with rollback/recovery. Normal neutral source allowlist is retained.
- `workbench/main.gd`: opt-in readiness/stop markers, graceful stop-file handling and bounded frame/FPS/
  engine-static-memory samples.
- `docs/debugging.md`, `docs/portable-workbench.md`, `docs/debug-handoff.md`: workflow, stepping and evidence.

The existing `game/project.godot` edit was preserved; live checks verified original source hashes, including
that file. No game scene, adult mod, deployment, push, service installation or network telemetry was used.

## Commands and outcomes

Input baseline was 44 portable checks and three debugging tests. New measurements:

```sh
env LIVE_GODOT_DEBUG=1 DEV_DEBUG_EVIDENCE_DIR=/tmp/opencode/sdt-debug-live \
  python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_*.py' -v
```

**29 tests passed**: 20 supervisor tests, one actual-Godot lifecycle test, eight existing tooling tests.
ResourceWarning was treated as an error. Final suite runtime: 5.413 seconds.

```sh
env HOME=/tmp/opencode/sdt-neutral-debug-home \
  XDG_DATA_HOME=/tmp/opencode/sdt-neutral-debug-home/data \
  XDG_CONFIG_HOME=/tmp/opencode/sdt-neutral-debug-home/config \
  python3 tools/portable_release.py verify --output /tmp/opencode/sdt-neutral-debug-verify
```

**44 checks passed**, zero failed; import/checks/smoke exit codes all zero. Python compilation and
`git diff --check` also passed. These checks are distinct from live supervisor evidence.

## Actual runtime observations

Evidence: `/tmp/opencode/sdt-debug-live/events.jsonl` and `summary.json`; portable verification in
`/tmp/opencode/sdt-neutral-debug-verify/`. These temporary local artifacts are not a published release.

- Actual headless Godot: **three starts, two source-triggered process reloads**.
- One atomic-save burst produced one reload and the new script's marker was observed.
- Deleting a fixture source produced **one expected preparation failure**; the previous complete staged
  script remained intact. Restoring the fixture recovered to a third successful engine instance.
- Final SIGTERM: supervisor **0**, runtime exits **[0, 0, 0]**, approximately **0.184 s** final shutdown.
  Runtime PIDs were reaped and all reader cleanup records reported `reader_alive=false`.
- All engine-reported save directories were under the temporary debug output; no duplicate `.log` files
  bypassed bounded JSONL capture. Original files and personal saves were not used as edit fixtures.
- Seven engine windows: warmed observed callback FPS **60.002**, engine-reported FPS **50** (different
  averaging windows), engine static allocation **30,714,290–30,716,794 bytes**. Callback mean gaps across
  startup and warmed windows were **13.631–16.671 ms**. Startup observed FPS reached **73.365**; these are
  short headless observations, not rendered-performance or memory-leak benchmarks.
- A failed intermediate logging attempt exposed Godot's `/dev/null` rotation error. The tested fix disables
  file logging in staged debug configuration, including the desktop `.pc` override.

## Rendered editor follow-up: completed

Added `tools/editor_debug.py` and `tests/test_editor_debug.py`; extended `docs/debugging.md` and this handoff.
The prior local edits and the user's `game/project.godot` edit were retained. Exact new commands:

```sh
python3 -W error::ResourceWarning tools/editor_debug.py --output /tmp/opencode/sdt-editor-final
env LIVE_GODOT_DEBUG=1 DEV_DEBUG_EVIDENCE_DIR=/tmp/opencode/sdt-debug-live-editor-pass \
  python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_*.py' -v
```

- **Actual rendered Godot editor/DAP session passed**. Two verified breakpoints were hit for each request;
  Step Into entered `propose()` at line 22 and Step Over advanced to line 23. Locals, request strings,
  result dictionaries and before/after selection state were captured for valid and missing-asset cases.
- Valid selection became Blue Jacket + Station. Missing Jacket returned `missing_asset` and preserved
  that selection. Requests were injected through `_apply()` only in the fixture; manual button/toolbar
  clicks were not performed or claimed.
- Editor exit **0**, runtime exit **0**, runtime PID reaped, output reader joined, temporary user-data path
  verified, original source hashes unchanged, and **no captured engine-error output** in the final session.
- `summary.json`, `events.jsonl`, `editor.png`, `workbench.png`, `missing.png` are under
  `/tmp/opencode/sdt-editor-final/`. Images were read back and visually inspected. Editor capture: 960×1014;
  workbench captures: 948×812 (valid) and 947×812 (missing), reflecting window-manager viewport sizing.
- Three resumed rendered-session windows: observed callback FPS **59.995–60.013**, mean callback gaps
  **16.663–16.668 ms**, engine static allocation **55,123,892 bytes**. Raw windows include debugger pauses;
  this is not GPU/presentation timing or a performance certification.
- **35 tests passed** with ResourceWarning as error: prior 29 plus six DAP framing/fixture tests. The suite
  included another successful headless lifecycle run. Its evidence is in
  `/tmp/opencode/sdt-debug-live-editor-pass/`. No new core changes required repeating the earlier 44 checks.
- Early harness runs exposed missing DAP source metadata and asynchronous stale-frame diagnostics. The
  final harness supplies complete source metadata, opens fixture script state and waits for frame-variable
  delivery. An absent DAP process PID is handled using the engine readiness message.

## Real GUI save/load follow-up: completed

Added `tools/gui_debug.py`, read-only fixture `tools/fixtures/gui_observer.gd`, and eight focused tests in
`tests/test_gui_debug.py`; updated `docs/debugging.md` and this handoff. Fixed neutral workbench Undo feedback
in `workbench/main.gd`: it now reports `Selection undone.` or `Nothing to undo.` instead of retaining Apply's
old success message. Existing other edits, especially `game/project.godot`, were preserved.

```sh
python3 -W error::ResourceWarning tools/gui_debug.py --output /tmp/opencode/sdt-gui-verified
env LIVE_GODOT_DEBUG=1 DEV_DEBUG_EVIDENCE_DIR=/tmp/opencode/sdt-debug-live-gui-pass \
  python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_*.py' -v
env HOME=/tmp/opencode/sdt-gui-verify-home \
  XDG_DATA_HOME=/tmp/opencode/sdt-gui-verify-home/data \
  XDG_CONFIG_HOME=/tmp/opencode/sdt-gui-verify-home/config \
  python3 tools/portable_release.py verify --output /tmp/opencode/sdt-gui-portable-verify
```

- **Actual GUI harness passed eight cases**: Apply, Undo, empty Undo, Save, Load after restart, malformed
  rejection, incompatible rejection and valid-load recovery. Typed Gold Jacket/Garden selection survived
  the process restart. The incompatible fixture offered different valid assets but an invalid story digest;
  selection, story and undo count remained unchanged on rejection, proving no partial candidate commit.
- These were compositor keyboard events to real controls: Lua focus by owned PID/address, explicit mods,
  separate down/up, Tab navigation and Space activation. Native key events and `Button.pressed` observations
  are recorded. No mouse clicks, DAP requests, direct handler calls or Godot input injection were used as
  GUI proof. No unexpected SUPER modifiers appeared in the observed events.
- Two rendered Godot processes exited **[0, 0]**, both were reaped, readers joined, no captured engine-error
  output, and engine save paths remained in the temporary fixture. Runtime source hashes remained stable.
- Evidence: `/tmp/opencode/sdt-gui-verified/summary.json`, `events.jsonl`, session snapshots and six 808×693
  app-only captures: `applied.png`, `undone.png`, `saved.png`, `loaded.png`, `malformed.png`, `incompatible.png`.
  The captures were inspected, including corrected Undo feedback. Temporary saves/profile were removed.
- **43 tests passed** with ResourceWarning as error (prior 35 plus eight input-guard/fixture tests); suite
  runtime 5.459 seconds. The guard tests reproduce interruption/log-write failure after key-down and verify
  key-up is still sent to the original owned surface. **44 portable checks passed again**, with all three
  import/checks/smoke exits zero after the Undo feedback fix. Python compilation/diff whitespace passed.
- The supplied reference <https://sdt-progress.pages.dev/> was read as public progress context only; its
  claims refer to a separate port/toolchain and were not adopted as verification evidence for this repo.

## Existing-game Android packaging follow-up (v1 superseded)

An actual **existing-game** Android DEBUG preview is now packaged locally, separately from the neutral
workbench. See `docs/android-preview.md` for build/configuration changes and evidence. Artifact:
`build/android-game-preview/sdt-godot-android-debug-preview-arm64.apk`, **195,692,425 bytes**, SHA-256
`c552fd7ceab2048589e63736e05b8fbe2d7517dad4380850f288fc062bbd164e`.
API-36 manifest/resources, arm64 native game library, v2/v3 debug signatures, CRC and 16-KiB ZIP alignment
passed. The staged preview uses Compatibility rendering and restores an existing template icon resource;
original game content/settings and real child HOME were preserved. **Not device-tested; game completion
still unverified.** Earlier `e78771c8…` and `620fd36c…` APK hashes are rejected/superseded. c552 was later
reported to fail parsing on a phone and is now superseded too. `report.json` retains only that static audit;
the current evidence is below. No public publishing or personal-device installation occurred.

## Android v2: Root installer evidence and source-helper integration

- Final frozen delivery: `build/android-game-preview/sdt-godot-android-debug-preview-v2.apk`,
  **221,480,894 bytes**, SHA-256 **`a08966caffdc565ce82ea585592406fc85a2edb58fb5eedd370087ec7a332dcd`**.
  Version code **2**, name **0.1.1-debug-preview**, **arm64-v8a + x86_64**.
- Root owned actual builds, APK creation and installer tests. Its isolated Android13/API33 x86_64 install
  of this exact APK returned **Success**, exit **0**, with `app_process_absent=true`, `game_launched=false`,
  `physical_device_used=false` and no external routes. Evidence: `final-delivery-v2.json`,
  `luma-v2-dual64-report.json`, `installation-test/dual64-v2-report.json` under the build directory.
- Root first tested exact c552: Android reached native extraction and failed **NO_MATCHING_ABIS / -113**.
  That image has no arm64 bridge. The phone parse error was **not reproduced**; unique provider authorities
  fix a confirmed exporter defect but are **not proven to explain the phone error**.
- Source-only changes in `tools/android_preview.py` integrate the repair reference: distinct Startup
  authority, version metadata, stale JAR metadata removal before fresh v2/v3 signing, dual64 preset/build
  loops, native filename/mapping updates and per-ABI verification. New outputs/reports are versioned and
  refuse to overwrite frozen inputs. Duplicate authorities and stale signer records are rejected.
- **16 focused packaging tests passed**, ResourceWarning as error, both locally and independently by Root.
  Root's `helper-smoke-v2.json` confirms exact accepted-manifest bytes, repair idempotence, duplicate rejection
  and native verification against the real stage; test log: `logs/packaging-unit-v2-root.log`.
- This integration did not run SCons/import/export/emulators or alter installation-test tooling, the stage,
  frozen c552/4258 candidates or final APK. Original user source edits remain. See `docs/android-preview.md`
  for the exact split and helper limits (unstyled UTF-16 AXML; full new CLI not rerun in this pass).

## Boundaries and next milestone

No remaining blocker to the local headless, rendered-editor/DAP and tested Hyprland keyboard GUI milestones.
Mouse/touch/controller paths and Windows/macOS GUI/signal behavior remain unverified. Browser refresh,
service-health checks and state-preserving hot reload are not implemented. Heartbeats mean process
presence only; engine static allocation is not RSS. Legacy adapter/pixel-perfect status remains as stated
in `docs/loader-compatibility.md`. Work remained local; no commit, push, release, service install or telemetry
upload was performed in these follow-ups.

Next bounded milestone: use actual GUI Continue/choice navigation in the neutral arrival story, then
save/restart/load at the chosen dialogue position and verify the restored available choices and variables.
Keep profiles isolated and preserve the distinction between GUI input, DAP inspection and headless checks.
