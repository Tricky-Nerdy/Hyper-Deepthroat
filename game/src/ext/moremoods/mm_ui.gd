extends RefCounted
## moremoods' menu controls, where the Loader mod put them: the eye roll button (Scene menu, "u"), the upper
## eyelid limit button and slider (Custom menu), the bite button and slider (Options menu) and the mood list that
## opens from the mood label. The new menu's controls for the same modes (Her > Face, Behaviour > Biting) are
## declared in add_menu_controls and use the same setters.

const OFF := 0xFFFFFF
const GREEN := 0x00FF00
const BLUE := 0x0000FF
const CYAN := 0x00FFFF

var mm
var eyeroll_button: ExtButton
var eyelid_button: ExtButton
var eyelid_slider: ExtSlider
var bite_button: ExtButton
var bite_slider: ExtSlider
var list: ExtList
var _list_moods: Array = []
var _just_opened := false


func _init(p_mm) -> void:
	mm = p_mm


func build() -> void:
	var face = mm.face
	var beh = mm.behaviour
	# moremoods put it at y = 80, below the part of the Scene menu the port shows; next to the selector instead
	eyeroll_button = mm.menu_button("sceneMenu", -330 + 100 + 1 + 22 + 2, 40, "u", _eyeroll_clicked)
	eyelid_slider = mm.menu_slider("customMenu", 100, 80, 80, 12, face.eyelid_slider, func(v): face.eyelid_slider = v; g.her.updateEyes())
	mm.menu_label("customMenu", 100 - 75 - 15, 76, 75, "Eyelid Limit", 11, "right")
	eyelid_button = mm.menu_button("customMenu", 100 - 13, 80, "◒", _eyelid_clicked, 12, 12)
	bite_button = mm.menu_button("optionsMenu", -37, 40, "⬛", _bite_clicked)
	mm.menu_label("optionsMenu", -37 + 21, 37, 75, "Bite", 14)
	bite_slider = mm.menu_slider("optionsMenu", -37 + 21 + 34, 42, 82, 12, beh.bite_slider, func(v): beh.bite_slider = v)
	if mm.get_setting("addmenupopout"):
		list = ExtList.new(200, 368)
		list.visible = false
		list.on_pick = _picked
		mm.menu_add("sceneMenu", list, 140, -500)
		mm._label.on_click = open_list
		mm.hook_after(&"InGameMenu.updateTabs", func(_c): close_list())
		mm.hook_after(&"InGameMenu.closeMenu", func(_c): close_list())
		g.inGameMenu.addEventListener(FlashEvent.CLICK, _menu_clicked)
	add_menu_controls()
	refresh()


func remove() -> void:
	if g.inGameMenu != null:
		g.inGameMenu.removeEventListener(FlashEvent.CLICK, _menu_clicked)


## Button colours and slider states from the current modes (after a character code load too).
func refresh() -> void:
	var face = mm.face
	var beh = mm.behaviour
	if eyeroll_button:
		eyeroll_button.set_color([OFF, GREEN, BLUE][clampi(face.eyeroll_mode, 0, 2)])
	if eyelid_button:
		eyelid_button.set_color([OFF, GREEN, BLUE, CYAN][clampi(face.eyelid_mode, 0, 3)])
		eyelid_slider.enabled = face.eyelid_mode >= 2
		eyelid_slider.set_value(face.eyelid_slider)
	if bite_button:
		bite_button.set_color([OFF, BLUE, GREEN][clampi(beh.bite_mode, 0, 2)])
		bite_slider.enabled = beh.bite_mode == 2
		bite_slider.set_value(beh.bite_slider)


func _eyeroll_clicked() -> void:
	set_eyeroll((mm.face.eyeroll_mode + 1) % 3)


func set_eyeroll(mode: int) -> void:
	var face = mm.face
	face.eyeroll_mode = mode
	if not face.eyeroll_enabled():
		g.her.lookAt(g.her.eyesDown)
	var her = g.her
	her.eye.ball.irisContainer.x = -50.65
	her.eye.ball.highlights.x = 20.95
	refresh()


func _eyelid_clicked() -> void:
	set_eyelid((mm.face.eyelid_mode + 1) % 4)


func set_eyelid(mode: int) -> void:
	mm.face.eyelid_mode = mode
	g.her.updateEyes()
	refresh()


func _bite_clicked() -> void:
	set_bite((mm.behaviour.bite_mode + 1) % 3)


func set_bite(mode: int) -> void:
	mm.behaviour.bite_mode = mode
	refresh()


const EYEROLL := ["Off", "Roll", "Roll + cross-eyed"]
const EYELID := ["Normal", "Auto", "Limit", "Both"]
const BITE := ["Off", "By mood", "By slider"]


## Port addition: the new menu's controls (SDTMenu) for the eye roll, upper eyelid and biting modes.
func add_menu_controls() -> void:
	var face = mm.face
	var beh = mm.behaviour
	mm.menu_control("her", "Face", MenuSchema.choice("Eye roll",
		"Her eyes roll back as she nears passing out. Roll + cross-eyed: she also goes cross-eyed when she passes out.",
		EYEROLL, func(): return EYEROLL[clampi(face.eyeroll_mode, 0, 2)], func(v: String): set_eyeroll(EYEROLL.find(v)),
		{"keywords": "eyeroll eyes moremoods", "wide": true}))
	mm.menu_control("her", "Face", MenuSchema.choice("Upper eyelids",
		"Normal: the mood decides. Auto: they lower with where she looks. Limit: they stay at least as closed as the slider below. Both: auto and limit.",
		EYELID, func(): return EYELID[clampi(face.eyelid_mode, 0, 3)], func(v: String): set_eyelid(EYELID.find(v)),
		{"keywords": "eyelid lids moremoods", "wide": true}))
	mm.menu_control("her", "Face", {"type": "slider", "label": "Eyelid limit",
		"tip": "How closed her upper eyelids stay at least (Upper eyelids: Limit or Both).",
		"get": func(): return face.eyelid_slider,
		"set": func(v: float): face.eyelid_slider = v; g.her.updateEyes(); refresh(),
		"visible": func(): return face.eyelid_mode >= 2, "keywords": "eyelid lids moremoods"})
	mm.menu_control("behaviour", "Biting", MenuSchema.choice("Biting",
		"By mood: she bites when angry, upset, disgusted, aggressive or teasing, more as she runs out of breath. By slider: in any mood, as much as the slider below.",
		BITE, func(): return BITE[clampi(beh.bite_mode, 0, 2)], func(v: String): set_bite(BITE.find(v)),
		{"keywords": "bite moremoods", "wide": true}))
	mm.menu_control("behaviour", "Biting", {"type": "slider", "label": "Bite chance",
		"tip": "Low: she bites when close to passing out; higher: also when out of breath; highest: also when he is deep.",
		"get": func(): return beh.bite_slider,
		"set": func(v: float): beh.bite_slider = v; refresh(),
		"visible": func(): return beh.bite_mode == 2, "keywords": "bite moremoods"})


func open_list() -> void:
	if list == null:
		return
	_list_moods = mm.selectable()
	list.set_items(_list_moods)
	var i := _list_moods.find(mm.mood_name)
	list.select(i)
	list.scroll_to(maxi(i, 0))
	list.visible = true
	_just_opened = true


func close_list() -> void:
	if list != null:
		list.visible = false
	_just_opened = false


func _picked(i: int) -> void:
	if i >= 0 and i < _list_moods.size():
		g.her.setMood(_list_moods[i])
	if mm.get_setting("closemenuonselect"):
		close_list()
	else:
		_just_opened = true


## A click anywhere else in the menu closes the list (moremoods' menuClicked).
func _menu_clicked(_e) -> void:
	if list != null and list.visible and not _just_opened:
		close_list()
	_just_opened = false
