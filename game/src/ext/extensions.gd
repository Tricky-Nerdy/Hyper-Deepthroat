class_name Extensions
extends RefCounted
## Port extension (not in the original game): loads, enables and runs extensions (see SDTExtension).
##
## - Built-in extensions are listed in BUILTIN; plugins from Mods/Plugins share the same lifecycle.
## - Which extensions are on, and their settings, are kept in extensions.cfg next to the save files
##   (FlashSharedObject.save_dir, so --save-dir test runs use their own copy).
## - "Vanilla mode" (setting, or --vanilla on the command line) keeps every extension off.
## - Tick callbacks run at two fixed points of the game tick (Flash.tick_before / tick_after), in extension load
##   order; their time shows in --profile and in HITCH lines as "ext:<id>".

## Built-in extensions (script paths), in load order.
const BUILTIN: Array[String] = [
	"res://src/ext/dialogueactions/dialogue_actions.gd",
	"res://src/ext/moremoods/moremoods.gd",
]

const CONFIG_FILE := "extensions.cfg"
const PackageManifest = preload("res://src/ext/loader/package_manifest.gd")
const PackageResolver = preload("res://src/ext/loader/package_resolver.gd")
const RuntimeCapabilities = preload("res://src/ext/loader/runtime_capabilities.gd")
const OwnedSlots = preload("res://src/ext/loader/owned_slots.gd")

static var owned_slots := OwnedSlots.new()
static var plugin_manifests: Dictionary = {}
static var _plugin_configs: Dictionary = {}

static var all: Array[SDTExtension] = []
static var by_id: Dictionary = {}
static var vanilla_mode := false
static var started := false

static var _config: ConfigFile = null
static var _ticks: Array = []        # [extension, Callable], before the game's tick
static var _late_ticks: Array = []   # [extension, Callable], after it
static var _installed := false
static var _events: Dictionary = {}   # event name -> [[extension, Callable]]
static var _widgets: Array = []      # [extension, FlashDisplayObject]
static var _keys: Dictionary = {}    # Flash key code -> [[extension, Callable, label]]

## Flash key codes the vanilla game uses during play (DT.keyPressed), for clash warnings.
const VANILLA_KEYS := [16, 17, 191, 32, 65, 80, 79, 73, 85, 89, 67, 88, 66, 72, 75, 84, 83, 74]

## Plugins found in Mods/Plugins: id -> {"folder", "name", "author", "version", "error"} ("" = loaded).
static var plugins: Dictionary = {}
const LOADING_MARKER := "loading_plugin.txt"

## Events extensions can listen to with SDTExtension.on_event(): name -> description.
const EVENTS := {
	"mods_loaded": "a character's .swf mods (or mods chosen in a picker) finished loading",
	"mood_changed": "her mood changed; argument: the mood name (an extended one if active, see Moods)",
}


## Called once the game is built (end of DT.initGame): loads the built-in extensions and enables those that are on.
static func start() -> void:
	if started:
		return
	started = true
	_load_config()
	vanilla_mode = "--vanilla" in OS.get_cmdline_user_args() or bool(_config.get_value("extensions", "vanilla_mode", false))
	_install_tick()
	for path in BUILTIN:
		var scr = load(path)
		if scr == null:
			push_error("extensions: cannot load %s" % path)
			continue
		add(scr.new())
	load_plugins(Flash.mods_dir("Plugins"))


## Adds an extension (built in or a plugin): declares its settings, loads saved values, enables it if it is on.
static func add(ext: SDTExtension) -> bool:
	if ext.id == "" or by_id.has(ext.id):
		push_error("extensions: missing or duplicate id '%s'" % ext.id)
		return false
	if _config == null:
		_load_config()
	all.append(ext)
	by_id[ext.id] = ext
	ext._setup()
	if not ext.initialization_error.is_empty():
		var reason := ext.initialization_error
		_disable(ext)
		_state(ext.id, "failed", reason)
		return false
	ext._setup_complete = true
	for s in ext.settings():
		if _config.has_section_key(ext.id, s["key"]):
			ext._settings[s["key"]]["value"] = ext._coerce(s, _config.get_value(ext.id, s["key"]))
	if is_on(ext.id):
		_enable(ext)
	return true


## Removes an extension entirely (disables it first). Used by tests and when a plugin is unloaded.
static func remove(ext_id: String) -> void:
	var ext: SDTExtension = by_id.get(ext_id)
	if ext == null:
		return
	for dependent in _dependents(ext_id):
		if dependent.enabled:
			_disable(dependent)
	if ext.enabled:
		_disable(ext)
	all.erase(ext)
	by_id.erase(ext_id)


static func get_extension(ext_id: String) -> SDTExtension:
	return by_id.get(ext_id)


## Whether the extension with this id is (or would be) enabled: the player's choice, else its default.
static func is_on(ext_id: String) -> bool:
	if vanilla_mode:
		return false
	var ext: SDTExtension = by_id.get(ext_id)
	var dflt := ext.default_enabled if ext != null else false
	return bool(_config.get_value("enabled", ext_id, dflt)) if _config != null else dflt


## Switches an extension on or off and remembers the choice.
static func set_enabled(ext_id: String, on: bool) -> void:
	if _config == null:
		_load_config()
	if on:
		_activate(ext_id)
		return
	var ext: SDTExtension = by_id.get(ext_id)
	if ext == null:
		if plugins.has(ext_id):
			_config.set_value("enabled", ext_id, false)
			_save_config()
		return
	var affected: Array = _dependents(ext_id) + [ext]
	var restart := false
	for candidate in affected:
		_config.set_value("enabled", candidate.id, false)
		if candidate.enabled and not plugin_manifests.get(candidate.id, {}).get("reloadable", true):
			_state(candidate.id, "restart_required", "disable scheduled for next start")
			restart = true
	_save_config()
	if vanilla_mode or restart:
		return
	for candidate in affected:
		if candidate.enabled:
			_disable(candidate)


## Retry blocked packages after validating the entire requested requirement closure.
static func _activate(ext_id: String) -> void:
	if not by_id.has(ext_id) and not plugin_manifests.has(ext_id):
		return
	var ids := _requirements(ext_id)
	if not ext_id in ids:
		ids.append(ext_id)
	var selected: Array = []
	var available: Dictionary = {}
	for ext in all:
		if not plugin_manifests.has(ext.id) or not ext.id in ids:
			available[ext.id] = {"version": ext.version if ext.version != "" else "1",
				"enabled": ext.enabled or ext.id in ids}
	for pid in ids:
		if plugin_manifests.has(pid):
			var p: Dictionary = plugin_manifests[pid].duplicate(true)
			p["enabled"] = true
			selected.append(p)
		elif not by_id.has(pid):
			_state(ext_id, "blocked", "missing dependency %s" % pid)
			return
	var resolution := PackageResolver.resolve(selected, available, RuntimeCapabilities.report().capabilities, OS.get_name())
	if not resolution.errors.is_empty():
		_state(ext_id, "blocked", JSON.stringify(resolution.errors))
		return
	for pid in ids:
		_config.set_value("enabled", pid, true)
	_save_config()
	if vanilla_mode:
		return
	var ordered: Array = ids.filter(func(pid): return not plugin_manifests.has(pid)) + resolution.order
	for pid in ordered:
		if not by_id.has(pid):
			_load_plugin(pid, plugins[pid].folder, _plugin_configs[pid], data_root().path_join(LOADING_MARKER))
		elif not by_id[pid].enabled:
			_enable(by_id[pid])
		else:
			_state(pid, "active")
		if not by_id.has(pid) or not by_id[pid].enabled:
			if pid != ext_id:
				_state(ext_id, "blocked", "dependency not active: %s" % pid)
			return


## Turns Vanilla mode on (all extensions off) or off (each back to its own on/off choice).
static func set_vanilla_mode(on: bool) -> void:
	if _config == null:
		_load_config()
	_config.set_value("extensions", "vanilla_mode", on)
	_save_config()
	if on:
		for ext in all:
			if ext.enabled and not plugin_manifests.get(ext.id, {}).get("reloadable", true):
				_state(ext.id, "restart_required", "vanilla mode scheduled for next start")
				return
	vanilla_mode = on
	var ordered := all.duplicate()
	if on:
		ordered.reverse()
	for ext in ordered:
		var want := is_on(ext.id)
		if want and not ext.enabled:
			_enable(ext)
		elif not want and ext.enabled:
			_disable(ext)
	if not on:
		for pid in plugin_manifests.keys():
			if not by_id.has(pid) and bool(_config.get_value("enabled", pid, false)):
				_activate(pid)


## Folder for extension files, next to the save files.
static func data_root() -> String:
	return FlashSharedObject.save_dir.path_join("extensions")


# ---------------------------------------------------------------- internals

static func _enable(ext: SDTExtension) -> void:
	if not ext._setup_complete:
		_state(ext.id, "failed", "setup did not complete; restart required")
		return
	for dep in plugin_manifests.get(ext.id, {}).get("depends", []):
		if not by_id.has(dep) or not by_id[dep].enabled:
			_state(ext.id, "blocked", "dependency not active: %s" % dep)
			return
	ext.initialization_error = ""
	ext.enabled = true
	ext._enable()
	if not ext.initialization_error.is_empty():
		var reason := ext.initialization_error
		_disable(ext)
		_state(ext.id, "failed", reason)
	else:
		_state(ext.id, "active")


static func _disable(ext: SDTExtension) -> void:
	ext.enabled = false
	Hooks.remove_owner(ext.id)
	CharCode.remove_owner(ext.id)
	Moods.unregister_owner(ext.id)
	for w in _widgets.filter(func(x): return x[0] == ext):
		if is_instance_valid(w[1]) and w[1]._flash_parent != null:
			w[1]._flash_parent.removeChild(w[1])
	_widgets = _widgets.filter(func(x): return x[0] != ext)
	for k in _keys:
		_keys[k] = _keys[k].filter(func(x): return x[0] != ext)
	for name in _events:
		_events[name] = _events[name].filter(func(e): return e[0] != ext)
	_ticks = _ticks.filter(func(t): return t[0] != ext)
	_late_ticks = _late_ticks.filter(func(t): return t[0] != ext)
	ext._disable()
	owned_slots.release(ext.id)
	_state(ext.id, "disabled")


## Releases every extension when the game quits (main scene _exit_tree). Plugin scripts are compiled at runtime;
## if static lists still hold their instances while the engine shuts down, Godot can crash on exit.
static func shutdown() -> void:
	var ordered := all.duplicate()
	ordered.reverse()
	for ext in ordered:
		if ext.enabled:
			_disable(ext)
	all.clear()
	by_id.clear()
	_ticks.clear()
	_late_ticks.clear()
	_events.clear()
	_keys.clear()
	_widgets.clear()
	Hooks._hooks.clear()
	CharCode._fields.clear()
	CharCode._order.clear()
	CharCode._pending.clear()
	Moods._registered.clear()
	Moods._extended = ""
	owned_slots.clear()
	plugin_manifests.clear()
	_plugin_configs.clear()
	plugins.clear()
	_config = null
	started = false


# ---------------------------------------------------------------- plugins

## Loads every plugin in `dir` (one folder per plugin, each with a plugin.cfg). A plugin that crashed or hung the
## game while it was being loaded last time (its id is still in the loading marker) is switched off.
static func load_plugins(dir: String) -> void:
	if _config == null:
		_load_config()
	var marker := data_root().path_join(LOADING_MARKER)
	if FileAccess.file_exists(marker):
		var bad := FileAccess.get_file_as_string(marker).strip_edges()
		if bad != "":
			push_warning("extensions: plugin '%s' did not finish loading last time; it has been switched off" % bad)
			_config.set_value("enabled", bad, false)
			_save_config()
		DirAccess.remove_absolute(marker)
	var da := DirAccess.open(dir)
	if da == null:
		return
	var found: Array = []
	var configs: Dictionary = {}
	var available: Dictionary = {}
	for ext in all:
		available[ext.id] = {"version": ext.version if ext.version != "" else "1",
			"enabled": ext.enabled or (vanilla_mode and bool(_config.get_value("enabled", ext.id, ext.default_enabled)))}
	var folders := da.get_directories()
	folders.sort()
	for sub in folders:
		var folder := dir.path_join(sub)
		var cfg := ConfigFile.new()
		if cfg.load(folder.path_join("plugin.cfg")) != OK:
			continue
		var normalized := PackageManifest.normalize(cfg, sub)
		var manifest: Dictionary = normalized.manifest
		var pid: String = manifest.id
		if by_id.has(pid) or _plugin_configs.has(pid):
			push_warning("extensions: plugin id '%s' (%s) is already used, skipped" % [pid, folder])
			continue
		if configs.has(pid):
			# Keep both manifests in the resolver input so a duplicate cannot win by discovery order.
			found.append(manifest)
			continue
		plugins[pid] = {"folder": folder, "name": str(cfg.get_value("plugin", "name", pid)),
			"author": str(cfg.get_value("plugin", "author", "")),
			"version": manifest.version, "error": "", "state": "discovered", "diagnostics": []}
		if not normalized.errors.is_empty():
			_state(pid, "failed", ", ".join(normalized.errors))
			continue
		plugin_manifests[pid] = manifest
		manifest["enabled"] = bool(_config.get_value("enabled", pid, manifest.enabled_by_default))
		configs[pid] = cfg
		found.append(manifest)
		_state(pid, "validated")
	var resolution := PackageResolver.resolve(found, available, RuntimeCapabilities.report().capabilities, OS.get_name())
	for pid in configs:
		_plugin_configs[pid] = configs[pid]
	for pid in resolution.errors:
		var messages: Array[String] = []
		for issue in resolution.errors[pid]:
			messages.append("%s: %s" % [issue.code.replace("_", " "), issue.detail])
		_state(pid, "blocked", "; ".join(messages))
		# Structural failures cannot be bypassed by toggling a package on later.
		if resolution.errors[pid].any(func(issue): return issue.code == "duplicate_id"):
			plugin_manifests.erase(pid)
	for pid in resolution.order:
		_state(pid, "resolved")
		var ready := true
		for dep in plugin_manifests[pid].depends:
			if not by_id.has(dep) or (not vanilla_mode and not by_id[dep].enabled):
				_state(pid, "blocked", "dependency not active: %s" % dep)
				ready = false
				break
		if ready:
			_load_plugin(pid, plugins[pid].folder, configs[pid], marker)


static func _load_plugin(pid: String, folder: String, cfg: ConfigFile, marker: String) -> void:
	_state(pid, "loading")
	DirAccess.make_dir_recursive_absolute(data_root())
	var mf := FileAccess.open(marker, FileAccess.WRITE)
	if mf != null:
		mf.store_string(pid)
		mf.close()
	var scr := compile_script(folder.path_join(str(cfg.get_value("plugin", "main", "plugin.gd"))))
	var ext = scr.new() if scr != null else null
	if not ext is SDTExtension:
		_state(pid, "failed", "main script missing, broken or not an SDTExtension")
		push_warning("extensions: plugin '%s': %s" % [pid, plugins[pid]["error"]])
	else:
		ext.id = pid
		ext.builtin = false
		ext.folder = folder
		if ext.title == "":
			ext.title = plugins[pid]["name"]
		ext.author = plugins[pid]["author"]
		ext.version = plugins[pid]["version"]
		ext.default_enabled = bool(cfg.get_value("plugin", "enabled_by_default", true))
		if add(ext) and not ext.enabled and plugins[pid].state == "loading":
			_state(pid, "disabled")
	DirAccess.remove_absolute(marker)


static func _state(pid: String, state: String, error: String = "") -> void:
	if not plugins.has(pid):
		return
	plugins[pid]["state"] = state
	plugins[pid]["error"] = error
	if not error.is_empty():
		plugins[pid].diagnostics.append({"state": state, "message": error})


## Public-safe status: never includes local folders or source code.
static func report(include_details: bool = false) -> Dictionary:
	var result := RuntimeCapabilities.report()
	result["packages"] = []
	var ids := plugins.keys()
	ids.sort()
	for pid in ids:
		var p: Dictionary = plugins[pid]
		var entry := {"id": pid, "version": p.version, "state": p.state, "diagnostic_count": p.diagnostics.size()}
		if include_details:
			entry["error"] = p.error
			entry["diagnostics"] = p.diagnostics.duplicate(true)
		result.packages.append(entry)
	return result


static func _requirements(pid: String, visited = null) -> Array:
	if visited == null:
		visited = {}
	var result: Array = []
	if visited.has(pid):
		return result
	visited[pid] = true
	for dep in plugin_manifests.get(pid, {}).get("depends", []):
		for transitive in _requirements(dep, visited):
			if not transitive in result:
				result.append(transitive)
		if not dep in result:
			result.append(dep)
	return result


static func _dependents(pid: String, visited = null) -> Array:
	if visited == null:
		visited = {}
	var result: Array = []
	if visited.has(pid):
		return result
	visited[pid] = true
	for ext in all:
		if pid in plugin_manifests.get(ext.id, {}).get("depends", []):
			result.append_array(_dependents(ext.id, visited))
			if not ext in result:
				result.append(ext)
	return result


## Compiles a GDScript file from anywhere on disk (plugins live outside the project). Plugin scripts may not use
## class_name, so they cannot take over the name of a game class.
static func compile_script(path: String) -> GDScript:
	if not FileAccess.file_exists(path):
		push_warning("extensions: %s not found" % path)
		return null
	var src := FileAccess.get_file_as_string(path)
	for line in src.split("\n"):
		if line.strip_edges().begins_with("class_name"):
			push_warning("extensions: %s uses class_name, which plugin scripts may not do" % path)
			return null
	var scr := GDScript.new()
	scr.source_code = src
	if scr.reload() != OK:
		push_warning("extensions: %s has errors" % path)
		return null
	return scr


# ---------------------------------------------------------------- keys and widgets

## Called from DT.keyPressed after the vanilla guards (not while typing or with controls locked).
static func key_pressed(keycode: int) -> void:
	for k in _keys.get(keycode, []).duplicate():
		if k[1].is_valid():
			k[1].call()


static func _add_key(ext: SDTExtension, keycode: int, fn: Callable, label: String) -> void:
	if keycode in VANILLA_KEYS:
		push_warning("extension %s: key %d (%s) is also a key of the game" % [ext.id, keycode, label])
	if not _keys.has(keycode):
		_keys[keycode] = []
	for other in _keys[keycode]:
		push_warning("extension %s: key %d (%s) is also used by %s (%s)" % [ext.id, keycode, label, other[0].id, other[2]])
	_keys[keycode].append([ext, fn, label])


static func _add_widget(ext: SDTExtension, w: FlashDisplayObject) -> void:
	_widgets.append([ext, w])


## Calls every listener of event `name` (see EVENTS) with `args`.
static func emit(name: String, args: Array = []) -> void:
	for e in _events.get(name, []).duplicate():
		var fn: Callable = e[1]
		if fn.is_valid():
			fn.callv(args)


static func _add_event(ext: SDTExtension, name: String, fn: Callable) -> void:
	if not EVENTS.has(name):
		push_error("extension %s: unknown event '%s'" % [ext.id, name])
		return
	if not _events.has(name):
		_events[name] = []
	_events[name].append([ext, fn])
	_events[name].sort_custom(func(a, b): return all.find(a[0]) < all.find(b[0]))


static func _add_tick(ext: SDTExtension, fn: Callable, late: bool) -> void:
	var list := _late_ticks if late else _ticks
	list.append([ext, fn])
	# keep extension load order, whatever order the callbacks were registered in
	list.sort_custom(func(a, b): return all.find(a[0]) < all.find(b[0]))


static func _install_tick() -> void:
	if _installed:
		return
	_installed = true
	Flash.tick_before.append(func(): _run_ticks(_ticks, "tick"))
	Flash.tick_after.append(func(): _run_ticks(_late_ticks, "late_tick"))


static func _run_ticks(list: Array, phase: String) -> void:
	if list.is_empty():
		return
	for t in list.duplicate():
		var fn: Callable = t[1]
		if not fn.is_valid():
			continue
		var ts := Time.get_ticks_usec()
		fn.call()
		Flash.account_listener("ext:%s.%s" % [t[0].id, phase], Time.get_ticks_usec() - ts)


static func _load_config() -> void:
	_config = ConfigFile.new()
	var path := FlashSharedObject.save_dir.path_join(CONFIG_FILE)
	if FileAccess.file_exists(path) and _config.load(path) != OK:
		push_warning("extensions: cannot read %s, using defaults" % path)
		_config = ConfigFile.new()


static func _save_config() -> void:
	var err := _config.save(FlashSharedObject.save_dir.path_join(CONFIG_FILE))
	if err != OK:
		push_warning("extensions: cannot save %s (error %d)" % [CONFIG_FILE, err])


static func _save_setting(ext: SDTExtension, key: String, value) -> void:
	if _config == null:
		_load_config()
	_config.set_value(ext.id, key, value)
	_save_config()
