extends SDTExtension
## Built-in reimplementation of the Loader mod MoreTriggers (DrZombi, v2.22a): more DialogueActions triggers and
## variables for dialogue files, e.g. [SHOCK_2500], [LOOK_UP_2000], [CLOSE_MOUTH], [GROW_BREASTS_BY_20],
## [SET_PROGRESSBAR_...], [SHOW_CREDITS]. Written from its documentation and behaviour; dialogues use the same syntax.
## Needs DialogueActions. The screen parts (progress bars, overlay, splash screen, credits) are in mt_screen.gd.
##
## Timed effects ([SHOCK_<ms>], [LOOK_...], [CLOSE_MOUTH_<ms>], [WINCE_<ms>]) are re-applied every tick until their
## time is up, after the game's own tick, as the mod did; a new trigger of the same kind replaces the running one.

const ScreenScript := preload("res://src/ext/moretriggers/mt_screen.gd")

const SHOCK_POWER := 85.0
const MOUTH_OPENING := 1.0
## Grow / shrink steps per tick: breasts 1 size, her body 0.001 scale, his penis and balls 1/765 of their slider,
## her penis 1% of its slider.
const PENIS_STEP := 1.0 / 765.0
const BODY_STEP := 0.001
const BREASTS_MAX := 149
const BODY_MIN := 0.95
const BODY_MAX := 1.075
const BLEND_MODES := ["normal", "layer", "multiply", "screen", "lighten", "darken", "difference", "add", "subtract",
	"invert", "alpha", "erase", "overlay", "hardlight"]

var da = null
var screen = null   # mt_screen.gd
# timed effects: time (getTimer ms) they stop at, -1 = off
var _shock_until := -1.0
var _shock_power := SHOCK_POWER
var _look_until := -1.0
var _look_at := Vector2()
var _mouth_until := -1.0
var _mouth_angle := 0.0
var _wince_until := -1.0
# grow / shrink: steps left (negative = shrink)
var _grow := {"breasts": 0, "body": 0, "his_penis": 0, "her_penis": 0, "his_balls": 0}
# what the triggers changed, put back when the extension is switched off
var _hidden := {}   # "her" / "hair" / "his_arm" -> true
var _alpha_set := {}  # "penis" / "him" / "her" -> true


func _init() -> void:
	id = "moretriggers"
	title = "MoreTriggers"
	description = "More dialogue triggers (shock, look, mouth, wince, grow / shrink, alpha, overlays, progress bars, credits) and the mt.cuminmouth / mt.vigour variables, for dialogues written for the Loader mod MoreTriggers. Needs DialogueActions."
	default_enabled = true


func _enable() -> void:
	screen = ScreenScript.new(self)
	on_dialogueactions(_register)
	on_late_tick(_tick)


func _disable() -> void:
	if screen != null:
		screen.remove()
	screen = null
	_shock_until = -1
	_look_until = -1
	_mouth_until = -1
	_wince_until = -1
	for k in _grow:
		_grow[k] = 0
	if _hidden.get("her", false):
		_show_her(true)
	if _hidden.get("hair", false):
		_show_hair(true)
	if _hidden.get("his_arm", false) and g.him != null:
		g.him.leftArmContainer.visible = true
	_hidden.clear()
	for k in _alpha_set:
		_set_alpha(k, "normal", 1.0)
	_alpha_set.clear()
	da = null


func _register(p_da) -> void:
	da = p_da
	var t := func(name: String, n: int, fn: Callable): da.register_trigger(name, n, fn)
	t.call("TONGUE_ADD", 0, func(_a): _tongue(true))
	t.call("TONGUE_REMOVE", 0, func(_a): _tongue(false))
	t.call("UPDATE_RESISTANCE", 1, func(a): _resistance(a[0]))
	t.call("HIDE_HIS_LEFT_ARM", 0, func(_a): _his_arm(false))
	t.call("SHOW_HIS_LEFT_ARM", 0, func(_a): _his_arm(true))
	t.call("TOGGLE_LOADER_ARM", 1, func(_a): _log("[TOGGLE_LOADER_ARM]: the Loader's extra arm is not in the port yet"))
	t.call("TOGGLE_NIPPLES", 1, func(a): _nipples(a[0]))
	t.call("CLEAR_HAIR", 0, func(_a): g.customElementLoader.clearCustomHair())
	t.call("SHOW_HER", 0, func(_a): _show_her(true))
	t.call("HIDE_HER", 0, func(_a): _show_her(false))
	t.call("SHOW_HAIR", 0, func(_a): _show_hair(true))
	t.call("HIDE_HAIR", 0, func(_a): _show_hair(false))
	t.call("PENIS_ALPHA", 2, func(a): _alpha("penis", a[0], a[1]))
	t.call("HIM_ALPHA", 2, func(a): _alpha("him", a[0], a[1]))
	t.call("HER_ALPHA", 2, func(a): _alpha("her", a[0], a[1]))
	t.call("LOOK", 2, func(a): _look(a[0], "", "", a[1]))
	t.call("LOOK", 3, func(a): _look("", a[0], a[1], a[2]))
	t.call("SHOCK", 1, func(a): _shock(a[0], SHOCK_POWER))
	t.call("SHOCK", 2, func(a): _shock(a[0], a[1]))
	t.call("CLOSE_MOUTH", 0, func(_a): _close_mouth(INF))
	t.call("CLOSE_MOUTH", 1, func(a): _close_mouth(_ms(a[0])))
	t.call("OPEN_MOUTH", 0, func(_a): _mouth_until = -1)
	t.call("OPEN_MOUTH", 1, func(a): _hold_mouth(MOUTH_OPENING, _ms(a[0])))
	t.call("OPEN_MOUTH", 2, func(a): _hold_mouth(AS3.Number(a[1]), _ms(a[0])))
	t.call("WINCE", 1, func(a): _wince_until = Flash.getTimer() + _ms(a[0]))
	t.call("BIND_VARIABLES", 2, func(a): _bind(a[0], a[1]))
	t.call("LOAD_FOLDER", 1, func(a): _log("[LOAD_FOLDER_%s]: Loader character folders are not in the port yet" % a[0]))
	for k in [["BREASTS", "breasts"], ["BODY", "body"], ["HIS_PENIS", "his_penis"], ["HER_PENIS", "her_penis"],
			["HIS_BALLS", "his_balls"]]:
		var key: String = k[1]
		t.call("GROW_%s_BY" % k[0], 1, func(a): _grow[key] += int(AS3.Number(a[0])))
		t.call("SHRINK_%s_BY" % k[0], 1, func(a): _grow[key] -= int(AS3.Number(a[0])))
	t.call("SHOW_HER_PENIS", 1, func(a): _her_penis(int(AS3.Number(a[0]))))
	t.call("HIDE_HER_PENIS", 0, func(_a): _her_penis(0))
	da.vars.register("mt.cuminmouth", _cum_in_mouth, func(v): _set_percent(v, _cum_in_mouth, "mt.cuminmouth",
		func(p): g.her.cumInMouth = roundi(g.her.maxCumInMouth * p / 100.0)))
	da.vars.register("mt.vigour", _vigour, func(v): _set_percent(v, _vigour, "mt.vigour",
		func(p): g.her.vigour = roundf(1050.0 * p / 100.0)))
	screen.register(da)


func _log(msg: String) -> void:
	if da != null:
		da.vars.dlog("MoreTriggers " + msg)


static func _ms(v) -> float:
	return AS3.Number(v)


# ---------------------------------------------------------------- simple triggers

func _tongue(on: bool) -> void:
	g.tongue = on
	g.her.tongueToggled()
	g.inGameMenu.updateCBTongue()


func _resistance(v) -> void:
	g.her.setIntroResistance(clampf(AS3.Number(v), 0.0, 100.0))
	g.inGameMenu.updateResistanceSlider(false)


func _his_arm(on: bool) -> void:
	if g.him.visible:
		g.him.leftArmContainer.visible = on
		_hidden["his_arm"] = not on


## [TOGGLE_NIPPLES_ON / _OFF]: shows or hides both nipples (they can show through clothes).
func _nipples(state: String) -> void:
	if state != "ON" and state != "OFF":
		return
	var her = g.her
	var nipples: Array = []
	for b in [her.torsoBack.get("leftBreast"), her.torso.midLayer.get("rightBreast")]:
		var n = b.get("nipple") if b != null else null
		if n != null:
			nipples.append(n)
	var shown := nipples.any(func(n): return n.visible)
	if shown != (state == "ON"):
		for n in nipples:
			n.visible = not n.visible


## Her parts drawn outside her own container (arms, the leg Animtools can move behind him, back mods).
func _her_parts() -> Array:
	var her = g.her
	return [her.leftArmContainer, her.rightArmContainer, her.rightForeArmContainer, her.backModContainer,
		her.leftLegContainer]


func _show_her(on: bool) -> void:
	g.her.visible = on
	for p in _her_parts():
		if p != null:
			p.visible = on
	_hidden["her"] = not on


func _show_hair(on: bool) -> void:
	var her = g.her
	for p in [her.hairTop, her.hairMidContainer, her.hairBackContainer, g.hairOverContainer]:
		if p != null:
			p.visible = on
	_hidden["hair"] = not on


## [PENIS_ALPHA / HIM_ALPHA / HER_ALPHA_<BLENDMODE>_<0-100>]. Port: she is drawn with her separate parts (arms,
## hair over her) given the same alpha and blend mode, instead of the mod's moving of layers into her container
## every frame; LAYER composites each part as one picture like Flash did.
func _alpha(who: String, mode: String, percent) -> void:
	var m := mode.to_lower()
	if not m in BLEND_MODES:
		_log("unknown blend mode " + mode)
		m = "normal"
	_set_alpha(who, m, AS3.Number(percent) / 100.0)
	_alpha_set[who] = true


func _set_alpha(who: String, mode: String, a: float) -> void:
	var objs: Array = []
	match who:
		"penis":
			objs = [g.him.penis]
		"him":
			objs = [g.him, g.him.armContainer, g.him.overLayer]
		"her":
			var her = g.her
			objs = [her]
			for p in _her_parts() + [g.hairOverContainer, her.hairBackContainer, g.hairBackLayer, g.hairCostumeBack]:
				if p != null and not her.contains(p):
					objs.append(p)
	for o in objs:
		if o != null:
			o.alpha = a
			o.blendMode = mode


func _her_penis(selection: int) -> void:
	var pc = g.her._penisControl
	pc.penisControl.selection = selection
	pc.setPenis(1 if selection != 0 else 0)


# ---------------------------------------------------------------- variables

func _cum_in_mouth() -> int:
	return roundi(g.her.cumInMouth / float(g.her.maxCumInMouth) * 100.0)


func _vigour() -> int:
	return mini(100, roundi(g.her.vigour / 1050.0 * 100.0))


## Writes a 0..100 variable: a number sets it, a string starting with + or - adds to it.
func _set_percent(v, current: Callable, name: String, apply: Callable) -> void:
	var p: float
	if v is float or v is int:
		p = v
	elif v is String and not AS3.isNaN(v) and v.strip_edges() != "":
		p = current.call() + AS3.Number(v) if v.begins_with("+") or v.begins_with("-") else AS3.Number(v)
	else:
		_log("%s set to %s: not a number" % [name, v])
		return
	apply.call(clampf(p, 0.0, 100.0))


## [BIND_VARIABLES_<a>_<b>]: every write of a also sets b (one way), starting with a's current value.
func _bind(a: String, b: String) -> void:
	da.run_addon(id, func(d): d.vars.add_listener(a, func(_old, new): d.vars.write({b: new})))
	var v = da.vars.mod_value(a)
	if v == null:
		v = da.vars.store().get(a)
	var n: float = AS3.Number(v) if v != null else NAN
	da.vars.write({b: v if is_nan(n) else n})


# ---------------------------------------------------------------- timed effects

func _shock(ms, power) -> void:
	_shock_until = Flash.getTimer() + _ms(ms)
	_shock_power = AS3.Number(power)


## [LOOK_UP / DOWN / STRAIGHTFORWARD_<ms>] or [LOOK_<x>_<y>_<ms>]: where she looks, until the time is up.
func _look(dir: String, x, y, ms) -> void:
	var her = g.her
	if dir == "":
		_look_at = Vector2(AS3.Number(x), AS3.Number(y))
	else:
		match dir:
			"UP":
				_look_at = her.hisFace
			"DOWN":
				_look_at = her.eyesDown
			"STRAIGHTFORWARD":
				_look_at = Vector2(900, 0)
			_:
				_look_at = Vector2(900, 350)
	_look_until = Flash.getTimer() + _ms(ms)


func _close_mouth(ms: float) -> void:
	g.her.tongue.stopHangingOut()
	_hold_mouth(Her.closedJawAngle * 0.95, ms)


func _hold_mouth(angle: float, ms: float) -> void:
	_mouth_angle = angle
	_mouth_until = Flash.getTimer() + ms if ms != INF else INF


func _tick() -> void:
	if g.her == null:
		return
	var now := float(Flash.getTimer())
	var her = g.her
	if _shock_until >= 0:
		if now > _shock_until:
			_shock_until = -1
		else:
			her.eyelidMotion["shock"] = _shock_power
	if _look_until >= 0:
		if now > _look_until:
			_look_until = -1
		else:
			her.currentLookTarget = _look_at
	if _mouth_until >= 0:
		if now > _mouth_until:
			_mouth_until = -1
		else:
			var head = her.head
			for jaw in [head.jaw, head.jawBack, head.headTan.jawBack, head.headTan.jaw]:
				jaw.rotation_degrees = _mouth_angle
			her.updateLips()
	if _wince_until >= 0:
		if now > _wince_until:
			_wince_until = -1
		else:
			her.wince()
	_tick_growth()
	if screen != null:
		screen.tick()


func _tick_growth() -> void:
	var gr := _grow
	if gr["breasts"] != 0:
		var cc = g.characterControl
		cc.setBreasts(clampi(cc.breastSize + signi(gr["breasts"]), 0, BREASTS_MAX))
		gr["breasts"] -= signi(gr["breasts"])
	if gr["body"] != 0:
		var her = g.her
		her.setBodyScale(clampf(her.bodyScale + BODY_STEP * signi(gr["body"]), BODY_MIN, BODY_MAX))
		gr["body"] -= signi(gr["body"])
	if gr["his_penis"] != 0:
		var him = g.him
		var v: float = (him.currentPenisLengthScale - Him.MIN_PENIS_SIZE) / (Him.MAX_PENIS_SIZE - Him.MIN_PENIS_SIZE)
		him.setPenisLength(v + PENIS_STEP * signi(gr["his_penis"]))
		g.inGameMenu.updatePenisLengthSlider()
		g.inGameMenu.updatePenisWidthSlider()
		gr["his_penis"] -= signi(gr["his_penis"])
	if gr["her_penis"] != 0:
		var pc = g.her._penisControl
		var sl = pc.penisMenu.penisLengthSlider if pc.penisMenu != null else null
		var v: float = sl.currentValue(100) / 100.0 if sl != null else 0.5
		pc.setPenisLength(clampf(v + 0.01 * signi(gr["her_penis"]), 0.0, 1.0))
		pc.updatePenisLengthSlider()
		pc.updatePenisWidthSlider()
		gr["her_penis"] -= signi(gr["her_penis"])
	if gr["his_balls"] != 0:
		var him = g.him
		var v: float = (him.currentBallSize - Him.MIN_BALL_SIZE) / (Him.MAX_BALL_SIZE - Him.MIN_BALL_SIZE)
		him.setBallSize(v + PENIS_STEP * signi(gr["his_balls"]))
		g.inGameMenu.updateBallSizeSlider()
		g.inGameMenu.updateBallsList()
		gr["his_balls"] -= signi(gr["his_balls"])
