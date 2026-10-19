extends RefCounted
## DialogueActions variables (port's own implementation of its documented behaviour).
##
## - local: the dialogue's own variables (vanilla's AdvancedDialogueController._dialogueDataStore).
## - mod variables: names with a read handler and/or a write handler (e.g. da.pleasurePercentage); they are not
##   stored locally, the handlers read and write the game.
## - global: kept between dialogues while the game runs; a global can be linked to the local variable of the
##   same name, then writes to the local one are copied to it.
## - save: variables written to a save file (SAVESETVARS / SAVEGETVARS), see da_vars_triggers.gd.

const MathScript := preload("res://src/ext/dialogueactions/da_math.gd")

var _read: Dictionary = {}      # name -> Callable() -> value
var _write: Dictionary = {}     # name -> Callable(value)
var _listeners: Dictionary = {} # name -> [Callable(old, new)]
var globals: Dictionary = {}    # name -> {"value", "linked"}
var _checked: Array = []        # mod variables copied into the local store for a line's check
var owner := ""                 # extension registering right now (DialogueActions.run_addon)
var _owned: Dictionary = {}     # extension id -> [["read" | "write", name] | ["listener", name, Callable]]


func store() -> Dictionary:
	return g.dialogueControl.advancedController._dialogueDataStore


func dlog(msg: String) -> void:
	g.dialogueControl.advancedController.outputLog("DialogueActions: " + msg)


# ---------------------------------------------------------------- mod variables

func register_read(name: String, getter: Callable) -> void:
	if not _read.has(name):
		_read[name] = getter
		_own(["read", name])


func register_write(name: String, setter: Callable) -> void:
	if not _write.has(name):
		_write[name] = setter
		_own(["write", name])


func _own(entry: Array) -> void:
	if owner != "":
		if not _owned.has(owner):
			_owned[owner] = []
		_owned[owner].append(entry)


## Removes the mod variables and listeners extension `ext_id` registered.
func remove_owner(ext_id: String) -> void:
	for e in _owned.get(ext_id, []):
		match e[0]:
			"read":
				_read.erase(e[1])
			"write":
				_write.erase(e[1])
			"listener":
				if _listeners.has(e[1]):
					_listeners[e[1]].erase(e[2])
	_owned.erase(ext_id)


func register(name: String, getter: Callable, setter: Callable) -> void:
	if getter.is_valid():
		register_read(name, getter)
	if setter.is_valid():
		register_write(name, setter)


## Calls `fn(old, new)` after the local variable `name` was written.
func add_listener(name: String, fn: Callable) -> void:
	if not _listeners.has(name):
		_listeners[name] = []
	_listeners[name].append(fn)
	_own(["listener", name, fn])


## A mod variable's value, or null if `name` has no read handler.
func mod_value(name: String):
	var f = _read.get(name)
	return f.call() if f != null else null


# ---------------------------------------------------------------- reading and writing like a dialogue does

## The value a dialogue sees for *name* ("" if there is none), through the normal insert path.
func value_text(name: String) -> String:
	var idx := MathScript.operator_index(name)
	if idx == -2:
		return name
	if idx != -1:
		dlog("variable name contains an operator: " + name)
		return ""
	return g.dialogueControl.advancedController.replaceValues("*" + name + "*")


## Writes like a line's "set" attribute does (signed numeric strings add, see write()).
func set_value(name: String, value) -> void:
	g.dialogueControl.advancedController.setValues({name: value})


## Hook for AdvancedDialogueController.customValueReplacer: a mod variable's value, or the result of *a + b*;
## null to leave the insert to the game (local variables).
func insert(name: String):
	var v = mod_value(name)
	if v != null:
		return v
	if MathScript.operator_index(name) != -1:
		return evaluate(name)
	return null


## *a + b*: every word that is a variable is replaced by its value, then the expression is computed.
func evaluate(expr: String) -> float:
	var parts := expr.split(" ")
	for i in parts.size():
		var v := value_text(parts[i])
		if v != "":
			parts[i] = v
	return MathScript.evaluate(" ".join(parts))


## Hook for AdvancedDialogueController.setValues: the game's rules (a numeric string starting with + or - adds to
## the value) plus mod variables, linked globals and write listeners.
func write(values) -> void:
	if not values is Dictionary:
		return
	var st := store()
	for name in values:
		var value = values[name]
		var setter = _write.get(name)
		if setter != null:
			setter.call(value)
			continue
		var old = st.get(name)
		if value is String and not AS3.isNaN(value) and value != " ":
			if not st.has(name):
				st[name] = 0.0
			if value.begins_with("-") or value.begins_with("+"):
				st[name] = AS3.Number(st[name]) + AS3.Number(value)
		else:
			st[name] = value
		if globals.has(name) and globals[name]["linked"]:
			globals[name]["value"] = st[name]
		for fn in _listeners.get(name, []):
			fn.call(old, st[name])


## Hooks around AdvancedDialogueController.canPlay: a line may check mod variables; their values are put into the
## local store for the check and removed again afterwards.
func before_check(line) -> void:
	_checked.clear()
	var checks = line.settings.get("check") if line.settings else null
	if not checks is Dictionary:
		return
	var st := store()
	for name in checks:
		if not st.has(name):
			var v = mod_value(str(name))
			if v != null:
				st[name] = v
				_checked.append(name)


func after_check() -> void:
	var st := store()
	for name in _checked:
		st.erase(name)
	_checked.clear()


# ---------------------------------------------------------------- object variables ("prefix." names)

## Local and mod variable names starting with `prefix` (and longer than it).
func local_names(prefix: String) -> Array:
	var out: Array = []
	for n in store().keys() + _read.keys():
		if str(n).begins_with(prefix) and str(n).length() > prefix.length() and not str(n) in out:
			out.append(str(n))
	return out


func global_names(prefix: String) -> Array:
	return globals.keys().filter(func(n): return n.begins_with(prefix) and n.length() > prefix.length())


## Names an argument stands for: "x." (an object) means every variable under it, else just the name.
func expand_local(name: String) -> Array:
	return local_names(name) if name.ends_with(".") else [name]


func expand_global(name: String) -> Array:
	return global_names(name) if name.ends_with(".") else [name]


# ---------------------------------------------------------------- globals

func set_global(name: String, value) -> void:
	if not globals.has(name):
		globals[name] = {"value": value, "linked": false}
	globals[name]["value"] = value
	if globals[name]["linked"]:
		set_value(name, value)


func copy_to_global(name: String) -> void:
	set_global(name, _typed(value_text(name)))


func copy_from_global(name: String) -> void:
	if not globals.has(name):
		return
	var v = globals[name]["value"]
	var setter = _write.get(name)
	if setter != null:
		setter.call(v)
	else:
		store()[name] = v


func link(name: String, on: bool) -> void:
	if globals.has(name):
		globals[name]["linked"] = on


func unlink_all() -> void:
	for n in globals:
		globals[n]["linked"] = false


## A value read as text, back to a number when it is one (as DialogueActions copies values).
static func _typed(s: String):
	var n := AS3.Number(s)
	return s if is_nan(n) else n
