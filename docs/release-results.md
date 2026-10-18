# Loader maintenance preview 0.1.0

This maintenance fork builds on `asdkfkosafj/SDT-Godot` at `316cbf5`. Upstream and the starting branch were
identical when checked, so a history rebase was unnecessary. The existing Godot game remains the integration
target; the neutral workbench is auxiliary tooling for reproducible loader and authoring checks.

## Implemented

- Normalized legacy `plugin.cfg` manifests with loader API, numeric dependency constraints, ordering,
  platform/capability requirements, conflicts and actionable diagnostics.
- Dependency-aware enable/disable, retry of blocked packages, explicit setup/enable failure handling,
  duplicate detection, reverse-order shutdown and persisted restart-required transitions.
- Owned replacement stacks that restore previous owners or the original value.
- Separate reporting of SWF conversion and native acceleration capabilities.
- Neutral exact-name asset commands, atomic managed batches/undo, branching story fixtures, validated
  save/resume and preservation of unresolved asset references.
- Isolated workbench staging, source/artifact hashes, Linux/Windows/Web exports, evidence packaging and CI.
- Linux native library builds and filename mappings for additional native targets.
- Regression-runner accounting for failed child processes, incomplete dump sets and stress-test failures.

## Measured local verification

Engine: `4.7.2.stable.arch_linux.ed1daf0bf`, Linux x86-64.

| Check | Result |
|---|---|
| Standalone loader/command/story/storage checks | **44 passed, 0 failed** |
| Existing-project neutral loader integration | **27 passed, 0 failed** |
| Python staging/checksum and regression-runner checks | **8 passed** |
| Python compilation, shell syntax, diff whitespace | Passed |
| Native Linux x86-64 debug build | Built and loaded; neutral SWF header parsed |
| Native Linux x86-64 release build | Built; separate release-runtime testing pending |

The integration scene does not construct DT. It checks the real extension runtime with generated neutral
plugins and an isolated temporary save. Full gameplay regressions, a complete mod corpus, graphical pixel
comparisons, accessibility, long-running performance and physical-device testing are not established here.

## Neutral workbench deployment attempts

| Target | Actual result |
|---|---|
| Linux x86-64 | Exported executable passed headless UI startup/command smoke check |
| Windows x86-64 | Exported; Windows runtime verification pending |
| Web | Exported; browser verification pending |
| macOS | Export failed: local `macos.zip` template unavailable |
| Android arm64 | Export failed: Java/Android SDK paths not configured in Godot |
| iOS | Export failed: Apple team ID not configured; macOS/Xcode/device verification also required |

These downloadable applications are neutral tooling, not exported third-party game content. Passing export
does not imply a verified game port on that platform. Failed-target logs are included in the evidence bundle.

## Compatibility limits

Full TemplateExtension, alternate-template and ExtraMod behavior is **unverified**; new adapters for these
packages are not implemented in this preview. Arbitrary ActionScript compatibility and pixel-perfect parity
are not claimed. See [loader-compatibility.md](loader-compatibility.md) and
[external-sources.md](external-sources.md). Supplied image-edit/rotation links are research references;
ComfyUI integration and model execution are not part of this release.

## Reproduce

```sh
git submodule update --init native/godot-cpp
# With SCons installed in an isolated environment:
scons -C native platform=linux arch=x86_64 target=template_debug -j4
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tools/portable_release.py integration
python3 tools/portable_release.py export --target all
# The all-target export returns failure while any configured target is blocked.
# Commit the verified source inputs, then package the successful outputs and all results:
python3 tools/portable_release.py package
```

Artifacts: `workbench-linux.zip`, `workbench-windows.zip`, `workbench-web.zip`, `verification-results.zip`,
and `SHA256SUMS`. Evidence records the build checkout, exact source hashes and the committed release revision.
The CI workflow retains its own results separately; local verification does not imply that CI has passed.
