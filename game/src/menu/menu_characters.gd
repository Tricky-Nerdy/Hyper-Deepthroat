class_name MenuCharacters
extends RefCounted
## Port addition (not in the original game): the character list of the new menu (SDTMenu), read from the classic
## character menu (CharacterMenu: the game's characters, then stored ones, in the player's order) and selected
## through it, so C / X, stored characters and the classic menu keep working the same way.


static func _menu() -> CharacterMenu:
	return g.inGameMenu.characterMenu


static func names() -> Array:
	var m := _menu()
	var out: Array = []
	for t in m.thumbs:
		out.append(m.charNames[t.baseCharID] if t.isBaseChar else t.customChar.charName)
	return out


## The selected character's position in names(), -1 for a custom (edited or loaded from a code) character.
static func index() -> int:
	var m := _menu()
	return m.thumbs.find(m.selected) if m.selected != null else -1


static func select(i: int) -> void:
	var m := _menu()
	if i < 0 or i >= m.thumbs.size():
		return
	m.resetSearch()
	m.triggerSelect(i)


## Puts on character i's clothes only (the classic Select... costume button).
static func load_costume(i: int) -> void:
	var m := _menu()
	if i < 0 or i >= m.thumbs.size():
		return
	g.inGameMenu.onlyLoadCostume = true
	m.triggerSelect(i)
	g.inGameMenu.onlyLoadCostume = false


## A list of characters to take the clothes from.
static func choose_costume() -> void:
	if SDTMenu.instance == null:
		return
	var pop := PopupPanel.new()
	var v := VBoxContainer.new()
	var l := Label.new()
	l.text = "Wear the clothes of:"
	v.add_child(l)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(170, 260)
	list.add_theme_stylebox_override("panel", MenuTheme.box(MenuTheme.FIELD, MenuTheme.LINE, 4, 3, 3))
	list.add_theme_stylebox_override("hovered", MenuTheme.box(MenuTheme.CARD, Color(0, 0, 0, 0), 3, 3, 1))
	list.add_theme_stylebox_override("selected", MenuTheme.box(MenuTheme.ACCENT, Color(0, 0, 0, 0), 3, 3, 1))
	list.add_theme_stylebox_override("selected_focus", MenuTheme.box(MenuTheme.ACCENT, Color(0, 0, 0, 0), 3, 3, 1))
	list.add_theme_color_override("font_selected_color", MenuTheme.INK)
	for n in names():
		list.add_item(n)
	list.item_clicked.connect(func(i: int, _p, _b):
		load_costume(i)
		pop.hide())
	v.add_child(list)
	pop.add_child(v)
	pop.popup_hide.connect(func(): SDTMenu.open_popups -= 1; pop.queue_free())
	SDTMenu.instance.add_popup(pop)
	SDTMenu.open_popups += 1
	var vp := SDTMenu.instance.get_viewport().get_visible_rect().size
	var x := 8.0 if not SDTMenu.on_left() else SDTMenu.WIDTH + 8.0
	if not SDTMenu.on_left():
		x = vp.x - SDTMenu.WIDTH - 190
	pop.popup(Rect2i(Vector2i(int(x), 40), Vector2i(0, 0)))
