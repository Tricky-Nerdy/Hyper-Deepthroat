extends RefCounted
## Checks of the new in-game menu (src/menu): every section builds, the controls change the game through the classic
## menu's handlers (and the classic menu shows the same), settings (side, pause, classic menu), extension settings
## pages and controls added by extensions. Run by tools/regress.sh (main.gd --driver); prints
## "MENU CHECKS: n passed, m failed" and quits.

var _pass := 0
var _fail := 0
var _phase := 0
var _t0 := 0
var menu: SDTMenu


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
			Flash.stage.getChildAt(0).playClicked()
			_t0 = Flash.tick_count
			_phase = 1
		1:
			if Flash.tick_count > _t0 + 10:
				menu = SDTMenu.instance
				_open_checks()
				_section_checks()
				_control_checks()
				_settings_checks()
				_extension_checks()
				_finish()


func _finish() -> void:
	print("MENU CHECKS: %d passed, %d failed" % [_pass, _fail])
	Flash.get_tree().quit(1 if _fail > 0 else 0)
	_phase = 99


## The spec with this label in a section (searched in the merged groups, like the menu shows them).
func _spec(section: String, label: String) -> Dictionary:
	for grp in menu._groups_of(menu._find_section(section)):
		for c in grp["controls"]:
			if c.get("label", "") == label:
				return c
			for sub in c.get("colors", []):
				if sub.get("label", "") == label:
					return sub
	return {}


func _open_checks() -> void:
	_check("new menu active", SDTMenu.active())
	_check("classic menu hidden", not g.inGameMenu.visible)
	g.inGameMenu.toggleMenu(true, 1)   # the Y key
	_check("Y opens the new menu on Her", menu.is_open and menu.section == "her" and not g.inGameMenu.menuOpen)
	_check("the menu pauses the game", g.gamePaused)
	g.inGameMenu.toggleMenu(true, 1)
	_check("Y again closes it", not menu.is_open and not g.gamePaused)
	g.inGameMenu.toggleMenu(true, 1)
	var press := func(p: Vector2, b := MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
		var e := InputEventMouseButton.new()
		e.button_index = b
		e.pressed = true
		e.position = p
		return e
	var inside: Vector2 = menu._dock.get_global_rect().get_center()
	var outside := Vector2(inside.x - menu._dock.size.x if not SDTMenu.on_left() else inside.x + menu._dock.size.x, inside.y)
	_check("a click on the dock keeps it open", not menu.outside_click(press.call(inside)))
	_check("the wheel outside keeps it open", not menu.outside_click(press.call(outside, MOUSE_BUTTON_WHEEL_UP)))
	_check("a click outside the dock closes it", menu.outside_click(press.call(outside)))
	menu.close_menu()
	g.inGameMenu.toggleMenu(true, 4)
	_check("O opens Settings", menu.is_open and menu.section == "settings")
	var ai: Control = menu._external_views.get("local_ai")
	_check("Local AI is registered in the dock", ai != null and menu._nav_buttons.has("local_ai"))
	menu.open_menu("local_ai")
	_check("Local AI opens in the dock", menu.is_open and menu.section == "local_ai" and ai.visible and ai.get_parent() == menu._content)
	menu.close_menu()
	_check("Local AI close returns to the game menu state", not menu.is_open and not ai.visible)


func _section_checks() -> void:
	for s in menu.sections:
		menu.show_section(s["id"])
		menu.build_now()
		_check("section %s builds" % s["id"], menu._rows.size() > 0, str(menu._rows.size()))
	menu.query = "spit"
	menu._show()
	menu.build_now()
	_check("search finds options in other sections", menu._rows.size() >= 2 and "spit" in menu._heading.text,
		"%d %s" % [menu._rows.size(), menu._heading.text])
	menu.show_section("her")


func _control_checks() -> void:
	var chars := _spec("her", "Character")   # first: changing her look makes her a custom character
	var names: Array = chars["options"].call()
	_check("character list", names.size() >= 20 and chars["index"].call() >= 0 and names[chars["index"].call()] == "SD chan",
		"%d %d" % [names.size(), chars["index"].call()])
	chars["pick"].call(names.find("Misty"))
	_check("character pick", g.characterControl.currentName == "Misty" or names[chars["index"].call()] == "Misty",
		str(chars["index"].call()))
	chars["pick"].call(names.find("SD chan"))

	var spit := _spec("effects", "Spit")
	spit["set"].call(false)
	_check("toggle: Spit off", not g.spit and not g.inGameMenu.optionsMenu.cbSpit.on and not spit["get"].call())
	spit["set"].call(true)
	_check("toggle: Spit on", g.spit and spit["get"].call())

	var res := _spec("behaviour", "Resistance")
	res["set"].call(0.25)
	res["release"].call()
	var want: float = g.inGameMenu.costumeMenu.resistanceSlider.currentValue(100)
	_check("slider: resistance", absf(res["get"].call() - 0.25) < 0.01 and absf(g.introResistance - want) < 0.5,
		"%s %s" % [res["get"].call(), g.introResistance])
	res["reset"].call()
	_check("slider: reset to the default", absf(g.introResistance - g.defaultResistance) < 0.5, str(g.introResistance))

	var iris := _spec("her", "Iris")
	iris["pick"].call(2)
	_check("arrow list: iris 3", g.characterControl.currentIris == 2 and iris["index"].call() == 2,
		str(g.characterControl.currentIris))
	iris["pick"].call(0)
	_check("arrow list: back to iris 1", g.characterControl.currentIris == 0)

	var top := _spec("clothes", "Top")
	top["pick"].call(1)
	var tc: CharacterElementHelper = g.characterControl.topControl
	_check("costume slot: top", tc.selection == 1 and top["index"].call() == 1, str(tc.selection))
	var col := _spec("clothes", "Top colour")
	col["set"].call({"r": 10, "g": 20, "b": 30, "a": 1.0})
	_check("costume colour", tc.rgb1.r == 10 and tc.rgb1.g == 20 and tc.rgb1.b == 30, str(tc.rgb1))
	top["pick"].call(0)

	var lip := _spec("her", "Lipstick")
	lip["set"].call({"r": 200, "g": 10, "b": 10, "a": 0.5})
	_check("colour: lipstick", g.characterControl.lipstickRGB.r == 200 and is_equal_approx(g.characterControl.lipstickRGB.a, 0.5),
		str(g.characterControl.lipstickRGB))

	var auto := _spec("scene", "Auto mode")
	auto["set"].call(true)
	_check("auto mode on", g.autoModeOn and g.inGameMenu.sceneMenu.cbAuto.on)
	auto["set"].call(false)
	_check("auto mode off", not g.autoModeOn)

	var mood: Dictionary = {}
	for grp in menu._groups_of(menu._find_section("her")):
		if grp["title"] == "Mood":
			mood = grp["controls"][0]
	_check("mood list has the extension moods", "Smug" in mood["options"].call() and "Ahegao" in mood["options"].call())
	mood["set"].call("Smug")
	_check("mood: Smug", Moods.current() == "Smug")
	mood["set"].call("Happy")
	_check("mood: Happy", Moods.current() == "Happy" and g.inGameMenu.sceneMenu.cbMoodHappy.on)
	mood["set"].call("Normal")

	var quality := _spec("settings", "Quality")
	quality["set"].call("Low")
	_check("choice: quality low", g.inGameMenu.optionsMenu.cbLowQuality.on and quality["get"].call() == "Low")
	quality["set"].call("High")

	var bg := _spec("scene", "Background")
	bg["pick"].call(0)
	_check("background picker", g.bgID == 1 and bg["options"].call()[0] == "Lab", str(g.bgID))

	# refreshing every visible row (what the menu does while open) reads all getters without errors
	for s in menu.sections:
		menu.show_section(s["id"])
		menu.build_now()
		menu._refresh_rows()
	_check("all rows refresh", true)


func _settings_checks() -> void:
	var side := _spec("settings", "Menu side")
	side["set"].call("Left")
	_check("menu on the left", menu._dock.anchor_left == 0.0 and menu._dock.offset_left == 0.0)
	side["set"].call("Right")
	_check("menu on the right", menu._dock.anchor_left == 1.0)

	var pause := _spec("settings", "Pause while the menu is open")
	pause["set"].call(false)
	_check("pause off resumes the game", not g.gamePaused)
	menu.close_menu()
	menu.open_menu("settings")
	_check("pause off: open menu keeps playing", menu.is_open and not g.gamePaused)
	pause["set"].call(true)
	_check("pause on pauses", g.gamePaused)

	var classic := _spec("settings", "Classic menu")
	classic["set"].call(true)
	_check("classic menu: new menu off", not SDTMenu.active() and not menu.is_open and g.inGameMenu.visible)
	g.inGameMenu.toggleMenu(true, 4)
	_check("classic menu opens with O", g.inGameMenu.menuOpen and not menu.is_open)
	menu.classic_button.dispatchEvent(FlashEvent.mouse(FlashEvent.CLICK))
	_check("classic menu's New menu button", SDTMenu.active() and menu.is_open and not g.inGameMenu.visible
		and not g.inGameMenu.menuOpen and not SDTMenu.classic(), "%s %s %s %s %s" % [SDTMenu.active(), menu.is_open,
		g.inGameMenu.visible, g.inGameMenu.menuOpen, SDTMenu.classic()])
	classic["set"].call(true)
	g.inGameMenu.closeMenu()
	classic["set"].call(false)
	_check("back to the new menu", SDTMenu.active() and not g.inGameMenu.visible)

	Extensions.set_vanilla_mode(true)
	menu.apply_mode()
	_check("Vanilla mode uses the classic menu", not SDTMenu.active() and g.inGameMenu.visible)
	Extensions.set_vanilla_mode(false)
	menu.apply_mode()
	_check("leaving Vanilla mode brings it back", SDTMenu.active())


func _extension_checks() -> void:
	menu.open_menu("ext:moremoods")
	menu.build_now()
	_check("moremoods settings page", menu._rows.size() > 20 and menu._heading.text != "", str(menu._rows.size()))
	var mm: SDTExtension = Extensions.get_extension("moremoods")
	var spec := MenuSchema.setting_control(mm, "closemenuonselect")
	var before: bool = mm.get_setting("closemenuonselect")
	spec["set"].call(not before)
	_check("setting toggle changes the setting", mm.get_setting("closemenuonselect") == (not before))
	spec["set"].call(before)
	var sl := MenuSchema.setting_control(mm, "biteoccurancedivisor")
	sl["set"].call(500.0)
	_check("setting slider", is_equal_approx(float(mm.get_setting("biteoccurancedivisor")), 500.0))
	sl["set"].call(float(mm._settings["biteoccurancedivisor"]["default"]))

	# moremoods' modes in Her > Face and Behaviour > Biting (the classic menu's u / eyelid / bite buttons)
	var roll := _spec("her", "Eye roll")
	_check("eye roll control in Her", roll.get("group", "") == "Face" and roll.get("owner", "") == "moremoods")
	var roll_before: int = mm.face.eyeroll_mode
	roll["set"].call("Roll")
	_check("eye roll control sets the mode", mm.face.eyeroll_mode == 1 and roll["get"].call() == "Roll")
	mm.ui.set_eyeroll(roll_before)
	var lid_before: int = mm.face.eyelid_mode
	_spec("her", "Upper eyelids")["set"].call("Normal")
	var limit := _spec("her", "Eyelid limit")
	_check("eyelid limit hidden unless limited", not limit["visible"].call())
	_spec("her", "Upper eyelids")["set"].call("Both")
	_check("eyelid limit shown with Both", mm.face.eyelid_mode == 3 and limit["visible"].call())
	mm.ui.set_eyelid(lid_before)
	var bite := _spec("behaviour", "Biting")
	var bite_before: int = mm.behaviour.bite_mode
	bite["set"].call("By slider")
	_check("biting control sets the mode", mm.behaviour.bite_mode == 2 and _spec("behaviour", "Bite chance")["visible"].call())
	mm.ui.set_bite(bite_before)
	Extensions.set_enabled("moremoods", false)
	_check("moremoods off removes its controls", _spec("her", "Eye roll").is_empty())
	Extensions.set_enabled("moremoods", true)
	_check("moremoods on adds them once", menu._groups_of(menu._find_section("her")).filter(func(gr): return gr["title"] == "Face")[0]["controls"].filter(func(c): return c.get("label", "") == "Eye roll").size() == 1)

	SDTMenu.add_control({"type": "toggle", "label": "Test toggle", "owner": "moremoods", "section": "her",
		"group": "Face", "get": func(): return true, "set": func(_v): pass})
	menu.show_section("her")
	var found := _spec("her", "Test toggle")
	_check("extension control in a vanilla group", not found.is_empty())
	Extensions.set_enabled("moremoods", false)
	menu.show_section("her")
	menu.build_now()
	var shown := menu._rows.any(func(r): return r.get_meta("spec").get("label", "") == "Test toggle")
	_check("extension off: its controls are hidden", not shown)
	Extensions.set_enabled("moremoods", true)
	SDTMenu.remove_owner("moremoods")
	_check("remove_owner", _spec("her", "Test toggle").is_empty())
	menu.close_menu()
