# Loader compatibility contract (API 1)

This fork extends the existing `Extensions` / `SDTExtension` runtime. The upstream target remains SDT v1.21.1b,
with a 700 × 600 logical viewport and 30 Hz simulation. The portable workbench is an auxiliary neutral test
application using the same loader-core files; it does not replace the game.

## Native plugin manifests

Existing `Mods/Plugins/<folder>/plugin.cfg` files continue to work. Opaque nonempty version labels remain
usable with unconstrained dependencies. Numeric comparisons require one to three components (`1`, `1.2`,
`1.2.3`). API 1 supports exact numeric comparisons and space-separated intersections; semantic prerelease
comparisons, caret/tilde ranges, and OR expressions are not supported.

```ini
[plugin]
id="sample"
name="Sample plugin"
author="Example author"
version="1.2.0"
main="plugin.gd"
loader_api=1
enabled_by_default=true
reloadable=true
depends=["foundation"]
dependency_versions={"foundation": ">=1 <2"}
optional_depends=[]
load_after=[]
load_before=[]
conflicts=[]
requires=[]
platforms=[]
```

`depends` requires an active package. `optional_depends` is not required when absent; when installed, its
version constraint and ordering are checked. Ordering preferences apply only to installed packages.
Cycles, duplicate IDs, missing requirements, version mismatches, conflicts, platform restrictions and
missing capabilities are distinct diagnostics. IDs are case-sensitive. `platforms` uses `OS.get_name()`
values such as `Linux`, `Windows`, `macOS`, `Android`, `iOS`, and `Web`.

Entry scripts are relative `.gd` paths without parent traversal or absolute/drive paths. Plugins remain
trusted executable code, as documented in [extensions.md](extensions.md); path normalization is not a sandbox.

## Lifecycle

Packages have explicit `discovered`, `validated`, `resolved`, `loading`, `active`, `disabled`, `blocked`,
`failed`, or `restart_required` states. Enabling validates and activates requirements first. Blocked
packages can be retried after their requirements are enabled. Disabling a requirement disables its
dependents first. An explicit `fail_initialization(reason)` in `_setup()` or `_enable()` records a failure;
failed setup requires a restart. Arbitrary GDScript exceptions are not catchable transactions.

`reloadable=false` schedules a disable in saved configuration, leaving the running instance and its
dependents active until restart. Vanilla mode is likewise scheduled when a non-reloadable package is active.
Shutdown releases packages in reverse load order.

`Extensions.report()` includes runtime capabilities and package IDs, versions, states and diagnostic counts.
`Extensions.report(true)` additionally includes plugin-supplied messages, which may contain local information
and should be reviewed before sharing. Reported package names/IDs also deserve review before publication.

## Owned replacements

```gdscript
Extensions.owned_slots.define("preview.background", getter, setter)
# Inside an enabled SDTExtension:
replace_slot("preview.background", replacement)
```

The slot captures a baseline and tracks a stack of owner replacements. Disabling an owner removes its
entries, revealing the previous owner or baseline. Direct mutations outside managed slots remain the
extension's responsibility. The existing hooks, callbacks, widgets, hotkeys and fields retain their cleanup.

## Capability and legacy status

| Feature | Status in this change |
|---|---|
| Native GDScript plugin manifests and dependency lifecycle | Implemented; neutral core and integration fixtures |
| Owned replacement slots | Implemented; restoration fixtures |
| SWF conversion | Existing implementation; requires `SWFFile` native class |
| Native acceleration | Independent capability; requires `SDTNative` |
| Standard SWF mod kit | Existing implementation; no new blanket compatibility claim |
| TemplateExtension | Public reference located; complete compatibility unverified |
| Alternate loader template | Additional APIs documented upstream; adapter not implemented here |
| ExtraMod | Dependency/load-order documentation located; adapter not implemented here |
| Arbitrary Loader ActionScript | Unsupported as a blanket claim |
| Pixel-perfect parity | Not established by these checks |

An imported package is not necessarily behavior-compatible. Track recognition, inspection, conversion,
registration, behavior, restoration, persistence, and rendering independently for each versioned fixture.
No third-party Loader package or model weights are bundled by the workbench release.

## Verification

```sh
python3 tools/portable_release.py verify
python3 tools/portable_release.py integration
```

The first command stages only allowlisted core/neutral files. The second runs the real project's loader
in a dedicated scene with generated neutral plugins and a temporary save directory, without starting DT.
Both require Godot 4.7.2 (or `--godot <path>`). Build the native library first for a clean integration run.
