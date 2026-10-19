# Extensions and plugins

The game code in `game/src` is a 1:1 port of the original ActionScript. Features that are not in the original
(reimplemented Loader mods, fixes, new options) are **extensions**, kept out of the ported classes:

- **Built-in extensions**: `game/src/ext/<name>/`, shipped with the game, each switched on or off in the options.
- **Plugins**: `Mods/Plugins/<name>/`, installed by the player; loaded automatically at startup, each can be
  switched off.

Both use the same API (`SDTExtension`). One switch, **Vanilla mode** (`--vanilla` on the command line), turns every
extension off and gives the original game.

Status: hooks, the extension base class, tick callbacks, events, settings, character code fields, classic menu
buttons, controls in the new menu (with generated settings pages and the list of extensions), hotkeys, dialogue
triggers / variables and plugin loading exist.

Built in: DialogueActions (`dialogueactions`), moremoods (`moremoods`) and MoreTriggers (`moretriggers`), each a
reimplementation of the Loader mod of that name, written from its documentation and behaviour.

## Writing an extension

```gdscript
extends SDTExtension

func _init() -> void:
	id = "example"            # unique, used for settings and file names
	title = "Example"
	default_enabled = false   # on or off until the player chooses

func _setup() -> void:        # declare settings; saved values are loaded afterwards
	setting("strength", 0.5, {"label": "Strength", "min": 0.0, "max": 1.0})

func _enable() -> void:       # register everything here
	on_tick(_tick)            # every game tick, before the game's own logic
	hook_after(&"Her.passOut", _passed_out)

func _disable() -> void:      # hooks and tick callbacks are removed automatically;
	pass                      # undo only what you changed in the game yourself

func _tick() -> void:
	pass

func _passed_out(call: Hooks.Call) -> void:
	print("she passed out, strength ", get_setting("strength"))
```

| Call | What it does |
|---|---|
| `on_tick(fn)` / `on_late_tick(fn)` | `fn()` every game tick (30 per second), before the game's tick / after the game's logic. Extensions run in load order. |
| `hook_before(name, fn, priority, target)` / `hook_after(...)` | `fn(call)` around a game method, see Hooks below. |
| `setting(key, default, info)` | Declares a setting. Type from the default (bool, int, float, String); `info`: `label`, `desc`, `min`, `max`, `step`, `options`. |
| `get_setting(key)` / `set_setting(key, value)` | Read / change (saved immediately, then `_setting_changed(key, value)` is called). |
| `data_dir()` | A folder for the extension's own files, next to the save files. |
| `on_event(name, fn)` | `fn(...)` when something happens; events are listed in `Extensions.EVENTS` (`mods_loaded`, `mood_changed`). |
| `mood()` | Her current mood, including extended moods (see Moods). |
| `charcode_field(key, get, set, reset, after_mods)` | A field in the character code, see below. |
| `on_dialogueactions(setup)` | Dialogue triggers and variables, see [Dialogue triggers](#dialogue-triggers). |
| `menu_control(section, group, spec)` | A control in the new in-game menu: `section` is `"her"`, `"clothes"`, `"him"`, `"scene"`, `"behaviour"`, `"effects"`, `"dialogue"`, `"mods"` or `"settings"`; `group` an existing group of it (e.g. `"Face"`) or a new one. `spec` is a control spec (`MenuWidgets`: `type` toggle / choice / slider / actions / ..., `label`, `tip`, `get` / `set`, optional `visible()` / `enabled()`, `wide`); `MenuSchema.choice(...)` and friends build them. Tagged with the extension's name in the menu; removed when the extension is disabled. Settings declared with `setting()` get a page of their own automatically. |
| `menu_button(menu, x, y, text, on_click)` | A small button in a game menu (`"optionsMenu"`, `"sceneMenu"`, ...), styled like the Loader's mod buttons; `set_color(0x00FF00)` shows a state. |
| `menu_slider(menu, x, y, w, h, value, on_change)` | A slider (ExtSlider, value 0..1) in a game menu. |
| `menu_label(menu, x, y, w, text)` | A text label in a game menu. |
| `menu_add(menu, obj, x, y)` | Any display object (an ExtList, ...) in a game menu; removed when the extension is disabled. |
| `on_key(keycode, fn, label)` | `fn()` when a key is pressed during play (Flash key codes; not while typing). Clashes with the game's keys or other extensions are reported in the log. |

Settings and on/off choices are stored in `extensions.cfg` next to the save files. Test runs with `--save-dir` use
their own copy.

Tick time is measured per extension: it appears in `--profile` output and in the log's `HITCH` lines as
`ext:<id>.tick`.

## Plugins

A plugin is a folder in `Mods/Plugins/` with a `plugin.cfg` and a main script:

```ini
[plugin]
id="myplugin"                 ; unique; also the name of its settings section
name="My plugin"
author="me"
version="1"
main="plugin.gd"              ; extends SDTExtension
depends=["otherplugin"]       ; optional: loaded after these
enabled_by_default=true       ; optional
```

- Scripts are compiled from the folder at startup. They must not use `class_name`, and they load their other
  scripts with `load_script("other.gd")` and files with `file_path("art.png")` instead of `res://` paths.
- A plugin with errors is skipped; the rest of the game and the other plugins still load.
- If the game crashes or hangs while a plugin loads, that plugin is switched off at the next start.
- Plugins can do anything a program can, as Loader mods could: only install plugins you trust.

`tests/plugins/example` is a small working plugin.

## Character code fields

The character code ("key:value;key:value...", used by saved characters and the Generate / Load box) can carry
extension fields, in the same form Loader mods used, so codes shared from the Loader keep working:

```gdscript
charcode_field("tongueLength",
	func(): return str(length),                    # value to write (null leaves the field out; no ";")
	func(value: String, load: CharCode.Load): length = float(value),
	func(load: CharCode.Load): length = 1.0)       # default, when a full code lacks the field
```

- The reset (default) runs only for a **full** character code. Costume-only loads, a mod's built-in character
  data and partial codes (35 or fewer ";"-separated parts, the Loader mods' rule) leave the current value alone.
  `load.kind` tells which one it is (`CharCode.Kind.FULL / PARTIAL / COSTUME / MOD_CHARDATA`).
- `after_mods = true` applies the field once the code's .swf mods have loaded (for values that refer to mod items).
- Fields nobody knows, from a disabled extension or a Loader mod the port does not have, are kept with the
  character and written back out, so saving never loses them.

## Dialogue triggers

Triggers (`[NAME_arg1_arg2]` in dialogue lines) and variables (`*name*`, `"set"`, `"check"`) come from the built-in
DialogueActions. Extensions add their own inside `on_dialogueactions`:

```gdscript
func _enable() -> void:
	on_dialogueactions(func(da):
		da.register_trigger("WAVE", 1, func(args): print("wave ", args[0]))   # [WAVE_3]; -1 = any number of args
		da.vars.register("example.power", func(): return 5, func(v): print("set to ", v))
		da.vars.add_listener("myVar", func(old, new): print(old, " -> ", new)))
```

`setup(da)` runs when DialogueActions is on, and again whenever it is switched back on; everything it registered
is removed when the extension is disabled. Arguments are split at `_`, so variable names used as arguments cannot
contain `_`. Something registered later (e.g. from inside a trigger) goes in `da.run_addon(id, func(d): ...)` so
it is removed with the extension too.

## Moods

The vanilla game has four moods (`Her.currentMood`). Extensions that add moods (moremoods adds 22) take over
`Her.setMood` with a before-hook, show the mood themselves, set a vanilla mood underneath and call
`Moods.set_extended(name)`; they declare their moods with `Moods.register(name, id)`.

Everyone else reads `mood()` (or `Moods.current()`): the extended mood while one is active, else the vanilla one.
The `mood_changed` event reports every change with the mood name.

## Hooks

GDScript cannot replace a method at runtime (the Loader's `lProxy` did this for Loader mods), so each game method
that an extension needs gets a hook point: two guarded blocks named after the original `Class.method`, marked
`# HOOK`. `grep -rn "# HOOK" game/src` lists them all. Hook points are added when an extension needs them.

```gdscript
func lookAt(target: Vector2) -> void:
	if Hooks.has(&"Her.lookAt"):                       # HOOK
		var h := Hooks.before(&"Her.lookAt", self, [target])
		if h.cancelled:
			return
		target = h.args[0]
	...original code, unchanged...
	if Hooks.has(&"Her.lookAt"):                       # HOOK
		Hooks.after(&"Her.lookAt", self, [target])
```

Handlers get a `Hooks.Call` with `name`, `obj` (the object whose method runs), `args`, `result` and `cancel(value)`:

- **Before-handlers** run in `priority` order (lower first, then registration order). They may change `call.args`,
  or call `call.cancel(value)`: the original method is skipped and returns `value`, and the remaining handlers
  (before and after) are skipped too.
- **After-handlers** see the method's return value in `call.result` and may replace it.
- While a hook's handlers run, the hook is inactive, so a handler can call the hooked method itself to run the
  original code.
- A handler registered with a `target` runs only for that object. A hook name covers every instance of the class.
- An unused hook point costs one dictionary lookup, so hooks are fine even in methods that run every tick.

## Testing

`tools/regress.sh` runs the game scenarios in Vanilla mode (their reference dumps must not change because of an
extension), plus `game/debug/ext_checks.gd`, which tests the hook system, the extension lifecycle, tick order and
settings.
