# SDT-Godot completion and platform gates

Project: **Super Deep Throat One Shot Chain / Hyper Deep Throat**, the existing SDT-Godot game.
Not Aurora Bay, Neon Pursuit or the neutral workbench. This is a delivery plan, **not a completion claim**.

## Release order

1. **Android phone-review preview:** fix actual startup failures; sign an incremented APK; check its exact
   checksum, Android installation, native class registration, real main-scene readiness and advancing frames.
   Keep x86_64 emulator results separate from arm64 phone results. See [Android evidence](android-preview.md).
2. **Existing desktop game:** Linux x86_64, Windows x86_64 and macOS arm64/x86_64. Establish matching native
   libraries, installed-app paths, clean first launch, controls, save/restart/load, mod import and shutdown on
   each OS. A neutral workbench export is not evidence that the game works there.
3. **iOS and browser:** resolve native-extension integration first, then package and run the existing game.
   Test sandbox storage and file-import restrictions. Document unavailable capabilities rather than silently
   substituting an incomplete SWF converter. Apple builds require macOS/Xcode, signing and device access.
4. **Release readiness:** agreed functional checklist, regressions, visual comparisons, accessibility,
   supported-device performance/soak testing, upgrade/save migration and rights review. Publish only after
   explicit approval; debug signing material is never a production/distribution identity.

“All platforms” is provisionally desktop + Android + iOS + Web, not every CPU, console or store.
Console SDK access, 32-bit Android, store submissions and unsupported legacy browsers are not promised.

## Current evidence boundaries

Six-target source configuration and a manual desktop AI-contract workflow are now available; see
[local AI builds and workflows](local-ai-builds.md). This adds no new platform export/runtime certification.

| Target | Established starting point | Gate still needed |
|---|---|---|
| Android arm64 + x86_64 | v3 APK; API-33 x86_64 host-GPU launch/native/scene/frames/upgrade/Home-resume/private-storage smoke passed | Arm64 phone install/launch; original parse error; software-GPU shader failure; touch/audio/real-save/performance QA |
| Linux x86_64 | Existing game reaches ready main scene and registers both native classes in a new 90-frame headless smoke | Shutdown reports leaked RIDs/resources; exported/rendered runtime and functional acceptance still needed |
| Windows x86_64 | Existing prebuilt native DLLs; neutral workbench export | Reproducible native build and real Windows game tests |
| macOS arm64/x86_64 | Filename mappings, not verified binaries | Apple toolchain/templates, native builds, signing/notarization and Mac tests |
| iOS | Native integration not configured | Extension/static-link/export design, Apple signing and device testing |
| Web | Neutral workbench export only; game-native integration not configured | WASM/native capability design, browser rendering/audio/storage/import tests |

Each target needs its own exact artifact hash and machine-readable pass/fail evidence. Installation,
process presence, scene readiness, rendered frames and actual usability are separate measurements.
No operating system or input path is certified merely by a pure path-policy unit test.

Linux follow-up evidence: `build/linux-game-smoke-20261019/report.json` and `runtime.log`.
The process exited 0 but the test **failed** its clean-shutdown gate because Godot reported five
resource/RID/allocator error lines. Headless drawn-frame count was correctly 0. Do not call this a
rendered Linux release or ignore the cleanup failure because the process exit code was zero.

## Requested authoring and compatibility work — planned, not delivered

An opt-in [local AI review panel and provider layer](local-ai-providers.md) has now been implemented and mock-tested,
separately from these authoring features. It does not replace authored gameplay dialogue and does not establish an
implemented natural-language scene editor, generated-asset editor or phone networking support.

| Workstream | First bounded implementation | Acceptance gate |
|---|---|---|
| Natural-language scene editor | Connect the existing neutral exact-name command parser to a documented scene schema; propose validated edits with preview/confirmation and undo | Unknown/ambiguous assets rejected; atomic apply/undo; save/restart/load; no arbitrary code execution |
| Standard controls | Inventory existing documented keyboard/mouse/menu bindings; define a cross-platform action map and remapping UI, then add accessible touch equivalents | Input/focus/resize tests on real targets; preserve existing defaults; no blanket parity claim |
| “Sibby” mods | Confirm the intended author/package/version; if the user means **sby**, start with the attributed references below | Rights/source/API review; versioned neutral fixtures; dependency/load-order, restoration and persistence tests |
| User mod templates | An original neutral plugin example with manifest, dependency declaration, owned cleanup, diagnostics and license metadata | Install/enable/disable/restart tests; no third-party art or scripts bundled; plugins remain trusted executable code, not sandboxed |
| Asset editor | Import/inspect user-owned neutral assets, validate dimensions/layers/anchors and provenance, preview changes and export a versioned manifest | Round-trip preservation; malformed/path-traversal rejection; non-destructive originals; undo and license metadata |
| Forum suggestions | A reviewed backlog of attributed proposals, with exact source URL, author, date/version, short paraphrase, rights status and local implementation status | No invented quotes, compatibility claims, downloads or copied assets; link-only while rights are unknown |

The workbench's existing exact-name command and loader checks are foundations, **not an implemented
natural-language editor for the game**. “Sibby” is not assumed to be an established integration. Broader
TemplateExtension/ExtraMod/alternate-template parity remains unverified.

## Attributed reference links, not copied implementations

- **sby**, [alternate loader template](https://www.undertow.club/downloads/sby-alternate-loader-template.4762/):
  use its documented registration/dependency surface as a compatibility research target, subject to rights
  and source/version review. This is our proposed investigation, not a claim that sby suggested a feature here.
- [ExtraMod core and template](https://www.undertow.club/downloads/extramod-core-and-mod-template.8227/):
  dependency/load-order research target. Confirm the actual author's attribution and license before any reuse.
- [TemplateExtension](https://www.undertow.club/downloads/templateextension.3679/): public reference;
  source/version/rights and an executable compatibility corpus remain pending.
- [Public reference register](external-sources.md) and [loader contract](loader-compatibility.md) retain the
  previously inspected claims and unknowns. No new forum-post author statements were verified by this pass.

Do not treat public availability or the repository's MIT code license as permission to redistribute
third-party game/mod art, audio, fonts or scripts. Preserve existing assets, keep review builds local, and
record explicit permissions/license terms before adding third-party material or making a public release.
