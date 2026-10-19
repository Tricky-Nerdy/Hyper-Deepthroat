# Local neutral-workbench debugging

The supervisor prepares and runs only the allowlisted neutral workbench. Requirements are Python 3.11+
and the installed Godot executable (locally verified with Godot 4.7.2 on Linux). It does not run the game's
main scene. Use a single supervisor per output directory.

## Run

From the repository root:

```sh
python3 tools/dev_debug.py                 # interactive workbench
python3 tools/dev_debug.py --headless      # same lifecycle without a rendered window
python3 tools/dev_debug.py --godot /path/to/godot --max-restarts 3
tail -F build/debug/events.jsonl           # Linux: follows the active log across rotation
```

The staged project is **`build/debug/portable/project`**, not the release tool's default
`build/portable/project`. `--output /path/to/dedicated-debug-directory` changes this root. Runtime data,
configuration, caches and HOME are isolated under the debug output directory. The engine-reported
`WORKBENCH_READY` message identifies the actual save directory. Existing personal workbench saves are not
loaded automatically. A temporary `--source-root` may contain copies of the fixed staging allowlist for
reproducible edit tests; arbitrary game folders are not imported.

Useful controls:

| Option | Default | Meaning |
|---|---|---|
| `--poll` | 0.2 seconds | Source polling interval |
| `--debounce` | 0.4 seconds | Required quiet period after the last source change |
| `--backoff` | 0.5 seconds | First failed-attempt retry delay; doubles to a 5-second cap |
| `--prepare-timeout` | 60 seconds | Maximum staging subprocess duration |
| `--max-restarts` | 3 | Session-wide automatic failure retries after the first attempt |
| `--max-fps` | 60 | Engine frame-rate cap, including headless runs |
| `--telemetry-interval` | 1 second | Engine metric window; supported range 0.1–60 seconds |
| `--log-bytes` | 1 MiB | Maximum managed JSONL file size |
| `--log-backups` | 3 | Number of rotated files, in addition to the active file |

## Watch, preparation and failure semantics

- Relevant source extensions in `workbench/` and `game/src/ext/loader/` are hashed; import caches and
  `.git`/`__pycache__` are ignored. Atomic replacements and brief deletion gaps are debounced. A failed or
  unstable read keeps its last digest until another poll; a stable deletion changes the snapshot.
- Staging completes a new tree before swapping it into place. Copy/rename failures retain or restore the
  previous complete project. A subsequent staging attempt recovers an interrupted swap's previous tree.
- Normal source edits trigger **process restart**, not state-preserving hot reload. Current dialogue
  position, undo history and unsaved selections are reset. Persisted configurations can be loaded manually.
- Failed preparation, missing executables, runtime crashes and recognized Godot `ERROR:` / `SCRIPT ERROR:`
  output share one retry budget. A zero process exit cannot hide a recognized error. Source edits do not
  reset the failure budget. Fix the source before retries are exhausted, or rerun the supervisor afterward.
- A successful normal child exit stops supervision. Exhausted failures return nonzero (for example 127
  for launch failure, 124 for preparation timeout, or the child's positive failure code). Signal deaths are
  mapped to a nonzero shell-style status. An explicit operator stop returns zero after cleanup succeeds.
- SIGINT/SIGTERM interrupt preparation and backoff. The workbench receives a local stop-file request first
  so it can quit normally. Nonresponsive children fall back to terminate/kill. Pipes/readers are joined and
  closed, and prior Python signal handlers are restored. POSIX process groups cover non-detached descendants.

## Local records and engine metrics

`events.jsonl` records wall-clock and monotonic time. Default retention is at most four 1-MiB managed files:
the active log and `.1`–`.3`. Oversized records are truncated, old oversized managed logs retain their newest
complete lines, and excess numbered backups are removed. Retention deliberately discards old log history.
It does not impose a quota on saves or staged projects. Console history is controlled by the terminal.
The CLI echoes child output only to an interactive terminal; piped runs use the JSONL file so an unread
stdout pipe cannot fill with copied engine output.

The staged **debug** project disables Godot's duplicate file logger, including its desktop `.pc` override.
Only combined stdout/stderr goes through the bounded recorder. Redirecting Godot's log to `/dev/null` was
tested and rejected: its rotation code produces an engine error. Ordinary staging/exports keep their
original logging settings unless `--disable-file-logging` is explicitly requested for `stage`.

These records have different meanings:

- `heartbeat`, `metric_source="supervisor"`: the child has not exited according to `Popen.poll()`. This is
  **not** a responsiveness check, engine-frame measurement, browser refresh or service-health probe.
- `engine_metrics`, `metric_source="godot"`: an opt-in window emitted by the running workbench. It includes
  observed callback FPS, engine-reported FPS, callback frame-gap mean/p95/max, the most recent engine process
  time, engine static allocated bytes and object count. Samples are capped at 4096 gaps per window and
  report truncation. Static allocated memory is **not process RSS**, GPU memory or a leak diagnosis.
- Short startup windows may exceed the requested FPS cap. Headless callback gaps do not measure rendered
  presentation, GPU performance or input latency. Treat these as debugging observations, not benchmarks.

No network telemetry, installed-service management or browser auto-refresh is implemented.

## Godot breakpoints and stepping

1. Run the supervisor once to stage the project, then stop it with Ctrl+C. Keep it stopped while stepping.
2. Open the staged neutral project in the editor. On Linux, this preserves the same isolated profile:

   ```sh
   env HOME="$PWD/build/debug/home" \
     XDG_DATA_HOME="$PWD/build/debug/user-data" \
     XDG_CONFIG_HOME="$PWD/build/debug/config" \
     XDG_CACHE_HOME="$PWD/build/debug/cache" \
     godot --editor --path build/debug/portable/project
   ```

3. In the script editor open `main.gd`, find `_apply()`, and click its gutter (F9 by default) to set a
   breakpoint at `var proposal := commands.propose(_request.text)`.
4. Run the project with F5 (or the current `main.tscn` with F6). In the workbench, click **Apply**. Execution
   should stop at the breakpoint; inspect `commands`, `state`, `_request.text` and the debugger call stack.
5. **Step Into** (normally F11) follows `propose()` in `core/asset_commands.gd`. **Step Over** (F10) evaluates
   the current statement. Use the debugger toolbar's Step Out/Continue controls to return; Continue is F12
   by default. Use F8/Stop to end the debug process. Shortcuts can be remapped in the editor.
6. To examine failure atomically, stop, set the request to `wear Missing Jacket`, break inside `propose()`,
   and inspect the returned error and unchanged selection state. Use the editor's Profiler/Monitors for
   interactive engine measurements; this supervisor is not a debugger transport.
7. Apply durable fixes to the original `workbench/` or shared neutral core, then restage/restart. Edits made
   **only** in the staged directory are temporary and will be overwritten. Editor live-property inspection
   is separate from supervisor restarts; state-preserving script hot reload is not guaranteed here.

The sequence above describes manual editor operation. The automated session below uses the real editor's
debug adapter; it does not claim to click the toolbar or simulate human mouse/keyboard input.

### Reproducible rendered editor/DAP session

With a graphical display available, choose a **new empty** evidence directory:

```sh
python3 -W error::ResourceWarning tools/editor_debug.py --output /tmp/workbench-editor-evidence-001
python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_editor_debug.py' -v
```

`tools/editor_debug.py` stages a temporary neutral copy, opens an actual rendered Godot editor and launches
the workbench through its Debug Adapter Protocol. Its client connects only to `127.0.0.1`; debug/LSP ports
are chosen separately from other editor sessions. The supervisor stays out of this paused session.

The fixture injects two requests through the normal `_apply()` handler: a valid jacket/background selection
and a missing asset. For each request the tool verifies a breakpoint in `_apply()`, reads locals/evaluates
the request and managed state, performs real **Step Into** to `propose()`, **Step Over** within that function,
and stops again to inspect the result. The valid request must succeed; the missing request must report
`missing_asset` with equal before/after selection state. Breakpoint lines are discovered from the staged
source rather than hardcoded. Only the fixture is instrumented; original neutral/game source hashes are
checked afterward, including the existing `game/project.godot` edit.

Evidence consists of bounded `events.jsonl`, `summary.json`, `editor.png` (the paused editor's own viewport),
`workbench.png` and `missing.png` (the rendered workbench viewport). These captures do not photograph other
desktop applications. The tool verifies PNG dimensions, actual non-headless rendering, temporary save paths,
zero captured engine-error output, normal editor/runtime exit and disappearance of the runtime PID.

Godot's `process` event may omit a PID; the harness instead uses the workbench's engine-reported readiness
PID. It waits for asynchronous scope-variable delivery before stepping to avoid stale-frame diagnostics.
Editor script cache, helper plugin, profiles and saves all live in the temporary project/profile. The helper
plugin provides app-only captures and graceful editor shutdown and is removed with the fixture.

The last three metric windows after continuing provide a short rendered-session callback sample. Raw
metrics also contain startup and debugger pauses, so they must not be summarized as uninterrupted rendering
performance. Callback gaps are still not GPU execution or presentation timing; engine static allocation is
not process RSS. This exercise establishes actual debugger operation, not state-preserving hot reload,
manual toolbar interaction, browser refresh, service health or additional mod compatibility.

## Real GUI Apply/Undo/Save/Load check (Hyprland Lua)

This is a separate input path from DAP and the headless supervisor check. It requires the local graphical
Hyprland session and installed `hyprctl`:

```sh
python3 -W error::ResourceWarning tools/gui_debug.py --output /tmp/workbench-gui-evidence-001
python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_gui_debug.py' -v
```

Choose a new empty output directory. The tool stages a neutral project and runs it twice with the same
temporary HOME/data/config/cache paths. It discovers exactly one mapped application window by the owned
process PID/address, focuses it with `hl.dispatch(hl.dsp.focus({window='address:...'}))`, and navigates controls
using real compositor **Tab/Space keyboard events**. It does not claim mouse clicks or physical human input.

Each key uses `hl.dsp.send_key_state` with explicit modifiers and separate down/up events, following the
installed Omarchy `clipboard.lua` helper. Key down atomically checks the focused PID/address; key up remains
targeted to that same owned window even if focus changes. Failed focus checks abort input. Releases also run
after interruption or a recording failure. No `wtype`, held-modifier merging or clipboard replacement is
used. Only the owned window is logged; unrelated window titles are not recorded.

The actual GUI sequence is:

1. Activate Apply and verify Blue Jacket + Station, then activate Undo and verify the empty selection.
2. Verify empty-history Undo feedback. Type `wear gold jacket; background garden` into the LineEdit using
   explicit keyboard events, activate Apply and Save, and compare the isolated save to live state.
3. Shut down normally and restart with the same temporary profile. Verify empty transient selection,
   unchanged saved bytes, and actual Load activation restoring Gold Jacket + Garden and the story snapshot.
4. Replace only that isolated save with malformed JSON, activate Load, and require `invalid_json` without
   changing selection, story or undo state. Repeat with a valid envelope whose candidate assets differ but
   whose story digest is incompatible; require rejection without a partial asset commit.
5. Restore valid saved bytes and activate Load to verify recovery; close both workbench instances cleanly.

`tools/fixtures/gui_observer.gd` is attached only to the staged scene. It reads state/focus, records incoming
key events and button signals, and captures the app's own rendered viewport. It never calls `_apply()`,
`_undo()`, `_save()`, `_load_save()`, `Input.parse_input_event()` or `emit_signal()` to perform the actions.
There is no DAP connection in this GUI harness. Thus input commands, native events, button activation and
resulting state are independently observable.

The output includes `events.jsonl`, `summary.json`, per-session snapshots and app-only PNGs for Apply, Undo,
Save, loaded state and both rejected saves. All source hashes are checked, including the existing
`game/project.godot` edit. Temporary profiles are removed after cleanup; evidence remains local. This check
establishes the tested keyboard GUI path, not mouse/touch/controller parity, browser refresh, hot reload,
pixel-perfect rendering or additional legacy-mod compatibility.

## Reproducible checks

```sh
python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_dev_debug.py' -v
LIVE_GODOT_DEBUG=1 DEV_DEBUG_EVIDENCE_DIR=/tmp/workbench-debug-evidence \
  python3 -W error::ResourceWarning -m unittest discover -s tests -p 'test_dev_debug_live.py' -v
```

The opt-in POSIX live check copies neutral sources, launches actual Godot, atomically edits only that
fixture, deletes/restores a fixture source to exercise staging failure/recovery, and signals shutdown.
It verifies three engine starts, two process reloads, joined readers, zero runtime shutdown exits, reaped
PIDs, isolated engine save paths, no duplicate engine log files and unchanged original source hashes.
An optional evidence directory retains the local JSONL and summary after temporary fixtures are removed.

See [debug-handoff.md](debug-handoff.md) for this milestone's measured results, and
[loader-compatibility.md](loader-compatibility.md) for legacy compatibility status. Those unimplemented
adapters and pixel-perfect parity are not established by neutral debugging checks.
