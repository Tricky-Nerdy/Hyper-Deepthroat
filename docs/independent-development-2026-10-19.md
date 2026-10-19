# Independent code pass while v3 is under external review

## Boundaries

No emulator, adb, APK installation, export, deployment or publication was run. This pass did not write to
`build/android-game-preview`. Luma Actual's existing-v3 tests remain independent. Source edits have not
been incorporated into any APK. Existing worktree edits and assets were retained; no session/worktree was
created and no third-party material was downloaded.

## Implemented: final mod ownership teardown

`game/flash/swf_mod.gd` now provides an explicit, repeatable final `shutdown()`:

- Breaks the cached mod/library and bytecode/host reference cycles that RefCounted cannot collect.
- Releases the cached mod's library/bytecode references and clears the static loaded-mod cache.
- Removes this loader's handlers, including legacy duplicate registrations, while preserving other handlers.
- Makes registration idempotent when native SWF support exists.

`game/flash/flash_runtime.gd` calls teardown during final predelete, after its existing orphan-display-object
cleanup. This is **not a live-mod unloading API**: live symbols must retain their library/bytecode until
their display objects are destroyed. No in-game behavior, content or asset format was intentionally changed.

## Verification

`tests/test_mod_shutdown.py` copies source into a unique temporary directory under this repository's
`build/`, excluding original asset libraries, import caches and export credentials. It generates an empty
neutral library and runs actual headless Godot against `tools/fixtures/mod_shutdown_checks.gd`.

The fixture establishes retained ownership before teardown, verifies weak-reference release and cleared
back-references/cache afterward, tests duplicate owned-handler removal, preservation of another handler,
repeatable shutdown and idempotent registration. The passing run reports no captured engine/script errors.
All original imports and personal profiles are avoided. A frame-limit fallback bounds fixture assertion failures.

Focused command:

```sh
python3 -W error::ResourceWarning -m unittest discover -s tests -p test_mod_shutdown.py -v
```

Broader deliberately non-Android suite: **44 passed, 0 failures/errors/skips**.
Evidence: `build/independent-validation-4f93ztg4/report.json` and `tests.log`. This includes the new ownership
fixture, content paths, supervisor, editor/GUI guard, portable-tool and regression-accounting tests. Android
tests, live device tests and full-game acceptance were not run by this pass.

## Remaining work

This proves a concrete mod ownership fix, **not** resolution of all Linux shutdown leaks. The prior
unmodded-game test's texture/text/resource leaks cannot be attributed to this mod cycle without evidence.
Next independent step: reproduce those remaining leaks in a separate Linux-only stage, trace orphan/cache
ownership and add a bounded regression for each confirmed cause. Software shader failures and full-game
functional review also remain open. Physical-phone APK findings belong to Luma Actual's independent run.
