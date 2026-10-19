# Hyper-Deepthroat

**An experimental Godot-based SDT fork by Tricky-Nerdy, developed under the Afterdark Atelier studio identity.** This is an adult-only (18+) modding and local-AI development project, **not a finished release**.

> **Status snapshot — 19 October 2026 (not a new runtime validation):** The game can launch on the Omarchy Linux desktop, and some standard mods load. ExtraMod and the alternate template have been reported to crash the game; compatibility is **not** verified. The proposed replacement UI based on reference screenshots is **not implemented**. Do not confuse an exported build or a passing neutral test with a fully functioning game.

## Development priorities and handoff

1. **Crash reproduction first.** Reproduce the reported ExtraMod and sby alternate-template failures with exact package versions, logs and isolated saves. Fix the underlying failure before claiming compatibility.
2. **Replacement interface second.** Implement the agreed screenshot-referenced local-AI/modding UI, including SBY modding, Extra Mod, developer pages and AI modding. Preserve existing gameplay and provide real working controls rather than mockups.
3. **Integrate after validation.** Once the UI launches and passes functional tests on Linux, integrate and test Android APK and web builds. Record platform-specific results and blockers; do not describe exports as working releases without launch tests.
4. **Developer handoff to 007.** Supply reproduction steps, affected versions, validation evidence, and commit references. Do not infer completion from a successful build alone.

**Integration status:** The upstream docked game menu and the local AI/debugging checkpoint are included in this development branch. The screenshot-referenced replacement interface and release acceptance remain pending.

## What makes this fork different?

This fork builds on [SDT-Godot](https://github.com/asdkfkosafj/SDT-Godot), a port of the original Flash SDT game to Godot 4.7. It retains the base game, Flash compatibility layer, converted assets and mod-loading pathways while developing:

- **Loader modernization:** plugin manifests, dependency and version diagnostics, enable/disable lifecycle, owned replacement restoration, and capability reports. See [loader compatibility](docs/loader-compatibility.md).
- **Local AI integration work:** text/image provider configuration, optional worker connections, and locally scoped connection flows. These are **development features**, not a promise that any particular model, endpoint or image workflow is operational. See [local AI providers](docs/local-ai-providers.md) and [AI development status](docs/independent-ai-progress-2026-10-19.md) where present in the checked-out branch.
- **Developer tooling:** isolated neutral workbench for deterministic asset commands, branching dialogue and save/load tests; regression scripts, diagnostics, portable staging and build verification. See [portable workbench](docs/portable-workbench.md).
- **UI redesign goal:** replace the native interface with the agreed screenshot-based modding/developer UI while preserving vanilla behavior. **Not yet delivered.**
- **Sby compatibility goal:** verify the specific sby alternate template, TemplateExtension and ExtraMod versions, then implement adapters and regression fixtures. **Not yet delivered.**

## What works, what does not

| Area | Current evidence |
| --- | --- |
| Vanilla Godot game | Desktop launch observed; complete gameplay certification pending |
| Standard mods | Some load; universal behavior compatibility **not established** |
| ExtraMod and template | User-reported crashes; priority blockers |
| Native loader lifecycle | Neutral fixtures and integration checks reported passing in [release results](docs/release-results.md); not proof of full legacy mod compatibility |
| Local AI | Integration code and provider documentation under development; runtime/provider-specific behavior requires testing |
| Screenshot-based replacement UI | Pending |
| Linux / Windows / Web | See target-specific evidence in [release results](docs/release-results.md); exports are not all verified |
| Android | Preview work in progress; no certified playable release |

## Getting started (developers)

Requirements: **Godot 4.7.2 standard edition** and Python 3 for supporting scripts. Clone with submodules where native builds are needed:

```sh
git clone --recurse-submodules https://github.com/Tricky-Nerdy/Hyper-Deepthroat.git
cd Hyper-Deepthroat
godot --headless --path game --import
godot --path game
```

On Linux, build the native GDExtension as described in [native/README.md](native/README.md) for features requiring native classes; runtime SWF conversion specifically requires `SWFFile`. On Windows, configure the Godot executable path and run `run_debug.bat`. Do not launch tests against personal saves; use an isolated save directory.

```sh
python3 tools/portable_release.py verify
python3 tools/portable_release.py integration
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

These checks do not substitute for reproducing crashes with actual legacy mod packages.

## Performance problems

If the game runs slowly, please send `%APPDATA%\Godot\app_userdata\SDT Godot\logs\godot.log` right after
playing (later runs replace it). Its `SYSTEM` line says which renderer and graphics card the game uses and whether
the native extension loaded; a `PERF` line every 30 seconds gives the frame rate and where the time goes (game
ticks or drawing); `HITCH` lines describe single slow frames.

On weak or integrated graphics, Godot's lighter renderer can be faster: `run_debug.bat --rendering-method gl_compatibility`.


## How the game is organized

- `game/scenes/main.gd`: main entry point and scripted test options.
- `game/src/`: game logic ported from ActionScript; `game/flash/`: Flash display/runtime compatibility.
- `game/assets/sdt/` and `game/assets/mods/`: converted base and community assets.
- `Mods/` at runtime: Clothing, Hair, Backgrounds, Characters, Dialogue and Plugins.
- `game/src/ext/loader/`: shared loader core; `native/`: optional C++ extension.
- `workbench/`, `tools/`, `tests/`: neutral authoring workbench, packaging and tests.

See [extension authoring](docs/extensions.md), [loader compatibility](docs/loader-compatibility.md), [debugging](docs/debugging.md), [portable workbench](docs/portable-workbench.md), [release results](docs/release-results.md), and [external mod references](docs/external-sources.md). Some development documents may exist only in local, uncommitted work until reviewed and published.

## Local AI: configuration and safety

AI provider configuration is optional. Use local endpoints for private workflows and explicitly approve any LAN route before connecting. Keep bearer tokens in session-only storage or environment variables, **never in committed files, screenshots, logs or URLs**. Distinguish connection tests from successful model inference, and text-provider readiness from image-provider readiness. Never assume a local service is reachable just because its settings appear in a UI.

## Mod compatibility and known blockers

Vanilla SWF mod recognition does **not** establish that every mod's ActionScript behavior, assets, lifecycle and rendering match the Flash original. In particular, the sby alternate loader template, TemplateExtension and ExtraMod require version-specific testing and adapters. The immediate acceptance criterion is: each named package loads without a crash, its features behave as expected, disabling/reloading restores state, and a repeatable regression test documents the result.

## Credits, licenses and redistribution

The underlying port is based on SDT-Godot and the original SDT game. Community mod creators—including sby where their work is referenced—retain credit and rights to their respective contributions. Game art, sounds, fonts and third-party mod assets are **not automatically covered by the code license**. Consult [LICENSE](LICENSE) and the asset attribution notes before redistributing packages or publishing builds.

**Project:** [Tricky-Nerdy/Hyper-Deepthroat](https://github.com/Tricky-Nerdy/Hyper-Deepthroat) · **Studio identity:** Afterdark Atelier · **Release readiness:** blocked pending compatibility, UI and runtime verification.
