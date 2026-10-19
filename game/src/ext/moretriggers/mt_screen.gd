extends RefCounted
## MoreTriggers' screen parts: progress bars bound to dialogue variables, a full-window overlay picture, a splash
## screen and the credits roll (mt_credits.gd). Pictures and credits-settings.txt are looked up like DialogueActions'
## files (the character's folder, then Mods/Dialogue, ...). Positions are in game window pixels (700 x 600).
##
##   [SET_PROGRESSBAR_<x>_<y>_<min>_<max>_<start>_<RRGGBB>_<variable>]  a 100 x 10 bar following <variable>; a
##       picture <variable>Bar.png is drawn over it at (x - 17, y - 3)
##   [HIDE_ / SHOW_ / KILL_PROGRESSBAR_<variable or ALL>]
##   [SET_OVERLAY_<file>_<BLENDMODE>_<0-100>], [HIDE_OVERLAY], [SHOW_OVERLAY], [KILL_OVERLAY]: a picture over the
##       scene (under the menus and the dialogue), fixed to the window
##   [SHOW_SPLASHSCREEN_<file>_<ms>]: a picture over everything; then the line "splashscreen_unloaded"
##   [SHOW_CREDITS]: rolls the credits set up in credits-settings.txt; then the line "credits_ended"

const CreditsScript := preload("res://src/ext/moretriggers/mt_credits.gd")

const BAR_W := 100
const BAR_H := 10

var mt
var layer: FlashSprite = null        # over the whole game: bars, splash screen, credits
var overlay_box: FlashSprite = null  # in the screen effects layer, under the menus and the dialogue
var _overlay: FlashDisplayObject = null
var _bars: Dictionary = {}           # variable -> [Bar, FlashLoader (wrapper picture)]
var _splash: FlashLoader = null
var _splash_until := -1.0
var credits = null                   # mt_credits.gd while rolling


func _init(p_mt) -> void:
	mt = p_mt


func register(da) -> void:
	var t := func(name: String, n: int, fn: Callable): da.register_trigger(name, n, fn)
	t.call("SET_PROGRESSBAR", 7, func(a): set_bar(a))
	t.call("KILL_PROGRESSBAR", 1, func(a): _each_bar(a[0], func(v): kill_bar(v)))
	t.call("HIDE_PROGRESSBAR", 1, func(a): _each_bar(a[0], func(v): _bar_visible(v, false)))
	t.call("SHOW_PROGRESSBAR", 1, func(a): _each_bar(a[0], func(v): _bar_visible(v, true)))
	t.call("SET_OVERLAY", 3, func(a): set_overlay(a[0], a[1], a[2]))
	t.call("HIDE_OVERLAY", 0, func(_a): _overlay_visible(false))
	t.call("SHOW_OVERLAY", 0, func(_a): _overlay_visible(true))
	t.call("KILL_OVERLAY", 0, func(_a): kill_overlay())
	t.call("SHOW_SPLASHSCREEN", 2, func(a): splash(a[0], AS3.Number(a[1])))
	t.call("SHOW_CREDITS", 0, func(_a): show_credits())


func remove() -> void:
	for v in _bars.keys():
		kill_bar(v)
	kill_overlay()
	if credits != null:
		credits.clear()
		credits = null
	for o in [layer, overlay_box]:
		if o != null and is_instance_valid(o) and o._flash_parent != null:
			o._flash_parent.removeChild(o)
	layer = null
	overlay_box = null
	_splash = null


func _layer() -> FlashSprite:
	if layer == null or not is_instance_valid(layer):
		layer = FlashSprite.new()
		layer.mouseEnabled = false
		layer.mouseChildren = false
	g.container.addChild(layer)   # (again) on top
	return layer


func path(file: String) -> String:
	return mt.da.world.resolve(file) if mt.da != null else file


func _picture(file: String, on_loaded := Callable()) -> FlashLoader:
	var l := FlashLoader.new()
	l.mouseEnabled = false
	var p := path(file)
	if FileAccess.file_exists(p):
		if on_loaded.is_valid():
			l.contentLoaderInfo.addEventListener(FlashEvent.COMPLETE, func(_e): on_loaded.call(l))
		l.load(p)
	return l


## A dialogue line type MoreTriggers adds ("splashscreen_unloaded", "credits_ended"): built when it happens, if
## the dialogue has such lines.
func build_line(line: String) -> void:
	var dc = g.dialogueControl
	if dc.library.getPhrases(line).size() == 0:
		return
	if not dc.states.has(line):
		dc.states[line] = DialogueState.new(200, 5)
	dc.buildState(line, 130)


# ---------------------------------------------------------------- progress bars

class Bar:
	extends FlashSprite
	var lo := 0
	var hi := 100
	var value := 0
	var color := Color.WHITE

	func _init(p_lo: int, p_hi: int, p_color: Color) -> void:
		mouseEnabled = false
		if p_lo == p_hi:
			p_hi = p_lo + 1
		lo = mini(p_lo, p_hi)
		hi = maxi(p_lo, p_hi)
		value = lo
		color = p_color

	func set_value(v: int) -> void:
		value = clampi(v, lo, hi)
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(0, 0, float(value - lo) * BAR_W / float(hi - lo), BAR_H), color)


func set_bar(a: Array) -> void:
	var v: String = a[6]
	kill_bar(v)
	var bar := Bar.new(int(AS3.Number(a[2])), int(AS3.Number(a[3])), Color.hex((("0x" + str(a[5])).hex_to_int() << 8) | 0xFF))
	bar.x = AS3.Number(a[0])
	bar.y = AS3.Number(a[1])
	bar.set_value(int(AS3.Number(a[4])))
	var wrap := _picture(v + "Bar.png")
	wrap.x = bar.x - 17
	wrap.y = bar.y - 3
	_layer().addChild(bar)
	layer.addChild(wrap)
	_bars[v] = [bar, wrap]
	mt.da.run_addon(mt.id, func(d): d.vars.add_listener(v, _bar_follow.bind(bar)))


func _bar_follow(_old, new, bar: Bar) -> void:
	if is_instance_valid(bar):
		bar.set_value(int(AS3.Number(new)))


func _each_bar(which: String, fn: Callable) -> void:
	for v in (_bars.keys() if which == "ALL" else [which]):
		if _bars.has(v):
			fn.call(v)


func kill_bar(v: String) -> void:
	if not _bars.has(v):
		return
	for o in _bars[v]:
		if is_instance_valid(o) and o._flash_parent != null:
			o._flash_parent.removeChild(o)
	_bars.erase(v)


func _bar_visible(v: String, on: bool) -> void:
	for o in _bars[v]:
		o.visible = on


# ---------------------------------------------------------------- overlay and splash screen

func set_overlay(file: String, mode: String, percent) -> void:
	if overlay_box == null or not is_instance_valid(overlay_box):
		overlay_box = FlashSprite.new()
		overlay_box.mouseEnabled = false
		overlay_box.mouseChildren = false
		g.screenEffects.addChild(overlay_box)
	var m := mode.to_lower()
	overlay_box.blendMode = m if m in mt.BLEND_MODES else "normal"
	overlay_box.alpha = AS3.Number(percent) / 100.0
	_picture(file, _overlay_loaded)


func _overlay_loaded(l: FlashLoader) -> void:
	kill_overlay()
	_overlay = l
	overlay_box.addChild(l)


func _overlay_visible(on: bool) -> void:
	if overlay_box != null:
		overlay_box.visible = on


func kill_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay) and _overlay._flash_parent != null:
		_overlay._flash_parent.removeChild(_overlay)
	_overlay = null


func splash(file: String, ms: float) -> void:
	if _splash != null and _splash._flash_parent != null:
		_splash._flash_parent.removeChild(_splash)
	_splash = _picture(file)
	_layer().addChild(_splash)
	_splash_until = Flash.getTimer() + ms


func show_credits() -> void:
	if credits != null:
		credits.clear()
	credits = CreditsScript.new(self, _settings("credits-settings.txt"))
	_layer().addChild(credits.root)


## A Loader settings file: "key=value" lines; ";" starts a comment line, "//" a comment after the value.
func _settings(file: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path(file), FileAccess.READ)
	if f == null:
		return out
	for line in f.get_as_text().split("\n"):
		var l := line.strip_edges()
		if l == "" or l.begins_with(";") or not "=" in l:
			continue
		var k := l.get_slice("=", 0).strip_edges()
		var v := l.substr(l.find("=") + 1)
		var c := v.find("//")
		if c != -1:
			v = v.substr(0, c)
		out[k] = v.strip_edges()
	return out


func tick() -> void:
	if _splash_until >= 0 and Flash.getTimer() > _splash_until:
		_splash_until = -1
		if _splash != null and _splash._flash_parent != null:
			_splash._flash_parent.removeChild(_splash)
		_splash = null
		build_line("splashscreen_unloaded")
	if credits != null and credits.roll():
		credits.clear()
		credits = null
		build_line("credits_ended")
