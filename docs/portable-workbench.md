# Portable workbench and exports

The workbench demonstrates the loader core independently of third-party game assets. All distributable
workbench art consists of native UI, color swatches and neutral text fixtures. The game's main scene remains
unchanged. Shared implementation lives in `game/src/ext/loader/`.

## Run and verify

Requirements: Python 3.11+ and Godot 4.7.2 with matching standard export templates.

```sh
python3 tools/portable_release.py stage
godot --path build/portable/project
python3 tools/portable_release.py verify
python3 tools/portable_release.py integration
python3 tools/portable_release.py export --target linux --target windows --target web
# Also attempt the other configured targets and retain failures:
python3 tools/portable_release.py export --target all
# Check source/artifact hashes and bundle results after integration and exports:
python3 tools/portable_release.py package
```

`--output <separate-build-directory>` and `--godot <executable>` are supported. Staging copies an explicit
source allowlist into an isolated Godot project, including generated export presets. No game assets,
personal files, arbitrary mods or model weights are scanned or copied. Open the staged project rather
than `workbench/`, whose `core/` references are populated during staging.

## Authoring features

- `wear Blue Jacket; background Station` resolves exact names to typed asset-selection commands.
- `use`, `select`, `wear`, `background`, `costume` and `portrait` are recognized; optional `the` is accepted.
- This is a small deterministic grammar, not unrestricted LLM interpretation. Unsupported, missing and
  ambiguous requests return errors. Entire command batches validate before any state changes.
- Undo restores the previous managed selection batch (32 snapshots maximum).
- Missing asset references and unknown save fields survive restoration.
- The neutral arrival story supports lines, choices, equality conditions, typed variables, assignments,
  jumps and endings. Automatic transitions are bounded to prevent endless loops.
- Story snapshots include a canonical document checksum; changed stories require an explicit migration.
- Save/load uses app-private `user://workbench.json` with temporary-file replacement. This is not a
  power-loss durability guarantee. Web storage depends on browser persistence and user settings.
- Manifest inspection validates `plugin.cfg` without executing its script.

## Deployment status vocabulary

`headless_smoke_passed` means a Linux exported executable constructed the neutral UI and exited successfully.
It is not a graphical, accessibility, device or performance certification. `exported_unverified` means only
that export succeeded and files were produced. `failed` / `runtime_failed` retain logs and return failure.

The results contain source hashes, source revision, checks, export statuses and artifact checksums. Source
hashes identify inputs even when local edits exist at the recorded revision. Windows and Web artifacts
must be tested on their actual runtimes before being promoted to verified support.

`package` requires the verified source inputs to match committed `HEAD`, records that release revision,
checks the artifact hashes and creates `verification-results.zip` plus `SHA256SUMS`. Commit the intended
sources before this final packaging step. The earlier source revision records the build's starting checkout.

| Target | Additional requirements |
|---|---|
| Linux x86-64 | Matching export template; exported executable smoke-tested on Linux |
| Windows x86-64 | Windows template; Windows testing and optional signing |
| Web | Non-threaded Web template; HTTP(S) hosting and browser testing |
| macOS | macOS template, Apple runtime testing, distribution signing/notarization as appropriate |
| Android arm64 | Java/Android SDK configured in Godot, signing, scoped-file import and physical-device verification |
| iOS | Apple team/provisioning configuration, macOS/Xcode, device testing |

Android/iOS presets use debug export; they are not production-signed distributions. Mobile native plugin
loading, arbitrary filesystem import and inference are not verified by the neutral UI demonstration.
The native game's library mappings are separate from these workbench presets.

## CI

`.github/workflows/portable-loader.yml` installs the official engine and templates, verifies their published
SHA-512 checksums, builds the Linux native library, runs integration and exports Linux/Windows/Web workbench
artifacts. Logs and reports are uploaded even after failure. The workflow does not automatically publish a
release. macOS/Android/iOS need their own provisioned runners and device evidence.

The installer is intended for a disposable Linux CI runner:

```sh
python3 tools/install_godot_ci.py --bin-dir /tmp/godot-ci
```

It installs templates in the standard Godot data directory and does not edit editor settings. Downloaded
toolchain artifacts are checked against the publisher's checksum manifest, not an independent signature.
