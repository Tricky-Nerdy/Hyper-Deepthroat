class_name Moods
extends RefCounted
## Port extension (not in the original game): one shared view of her mood for extensions.
##
## The vanilla game has four moods (Her.currentMood). An extension can add more (moremoods adds 22): it takes over
## Her.setMood with a before-hook, shows the mood itself, sets a vanilla mood underneath (moremoods sets "Normal"
## for most of its moods, as the Loader mod did) and then calls Moods.set_extended(name). Everything else reads
## Moods.current(), which is the extended name while one is active, else the vanilla mood, and listens to the
## "mood_changed" event.

const VANILLA := [Her.NORMAL_MOOD, Her.HAPPY_MOOD, Her.ANGRY_MOOD, Her.AHEGAO_MOOD]

static var _extended := ""
static var _registered: Dictionary = {}   # extended mood name -> owner


## Her mood: the extended mood while one is active, else the vanilla mood.
static func current() -> String:
	if _extended != "":
		return _extended
	return g.her.currentMood if g.her != null else Her.NORMAL_MOOD


static func is_extended() -> bool:
	return _extended != ""


## Declares an extended mood (for mood lists and pickers).
static func register(name: String, owner: String) -> void:
	_registered[name] = owner


static func unregister_owner(owner: String) -> void:
	for name in _registered.keys():
		if _registered[name] == owner:
			_registered.erase(name)
	if _extended != "" and not _registered.has(_extended):
		_extended = ""


## Every mood: the vanilla ones, then the registered extended ones.
static func all() -> Array:
	return VANILLA + _registered.keys()


## The moods a player can pick (the new menu's mood list): all(), or what the mood extension offers (moremoods hides
## the moods its settings switch off). Set by that extension while it is on.
static var selectable_provider := Callable()


static func selectable() -> Array:
	return selectable_provider.call() if selectable_provider.is_valid() else all()


## Called by the extension that shows an extended mood, after it has set the vanilla mood underneath.
static func set_extended(name: String) -> void:
	_extended = name if not name in VANILLA else ""
	Extensions.emit("mood_changed", [current()])


## Called at the end of Her.setMood (the vanilla mood was set). While a Her.setMood hook is running (an extension
## setting the vanilla mood under an extended one), the extension reports the mood itself with set_extended().
static func vanilla_mood_set(_m: String) -> void:
	if Hooks._running.has(&"Her.setMood"):
		return
	_extended = ""
	Extensions.emit("mood_changed", [current()])
