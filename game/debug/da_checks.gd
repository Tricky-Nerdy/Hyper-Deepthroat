extends RefCounted
## Checks of the built-in DialogueActions (src/ext/dialogueactions): arithmetic, trigger matching, variables,
## inserts, set / check, globals, objects, saved variables, line types and instant lines; and MoreTriggers
## (src/ext/moretriggers) and extensions adding to DialogueActions (on_dialogueactions).
## Run by tools/regress.sh (main.gd --driver); prints "DA CHECKS: n passed, m failed" and quits.

const MathScript := preload("res://src/ext/dialogueactions/da_math.gd")

var _pass := 0
var _fail := 0
var _phase := 0
var _t0 := 0
var da = null
var mt = null
var _mt_breasts := 0
var _mt_body := 1.0


func _check(name: String, ok: bool, detail := "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("CHECK %s %s%s" % ["ok  " if ok else "FAIL", name, "" if ok or detail == "" else " (%s)" % detail])


func step(_frame: int) -> void:
	if not Extensions.started:
		return
	match _phase:
		0:
			da = Extensions.get_extension("dialogueactions")
			_check("DialogueActions on by default", da != null and da.enabled)
			if da == null or not da.enabled:
				_finish()
				return
			Flash.stage.getChildAt(0).playClicked()
			_math_checks()
			_trigger_checks()
			_variable_checks()
			_line_checks()
			_start_line_setup()
			_t0 = Flash.tick_count
			_phase = 1
		1:
			if Flash.tick_count > _t0 + 90:
				_check("start line plays after loading", g.dialogueControl.sayingPhrase == "Starting now",
					g.dialogueControl.sayingPhrase)
				_game_checks()
				_world_checks()
				_mood_checks()
				_mt_checks()
				_t0 = Flash.tick_count
				_phase = 2
		2:
			if Flash.tick_count > _t0 + 80:
				_game_checks_later()
				_mt_checks_later()
				_mood_cycle_i = 0
				_t0 = Flash.tick_count
				_phase = 3
		3:
			_mood_cycle_step()


func _finish() -> void:
	print("DA CHECKS: %d passed, %d failed" % [_pass, _fail])
	Flash.get_tree().quit(1 if _fail > 0 else 0)
	_phase = 99


func _math_checks() -> void:
	var cases := {"10 + 20": 30.0, "10 - 20": -10.0, "10 / 20": 0.5, "4 + 2 / 2": 3.0, "4 + ( 2 / 2 )": 5.0,
		"10 != 20": 1.0, "10 == 10": 1.0, "10 >= 20": 0.0, "10 <= 20": 1.0, "10 > 20": 0.0, "10 < 20": 1.0,
		"10 = 20": 20.0, "1 && 0": 0.0, "1 || 0": 1.0, "10 % 4": 2.0, "10 \\ 3": 3.0, "-5 + 2": -3.0,
		"( 1 + 2 ) * ( 3 + 4 )": 21.0, "2 * 3 + 1": 7.0}
	var bad: Array = []
	for e in cases:
		var r := MathScript.evaluate(e)
		if not is_equal_approx(r, cases[e]):
			bad.append("%s = %s" % [e, r])
	_check("arithmetic (left to right, parentheses)", bad.is_empty(), str(bad))
	_check("text result is NaN", is_nan(MathScript.evaluate("abc + 1")))
	_check("operator detection", MathScript.operator_index("a + b") == 2 and MathScript.operator_index("plain") == -1
		and MathScript.operator_index("+") == -2)


func _trigger_checks() -> void:
	var got: Array = []
	da.register_trigger("TEST_JOINED", 0, func(_a): got.append("joined"))
	da.register_trigger("TESTARGS", 2, func(a): got.append(a))
	da.register_trigger("TESTANY", -1, func(a): got.append(["any", a.size()]))
	_check("name with '_' found by joining", da.run_code("[TEST_JOINED]") and got.back() == "joined")
	_check("arguments split at '_'", da.run_code("[TESTARGS_a_b]") and got.back() == ["a", "b"], str(got.back()))
	_check("any-argument trigger", da.run_code("[TESTANY_1_2_3]") and got.back() == ["any", 3], str(got.back()))
	_check("wrong argument count not recognised", not da.run_code("[TESTARGS_a]"))
	_check("several triggers from code", da.run_code("[TEST_JOINED][TESTARGS_x_y]") and got.back() == ["x", "y"])
	# in a spoken line: the trigger runs, the line goes on without a pause; unknown words go to the game
	var dc = g.dialogueControl
	var st: Dictionary = dc.advancedController._dialogueDataStore
	dc.startSpeakingPhrase(DialogueLine.new("hello [SETVAR_inline_9] there [someline] end", {"style": "Thought"}))
	var spoken := ""
	for i in 300:
		if dc.speaking:
			spoken += dc.nextChar()
		elif dc.waitingToContinue:
			dc.continueSpeaking()
	_check("trigger in a line runs", st.get("inline") == 9.0, str(st.get("inline")))
	_check("unknown word left to the game (queued line)", dc.queuedPhrase == "someline", dc.queuedPhrase)
	_check("line spoken to the end, triggers not shown", spoken.ends_with("end") and not "[" in spoken, spoken)


func _variable_checks() -> void:
	var dc = g.dialogueControl
	var adc = dc.advancedController
	var st: Dictionary = adc._dialogueDataStore
	da.run_code("[SETVAR_x_5]")
	_check("SETVAR number", st.get("x") == 5.0)
	da.run_code("[SETVAR_x_+=2]")
	_check("SETVAR +=", st.get("x") == 7.0, str(st.get("x")))
	da.run_code("[SETVAR_x_-=10]")
	_check("SETVAR -=", st.get("x") == -3.0, str(st.get("x")))
	da.run_code("[SETVAR_name_Anna]")
	da.run_code("[APPENDVAR_name_bel]")
	_check("SETVAR text, APPENDVAR", st.get("name") == "Annabel", str(st.get("name")))
	da.run_code("[SETVARBYNAME_copy_x]")
	_check("SETVARBYNAME", st.get("copy") == -3.0, str(st.get("copy")))
	_check("insert local", adc.replaceValues("x is *x*") == "x is -3")
	_check("insert arithmetic", adc.replaceValues("*x + 10*") == "7", adc.replaceValues("*x + 10*"))
	_check("insert unknown is empty", adc.replaceValues("[*nothing*]") == "[]")
	var r := AS3.Number(adc.replaceValues("*da.random*"))
	_check("mod variable da.random", r >= 0.0 and r < 1.0)
	adc.setValues({"y": "+3"})
	adc.setValues({"y": "+3"})
	_check("set attribute adds signed numbers", st.get("y") == 6.0, str(st.get("y")))
	var seen: Array = []
	da.vars.register("test.modvar", func(): return 5, func(v): seen.append(v))
	adc.setValues({"test.modvar": 42})
	_check("mod variable write handler", seen == [42] and not st.has("test.modvar"))
	var line := DialogueLine.new("check line", {"check": {"test.modvar": 5}, "style": "Thought"})
	_check("check reads mod variables", adc.canPlay(line) and not st.has("test.modvar"))
	var line2 := DialogueLine.new("check line", {"check": {"test.modvar": 6}, "style": "Thought"})
	_check("check with wrong value fails", not adc.canPlay(line2))
	var listened: Array = []
	da.vars.add_listener("watched", func(o, n): listened.append([o, n]))
	da.run_code("[SETVAR_watched_1]")
	_check("write listener", listened == [[null, 1.0]], str(listened))
	# globals
	da.run_code("[SETGLOBAL_g1_hello]")
	da.run_code("[LOADGLOBALS_g1]")
	_check("SETGLOBAL + LOADGLOBALS", st.get("g1") == "hello")
	da.run_code("[SETVAR_g1_bye]")
	_check("linked global follows the local", da.vars.globals["g1"]["value"] == "bye")
	da.run_code("[UNREGISTERGLOBALS_g1]")
	da.run_code("[SETVAR_g1_later]")
	_check("unlinked global keeps its value", da.vars.globals["g1"]["value"] == "bye")
	da.run_code("[SETVAR_reg_3]")
	da.run_code("[REGISTERGLOBALS_reg]")
	_check("REGISTERGLOBALS", da.vars.globals["reg"]["value"] == 3.0 and da.vars.globals["reg"]["linked"])
	# objects
	da.run_code("[DEFINEOBJECT_Info._top_shoes]")
	_check("DEFINEOBJECT", st.get("Info.top") == 0 and st.get("Info.shoes") == 0)
	da.run_code("[SETVAR_src.top_red]")
	da.run_code("[SETVAR_src.shoes_blue]")
	da.run_code("[SETVAR_src.hat_green]")
	da.run_code("[COPYOBJECT_0_dst._src.]")
	_check("COPYOBJECT", st.get("dst.top") == "red" and st.get("dst.hat") == "green")
	da.run_code("[COPYOBJECT_0_part._src._USING_Info.]")
	_check("COPYOBJECT USING", st.get("part.top") == "red" and st.get("part.shoes") == "blue" and not st.has("part.hat"))
	da.run_code("[SPLITSTRING_abc_s]")
	_check("SPLITSTRING", st.get("s.length") == 3 and st.get("s.charAt.1") == "b")
	# saved variables
	da.run_code("[SAVESETVARS_testsave_x_src.]")
	da.run_code("[SETVAR_x_100]")
	da.run_code("[SAVEGETVARS_testsave_x]")
	_check("SAVESETVARS / SAVEGETVARS", st.get("x") == -3.0, str(st.get("x")))
	_check("save file next to the save files", FileAccess.file_exists(da.data_dir().path_join("saves/testsave.json")))
	da.run_code("[SAVEDELETE_testsave]")
	_check("SAVEDELETE", not FileAccess.file_exists(da.data_dir().path_join("saves/testsave.json")))
	_check("old VA_ form", da.run_code("[VA_SET_VARIABLE_va_4]") and st.get("va") == 4.0)


func _line_checks() -> void:
	var dc = g.dialogueControl
	var st: Dictionary = dc.advancedController._dialogueDataStore
	dc.loadCustomDialogue('dialogue_name:"da test"\n' +
		'intro:"[mytype]"{"style":"Thought"}\n' +
		'mytype:"instant played"{"style":"Thought"}\n' +
		'go_INSTANT:"[SETVAR_k_1] [SETVAR_k2_2] [after]"{"style":"Thought"}\n' +
		'after:"done line"{"style":"Thought"}\n' +
		'choking:"cough"{"style":"Thought"}\n', false)
	_check("line types get states", dc.states.has("choking") and not dc.states.has("orgasm"))
	dc.startSpeakingPhrase(dc.library.getPhrases("intro")[0])
	_check("single-trigger line plays that line type at once", dc.sayingPhrase == "instant played", dc.sayingPhrase)
	dc.stopSpeaking()
	dc.sayRandomPhrase("go_INSTANT")
	_check("_INSTANT line runs its triggers at once", st.get("k") == 1.0 and st.get("k2") == 2.0)
	_check("_INSTANT line goes on to the queued line", dc.sayingPhrase == "done line", dc.sayingPhrase)
	dc.stopSpeaking()


var _drops_before := 0


func _game_checks() -> void:
	var her = g.her
	var gt = da.game
	var ch_before: int = Flash._active_channels.size()
	_check("MOAN plays a sound", da.run_code("[MOAN]") and Flash._active_channels.size() > ch_before)
	var ch_voice: int = Flash._active_channels.size()
	_check("OH_SOFT plays DialogueActions' shipped voice clip", da.run_code("[OH_SOFT]") and Flash._active_channels.size() > ch_voice)
	da.run_code("[SETVOICE_2]")
	var ch_voice2: int = Flash._active_channels.size()
	_check("voice 2 clips", da.run_code("[AH_HARD]") and Flash._active_channels.size() > ch_voice2)
	da.run_code("[SETVOICE_1]")
	da.run_code("[GAG]")
	_check("GAG plays and starts the gag swallow", gt._gagging and her.head.neck.swallowProgress > 0.8)
	da.run_code("[TONGUE_OUT]")
	var out: bool = her.tongue.hangingOut
	da.run_code("[TONGUE_IN]")
	_check("TONGUE_OUT / TONGUE_IN", out and not her.tongue.hangingOut)
	her.maxIntroDist = 10
	da.run_code("[DEEPTHROAT]")
	_check("DEEPTHROAT", her.maxIntroDist == 150)
	her.firstDT = false
	da.run_code("[RESET_RESIST]")
	_check("RESET_RESIST", her.firstDT and her.intro)
	da.run_code("[AUTO_HARD]")
	var auto_on: bool = g.autoModeOn
	da.run_code("[AUTO_OFF]")
	_check("AUTO_HARD / AUTO_OFF", auto_on and not g.autoModeOn)
	da.run_code("[CUM_BLOCK_ON]")
	var adc = g.dialogueControl.advancedController
	_check("CUM_BLOCK_ON and da.blockingOrgasm", gt.blocking and adc.replaceValues("*da.blockingOrgasm*") == "1")
	adc.setValues({"da.blockingOrgasm": 0})
	_check("da.blockingOrgasm writable", not gt.blocking)
	adc.setValues({"da.breathPercentage": 50})
	_check("da.breathPercentage", is_equal_approx(g.currentBreathLevel, g.breathLevelMax / 2.0), str(g.currentBreathLevel))
	g.him.pleasure = 0
	adc.setValues({"da.pleasurePercentage": "+10"})
	_check("da.pleasurePercentage +10", is_equal_approx(gt._his_pleasure(), 10.0), str(gt._his_pleasure()))
	da.run_code("[HIDE_HIM]")
	var hidden: bool = not g.him.visible
	da.run_code("[SHOW_HIM]")
	_check("HIDE_HIM / SHOW_HIM", hidden and g.him.visible)
	_check("arm and cleaning triggers run", da.run_code("[ARMS_BREAST][FIX_ARMS][ARMS_HIS_CROTCH][RUB_HIS_CROTCH_ON][RUB_HIS_CROTCH_OFF][CLEAN_ALL][BOUNCE_TITS_0.3]"))
	_drops_before = g.strandBackLayer.numChildren
	da.run_code("[PUSSYDRIP_10]")
	_check("PUSSYDRIP starts", gt._dripping)
	da.run_code("[INSTANT_FLASH_ffffff_1]")
	_check("INSTANT_FLASH covers the screen", gt.fader != null and gt.fader.alpha == 1.0)
	da.run_code("[MASTURBATE_ON]")
	_check("MASTURBATE_ON", gt.masturbating)


func _world_checks() -> void:
	var adc = g.dialogueControl.advancedController
	var cc = g.characterControl
	var bra = cc.braControl
	var names: Array = bra.elementNameList
	adc.setValues({"da.clothes.top.type": names[1]})
	_check("da.clothes.top.type", bra.selectedName == names[1] and adc.replaceValues("*da.clothes.top.type*") == names[1],
		adc.replaceValues("*da.clothes.top.type*"))
	adc.setValues({"da.clothes.top.r": 100})
	adc.setValues({"da.clothes.top.r": "+20"})
	_check("da.clothes.top.r (relative)", bra.rgb1["r"] == 120.0, str(bra.rgb1["r"]))
	adc.setValues({"da.clothes.top.a": 5})
	_check("clothes alpha clamped", bra.rgb1["a"] == 1.0)
	adc.setValues({"da.her.body.breasts": 100})
	adc.setValues({"da.her.body.breasts": "+5"})
	_check("da.her.body.breasts", cc.breastSize == 105, str(cc.breastSize))
	adc.setValues({"da.her.body.lipstick.r": 200})
	_check("da.her.body.lipstick.r", AS3.Number(adc.replaceValues("*da.her.body.lipstick.r*")) == 200.0,
		adc.replaceValues("*da.her.body.lipstick.r*"))
	var tears: bool = g.tears
	adc.setValues({"da.sdtoptions.tears": 0 if tears else 1})
	_check("da.sdtoptions.tears toggles the option", g.tears != tears)
	adc.setValues({"da.sdtoptions.tears": 1 if tears else 0})
	# LOAD_CHARCODE keeps what the code does not list; LOAD_FULL_CHARCODE resets it
	adc.setValues({"da.clothes.top.type": names[1]})
	adc.setValues({"da.charcode.load": "mood:Happy"})
	da.run_code("[LOAD_CHARCODE]")
	_check("LOAD_CHARCODE keeps unlisted clothes", bra.selectedName == names[1] and g.her.currentMood == "Happy")
	adc.setValues({"da.charcode.load": "mood:Angry"})
	da.run_code("[LOAD_FULL_CHARCODE]")
	_check("LOAD_FULL_CHARCODE resets them", bra.selection == 0 and g.her.currentMood == "Angry", bra.selectedName)
	g.her.setMood("Normal")
	# dialogue buttons
	var dc = g.dialogueControl
	dc.loadCustomDialogue('dialogue_name:"buttons"
button1:"pressed one"{"style":"Thought"}
intro:"hi"
', false)
	adc.setValues({"da.button1.name": "Go on"})
	da.run_code("[BUTTON1_ON]")
	var b = da.world.buttons[0]
	_check("button shown with its text", b.visible and b.text == "Go on" and b._flash_parent == g.container)
	b.on_click.call()
	_check("button click builds its line", dc.states.has("button1") and dc.states["button1"].build > 0)
	da.run_code("[BUTTONALL_CLEAR]")
	_check("BUTTONALL_CLEAR", not b.visible and b.text == "")
	da.run_code("[CLEARLINES_intro]")
	_check("CLEARLINES", dc.library.getPhrases("intro").is_empty())
	# importing another dialogue file's lines
	var dir: String = Flash.mods_dir("Dialogue")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("da_import_test.txt"), FileAccess.WRITE)
	f.store_string('extra:"imported line"
')
	f.close()
	adc.setValues({"da.dialogue.import": "da_import_test.txt"})
	_check("da.dialogue.import adds lines", dc.library.getPhrases("extra").size() == 1 and dc.library.getPhrases("button1").size() == 1)
	_check("da.held / da.finishes / da.her.name readable", adc.replaceValues("*da.finishes*") != ""
		and adc.replaceValues("*da.her.name*") != "")


func _mood_checks() -> void:
	var mm = Extensions.get_extension("moremoods")
	_check("moremoods on by default", mm != null and mm.enabled)
	if mm == null:
		return
	var her = g.her
	var adc = g.dialogueControl.advancedController
	da.run_code("[DISGUSTED_MOOD]")
	_check("[DISGUSTED_MOOD]", Moods.current() == "Disgusted" and her.currentMood == "Normal" and mm.angry_lips,
		"%s / %s" % [Moods.current(), her.currentMood])
	_check("angry mouth shown", her.head.face.currentLabel == "Angry", her.head.face.currentLabel)
	_check("dialogue variable moremoods", adc.replaceValues("*moremoods*") == "Disgusted")
	da.run_code("[BROKEN_MOOD]")
	_check("Broken: tongue always out", her.tongue.hangingOut and mm.always_tongue_out)
	her.setMood("Happy")
	_check("vanilla mood through moremoods", Moods.current() == "Happy" and her.currentMood == "Happy"
		and not mm.always_tongue_out and her.head.face.currentLabel == "Happy")
	da.run_code("[FRIGHTENED_MOOD]")
	var code: String = g.inGameMenu.getSaveDataString(false)
	_check("character code has moremoods", ";moremoods:Frightened" in code and ";mood:Normal" in code)
	her.setMood("Angry")
	g.inGameMenu.loadData(code, false)
	_check("character code restores the mood", Moods.current() == "Frightened", Moods.current())
	mm._cycle(1)
	var after_up := Moods.current()
	mm._cycle(-1)
	_check("selector cycles (alphabetical)", after_up == "Happy" and Moods.current() == "Frightened", after_up)
	_check("selector label", mm._label.text == "Frightened")
	# controls
	var ui = mm.ui
	ui.eyeroll_button.on_click.call()
	_check("eye roll button cycles", mm.face.eyeroll_mode == 1 and ui.eyeroll_button._idle == 0x00FF00)
	ui.eyeroll_button.on_click.call()
	ui.eyeroll_button.on_click.call()
	_check("eye roll back to off", mm.face.eyeroll_mode == 0)
	ui.eyelid_button.on_click.call()
	ui.eyelid_button.on_click.call()
	_check("eyelid limit button enables the slider", mm.face.eyelid_mode == 2 and ui.eyelid_slider.enabled)
	ui.eyelid_slider.on_change.call(0.8)
	_check("eyelid slider limits the eyelid", her.eye.upperEyelid.currentFrame >= 120, str(her.eye.upperEyelid.currentFrame))
	ui.eyelid_button.on_click.call()
	ui.eyelid_button.on_click.call()
	var bm: int = mm.behaviour.bite_mode
	ui.bite_button.on_click.call()
	_check("bite button cycles", mm.behaviour.bite_mode == (bm + 1) % 3)
	ui.bite_button.on_click.call()
	ui.bite_button.on_click.call()
	mm._label.on_click.call()
	_check("mood list opens on the mood name", ui.list.visible and ui.list.items.size() == 26)
	var idx: int = ui.list.items.find("Smug")
	ui._picked(idx)
	_check("picking a mood in the list", Moods.current() == "Smug")
	ui.close_list()
	her.setMood("Normal")


var _mood_cycle_i := 0
var _mood_seen := {}


## Holds every mood for 12 ticks (faces, eyes and behaviour run through all their code), checking some results.
func _mood_cycle_step() -> void:
	var mm = Extensions.get_extension("moremoods")
	var her = g.her
	var t := Flash.tick_count - _t0
	# keep her busy: grab, then stroke deep and shallow, so the moods' behaviour code runs too
	var main = Flash.get_tree().current_scene
	if t == 1:
		main._move(Vector2(5, 250))
	elif t > 6:
		main._move(Vector2(200 + (t % 10) * 30, 240))
	if t == 150:
		mm.behaviour.bite_mode = 2
		mm.behaviour.bite_slider = 1.0
		mm.behaviour.bite_timer = 70
	if t % 12 != 0:
		return
	if _mood_cycle_i > 0:
		var prev: String = mm.MOODS[_mood_cycle_i - 1]
		_mood_seen[prev] = {"upper": her.eye.upperEyelid.currentFrame, "lower": her.eye.lowerEyelid.currentFrame,
			"iris": her.eye.ball.irisContainer.iris.scaleY, "shock": her.eyelidMotion["shock"]}
	if _mood_cycle_i >= mm.MOODS.size():
		var d: Dictionary = _mood_seen
		_check("all 26 moods ran", d.size() == 26, str(d.size()))
		_check("Disgusted raises the lower eyelid", d["Disgusted"]["lower"] >= 170, str(d["Disgusted"]))
		_check("Smug raises the lower eyelid more", d["Smug"]["lower"] >= 175, str(d["Smug"]))
		_check("Spent lowers the upper eyelid", d["Spent"]["upper"] >= 125, str(d["Spent"]))
		_check("Android keeps the eyes wide open", d["Android"]["upper"] <= 2, str(d["Android"]))
		_check("Frightened: shocked eyes", d["Frightened"]["shock"] >= 30, str(d["Frightened"]))
		_check("Normal eyes unchanged", d["Normal"]["lower"] < 170, str(d["Normal"]))
		_check("a bite ran to the end", mm.behaviour.bite_timer == 0)
		var adc = g.dialogueControl.advancedController
		_check("bite and eyelid fields in the character code", ";bitemode:2,1.00" in g.inGameMenu.getSaveDataString(false)
			and ";uppereyelidlimit:" in g.inGameMenu.getSaveDataString(false))
		her.setMood("Normal")
		_finish()
		return
	her.setMood(mm.MOODS[_mood_cycle_i])
	_mood_cycle_i += 1


func _game_checks_later() -> void:
	var gt = da.game
	_check("PUSSYDRIP made droplets and ended", not gt._dripping and g.strandBackLayer.numChildren > _drops_before,
		"%d -> %d" % [_drops_before, g.strandBackLayer.numChildren])
	_check("INSTANT_FLASH with a duration fades back", gt.fader.alpha == 0.0, str(gt.fader.alpha))
	_check("masturbation raises her pleasure", gt.her_pleasure > 0.0)
	da.run_code("[MASTURBATE_STOP]")
	_check("MASTURBATE_STOP", not gt.masturbating)
	da.run_code("[FLASH_ff0000]")
	_check("FLASH starts transparent and fades in", gt.fader.alpha == 0.0 and gt._fade_in)


# ---------------------------------------------------------------- MoreTriggers

func _mt_checks() -> void:
	mt = Extensions.get_extension("moretriggers")
	_check("MoreTriggers on by default", mt != null and mt.enabled)
	if mt == null or not mt.enabled:
		return
	var her = g.her
	var st: Dictionary = g.dialogueControl.advancedController._dialogueDataStore
	_check("SHOCK with power", da.run_code("[SHOCK_100000_150]"))
	_check("SHOCK with the default power", da.recognises("[SHOCK_2500]") == "SHOCK")
	_check("LOOK at a point", da.run_code("[LOOK_10_20_100000]"))
	_check("LOOK_UP", da.recognises("[LOOK_UP_2000]") == "LOOK")
	_check("vanilla [SHOCK] [WINCE] [LOOK_UP] stay the game's", da.recognises("[SHOCK]") == ""
		and da.recognises("[WINCE]") == "" and da.recognises("[LOOK_UP]") == "" and da.recognises("[LOOK_DOWN]") == "")
	_check("CLOSE_MOUTH", da.run_code("[CLOSE_MOUTH]"))
	_mt_breasts = g.characterControl.breastSize
	_mt_body = her.bodyScale
	da.run_code("[GROW_BREASTS_BY_5][GROW_BODY_BY_10]")
	da.vars.set_value("mt.cuminmouth", 50)
	_check("mt.cuminmouth sets her cum in mouth", her.cumInMouth == roundi(her.maxCumInMouth * 0.5), str(her.cumInMouth))
	da.vars.set_value("mt.cuminmouth", "+10")
	_check("mt.cuminmouth +10 adds", da.vars.value_text("mt.cuminmouth") == "60", da.vars.value_text("mt.cuminmouth"))
	da.vars.set_value("mt.cuminmouth", 0)
	da.vars.set_value("mt.vigour", 100)
	_check("mt.vigour", her.vigour == 1050.0 and da.vars.value_text("mt.vigour") == "100", str(her.vigour))
	da.vars.set_value("mtA", 3)
	da.run_code("[BIND_VARIABLES_mtA_mtB]")
	_check("BIND_VARIABLES copies the value", st.get("mtB") == 3.0, str(st.get("mtB")))
	da.vars.set_value("mtA", 7)
	_check("BIND_VARIABLES follows writes", st.get("mtB") == 7.0, str(st.get("mtB")))
	da.run_code("[UPDATE_RESISTANCE_150]")
	_check("UPDATE_RESISTANCE clamps to 100", g.introResistance == 100.0, str(g.introResistance))
	da.run_code("[HIDE_HER]")
	_check("HIDE_HER hides her and her arms", not her.visible and not her.rightArmContainer.visible)
	da.run_code("[SHOW_HER][HIDE_HAIR]")
	_check("SHOW_HER, HIDE_HAIR", her.visible and her.rightArmContainer.visible and not her.hairTop.visible)
	da.run_code("[SHOW_HAIR][PENIS_ALPHA_MULTIPLY_50]")
	_check("PENIS_ALPHA", her.hairTop.visible and g.him.penis.alpha == 0.5 and g.him.penis.blendMode == "multiply")
	da.run_code("[PENIS_ALPHA_NORMAL_100][HER_ALPHA_LAYER_60]")
	_check("HER_ALPHA, her arm outside her too", is_equal_approx(her.alpha, 0.6) and her.blendMode == "layer"
		and (her.contains(her.rightArmContainer) or is_equal_approx(her.rightArmContainer.alpha, 0.6)))
	da.run_code("[HER_ALPHA_NORMAL_100]")
	da.run_code("[SET_PROGRESSBAR_10_20_0_100_25_FF0000_mtbar]")
	var bars: Dictionary = mt.screen._bars
	_check("SET_PROGRESSBAR", bars.has("mtbar") and bars["mtbar"][0].value == 25 and bars["mtbar"][0].x == 10.0)
	da.vars.set_value("mtbar", 80)
	_check("progress bar follows its variable", bars.has("mtbar") and bars["mtbar"][0].value == 80)
	da.run_code("[HIDE_PROGRESSBAR_ALL]")
	_check("HIDE_PROGRESSBAR_ALL", not bars["mtbar"][0].visible)
	da.run_code("[KILL_PROGRESSBAR_mtbar]")
	_check("KILL_PROGRESSBAR", not bars.has("mtbar"))
	da.run_code("[SHOW_SPLASHSCREEN_nothere.png_0][SHOW_CREDITS]")
	_check("SHOW_CREDITS starts the credits", mt.screen.credits != null)
	_check("credits html", mt.screen.CreditsScript.html_to_bbcode("<B>a</b><br/>x &amp; [y]") == "[b]a[/b]
x & [lb]y]")


func _mt_checks_later() -> void:
	if mt == null or not mt.enabled:
		return
	var her = g.her
	_check("SHOCK holds her shocked eyes", her.eyelidMotion["shock"] == 150.0, str(her.eyelidMotion["shock"]))
	_check("LOOK holds where she looks", her.currentLookTarget == Vector2(10, 20), str(her.currentLookTarget))
	_check("CLOSE_MOUTH holds her jaw", is_equal_approx(her.head.jaw.rotation_degrees, Her.closedJawAngle * 0.95),
		str(her.head.jaw.rotation_degrees))
	_check("GROW_BREASTS_BY_5", g.characterControl.breastSize == mini(_mt_breasts + 5, 149),
		"%d -> %d" % [_mt_breasts, g.characterControl.breastSize])
	_check("GROW_BODY_BY_10", is_equal_approx(her.bodyScale, minf(_mt_body + 0.01, 1.075)), str(her.bodyScale))
	_check("splash screen gone after its time", mt.screen._splash == null)
	var c = mt.screen.credits
	_check("credits roll up", c != null and c._areas[0]["y"] < 700.0, str(c._areas[0]["y"]) if c != null else "")
	da.run_code("[OPEN_MOUTH][SHOCK_0][LOOK_UP_0]")
	# switching off: triggers gone, effects undone; on again: back
	da.run_code("[HIDE_HER]")
	Extensions.set_enabled("moretriggers", false)
	_check("MoreTriggers off: its triggers are gone", da.recognises("[SHOCK_100]") == "" and da.vars.mod_value("mt.vigour") == null)
	_check("MoreTriggers off: she is shown again, credits gone", her.visible and mt.screen == null)
	Extensions.set_enabled("moretriggers", true)
	_check("MoreTriggers on again", da.recognises("[SHOCK_100]") == "SHOCK")
	Extensions.set_enabled("dialogueactions", false)
	Extensions.set_enabled("dialogueactions", true)
	_check("DialogueActions on again keeps the extensions' triggers", da.recognises("[SHOCK_100]") == "SHOCK"
		and da.recognises("[FRIGHTENED_MOOD]") == "FRIGHTENED_MOOD" and da.vars.mod_value("mt.vigour") != null)


func _start_line_setup() -> void:
	var dc = g.dialogueControl
	dc.stopSpeaking()
	dc.loadCustomDialogue('dialogue_name:"start test"\nstart:"Starting now"{"style":"Thought"}\n', false)
