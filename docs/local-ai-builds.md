# Local AI build and workflow coverage

This is configuration coverage, **not six completed platform releases**. The existing game/assets remain
the product; the neutral workbench is a separate loader demonstration and intentionally has no AI UI.
Nothing here authorizes publishing, deploying, installing APKs or changing the frozen v3 review tree.

## Prepare, without exporting

```sh
python3 tools/game_build_plan.py --output build/local-ai-plan
```

This creates a new plan directory with six-target preset text, provider source hashes and explicit blockers.
It refuses existing outputs, source directories and `build/android-game-preview` (including descendants).
To copy the existing game into a **new** owned stage without invoking Godot/SDKs:

```sh
python3 tools/game_build_plan.py --output build/local-ai-stage --stage
```

Network export capability requires `--enable-ai-network`; runtime providers remain disabled by default and
LAN consent remains separate. Staging excludes the import cache and common signing/credential files;
review the stage before any authorized export. No automated secret scan or rights clearance is implied.

| Target | Configuration | Still unverified / blocked |
|---|---|---|
| Linux x86_64 | Game presets and local headless provider/UI contracts | Rendered/exported gameplay acceptance; remaining shutdown resources |
| Windows x86_64 | Presets; checksum-verified engine installer; manual CI contracts | Windows CI execution and real game/native/input/save tests |
| macOS universal | Presets; app-bundle engine installer; manual CI contracts | macOS CI execution, native builds, signing/notarization and game tests |
| Android arm64/x86_64 | Explicit INTERNET/feature opt-in; source-only packaging verification updates | Build/install freeze; physical phone, cleartext/TLS/LAN, touch/background tests |
| iOS | Preset and opt-in local-network purpose string | Native integration, Xcode/team signing, ATS policy and device acceptance |
| Web | Preset without native-extension/thread support | Existing game-native capability gap; HTTPS/CORS/private-network/browser tests |

An iOS purpose string does not bypass ATS, grant OS permission or make HTTP work. No global ATS exemption
or insecure TLS override is added. Browser network security similarly remains enforced.

## Android packaging source changes only

`tools/android_preview.py` accepts `--enable-ai-network` only for a version code above 3 and separate output;
it checks the final manifest's INTERNET permission against the explicit option. The runtime-preview helper
now defaults future work to version 4 / `0.1.3-local-ai-review` in `build/game-runtime-preview-v4` and rejects
the frozen review directory. No v4 APK was built. Runtime-preview staging still reuses the old verified native
binaries; it is not a native rebuild or evidence of updated native behavior. Do not run either packaging
helper until the Android owner lifts the freeze. Existing v3 contains none of the AI integration.

## Workflows and tests

`.github/workflows/local-ai-contracts.yml` is manual-only, read-only and has no deployment or artifact upload.
It configures Linux/Windows/macOS runners with a SHA-512-verified engine, runs neutral loopback/UI/profile
contracts and platform-tool boundary tests, then writes a six-platform plan. It neither exports nor signs
the game. Cross-platform CI execution has not been observed locally.

The existing portable-loader workflow remains responsible for its neutral workbench and game-loader checks;
its full Python test discovery also includes the new tests. AI networking is not added to workbench exports.
The installer keeps its existing Linux executable name/default portable template scope; `--engine-only`
avoids templates and `--template-scope all` supports separately authorized future tooling setup.

```sh
python3 -W error::ResourceWarning -m unittest discover -s tests -p test_ai_providers.py -v
python3 -W error::ResourceWarning -m unittest discover -s tests -p test_platform_workflows.py -v
```

Platform tests render Android preset text in temporary directories and inspect source/build boundaries;
they do **not** run an emulator, adb, SDK build, APK export or install. See
[provider configuration and limitations](local-ai-providers.md) and [platform gates](platform-completion-plan.md).
