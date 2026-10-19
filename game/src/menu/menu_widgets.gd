class_name MenuWidgets
extends RefCounted
## Port addition (not in the original game): builds the Godot controls of the new menu (SDTMenu) from control
## specs (Dictionaries, see MenuSchema). Every row gets a "refresh" meta Callable that re-reads the value with the
## spec's get(), so the menu shows changes made elsewhere (hotkeys, dialogue, character loads).
##
## Spec keys: type, id, label, tip, owner (extension id: shown as a tag), get / set, and per type:
##   toggle   get() -> bool, set(bool)
##   choice   options (Array or Callable -> Array of String), get() -> String, set(String). Up to 4 short options
##            show as buttons, more as a dropdown.
##   pick     options, index() -> int, pick(i): a dropdown with previous / next arrows (costume slots, hair, ...)
##   slider   get() -> float, set(float), min / max (default 0..1), step, release() when let go, reset() for the
##            reset button, format(v) -> String for the value label
##   actions  buttons: Array of [text, Callable]
##   text     get() -> String, set(String) on Enter / focus loss (live: on every change), placeholder
##   color    get() -> {r, g, b, a} (0..255, a 0..1), set(dict) while dragging, release(), alpha (bool)
##   colors   colors: Array of color specs (each may have visible()), shown side by side
##   hsl      get() -> {h, s, l, c}, set(dict), release(), remove()
##   chips    options, get() -> String, set(String): a wrapping row of buttons (moods, backgrounds)
##   note     text
##   custom   build() -> Control (its own refresh: give the Control a "refresh" meta Callable)
## Optional for all: visible() -> bool, enabled() -> bool, wide (label above the control).

const ROW_H := 18
const CONTROL_W := 120


static func build(spec: Dictionary, on_hover: Callable) -> Control:
	var t: String = spec.get("type", "note")
	var row: BoxContainer
	var wide: bool = spec.get("wide", t in ["chips", "note", "custom", "actions"] and spec.get("label", "") != "")
	if t in ["note"] or (t in ["actions", "custom", "chips"] and spec.get("label", "") == ""):
		row = VBoxContainer.new()
		wide = true
	elif wide:
		row = VBoxContainer.new()
	else:
		row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 3 if wide else 6)
	row.custom_minimum_size.y = ROW_H
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.tooltip_text = spec.get("tip", "")
	row.mouse_entered.connect(func(): on_hover.call(spec))
	var label_text: String = spec.get("label", "")
	if label_text != "" and t != "note":
		row.add_child(_label_row(spec, not wide))
	var refreshers: Array = []
	var ctl: Control = null
	match t:
		"toggle":
			ctl = _toggle(spec, refreshers)
		"choice":
			ctl = _choice(spec, refreshers)
		"pick":
			ctl = _pick(spec, refreshers)
		"slider":
			ctl = _slider(spec, refreshers)
		"actions":
			ctl = _actions(spec)
		"text":
			ctl = _text(spec, refreshers)
		"color":
			ctl = _color(spec, refreshers)
		"colors":
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 3)
			for sub in spec["colors"]:
				var one := _color(sub, refreshers)
				var sv: Callable = sub.get("visible", Callable())
				if sv.is_valid():
					refreshers.append(func(): one.visible = sv.call())
				h.add_child(one)
			ctl = h
		"hsl":
			ctl = _hsl(spec, refreshers)
		"chips":
			ctl = _chips(spec, refreshers)
		"note":
			var l := Label.new()
			l.text = spec.get("text", "")
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.add_theme_color_override("font_color", MenuTheme.MUTED)
			ctl = l
		"custom":
			ctl = spec["build"].call()
			if ctl.has_meta("refresh"):
				refreshers.append(ctl.get_meta("refresh"))
	if ctl != null:
		ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL if wide else Control.SIZE_SHRINK_END
		row.add_child(ctl)
	var vis: Callable = spec.get("visible", Callable())
	var en: Callable = spec.get("enabled", Callable())
	row.set_meta("refresh", func():
		if vis.is_valid():
			row.visible = vis.call()
			if not row.visible:
				return
		var on: bool = en.call() if en.is_valid() else true
		_set_enabled(row, on)
		for r in refreshers:
			r.call())
	row.set_meta("spec", spec)
	return row


static func _label_row(spec: Dictionary, expand: bool) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = spec.get("label", "")
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # clip_text: without expanding it would get no width
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	if spec.get("owner", "") != "":
		h.add_child(tag(spec["owner"]))
	return h


static func tag(text: String) -> Label:
	var t := Label.new()
	t.text = text
	t.add_theme_font_size_override("font_size", MenuTheme.SMALL)
	t.add_theme_color_override("font_color", MenuTheme.PLUGIN_INK)
	t.add_theme_stylebox_override("normal", MenuTheme.box(MenuTheme.PLUGIN, Color(0, 0, 0, 0), 2, 3, 0))
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


static func _set_enabled(node: Node, on: bool) -> void:
	for c in node.get_children():
		if c is BaseButton:
			c.disabled = not on
		elif c is Slider:
			c.editable = on
		elif c is LineEdit:
			c.editable = on
		if c.get_child_count() > 0:
			_set_enabled(c, on)
	if node is Control:
		node.modulate.a = 1.0 if on else 0.55


static func _options(spec: Dictionary) -> Array:
	var o = spec.get("options", [])
	return o.call() if o is Callable else o


# ---------------------------------------------------------------- widgets

static func _toggle(spec: Dictionary, refreshers: Array) -> Control:
	var b := CheckButton.new()
	b.focus_mode = Control.FOCUS_NONE
	b.toggled.connect(func(on: bool): spec["set"].call(on))
	refreshers.append(func(): b.set_pressed_no_signal(bool(spec["get"].call())))
	return b


static func _choice(spec: Dictionary, refreshers: Array) -> Control:
	var opts := _options(spec)
	var short := opts.size() <= 4 and opts.all(func(o): return str(o).length() <= 12)
	if short and not spec.get("dropdown", false):
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 1)
		var group := ButtonGroup.new()
		var buttons: Array = []
		for o in opts:
			var b := Button.new()
			b.text = str(o)
			b.toggle_mode = true
			b.button_group = group
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_font_size_override("font_size", MenuTheme.SMALL + 1)
			b.pressed.connect(func(): spec["set"].call(str(o)))
			h.add_child(b)
			buttons.append(b)
		refreshers.append(func():
			var v := str(spec["get"].call())
			for b in buttons:
				b.set_pressed_no_signal(b.text == v))
		return h
	var ob := _dropdown(CONTROL_W)
	# the list is filled when it opens (options can change: mods loaded, extension moods); until then the button
	# only shows the current value
	ob.button_down.connect(func():
		var v := str(spec["get"].call())
		ob.clear()
		for o in _options(spec):
			ob.add_item(str(o))
			if str(o) == v:
				ob.select(ob.item_count - 1))
	ob.item_selected.connect(func(i: int): spec["set"].call(ob.get_item_text(i)))
	refreshers.append(func():
		var v := str(spec["get"].call())
		if ob.text != v:
			ob.text = v)
	return ob


static func _dropdown(w: float) -> OptionButton:
	var ob := OptionButton.new()
	ob.custom_minimum_size.x = w
	ob.fit_to_longest_item = false
	ob.clip_text = true
	ob.focus_mode = Control.FOCUS_NONE
	return ob


static func _pick(spec: Dictionary, refreshers: Array) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 1)
	var prev := _icon_button("‹", "Previous")
	var next := _icon_button("›", "Next")
	var ob := _dropdown(CONTROL_W - 34)
	# options are read only when needed (they can mean a folder listing): when the list opens, and when the
	# index changes
	var names := [[]]
	var shown := [-2]
	var show := func():
		var i: int = spec["index"].call()
		if i == shown[0]:
			return
		shown[0] = i
		if i >= names[0].size():
			names[0] = _options(spec)
		var t := str(names[0][i]) if i >= 0 and i < names[0].size() else ""
		if ob.text != t:
			ob.text = t
	ob.button_down.connect(func():
		names[0] = _options(spec)
		ob.clear()
		for o in names[0]:
			ob.add_item(str(o))
		var i: int = spec["index"].call()
		ob.select(i if i < ob.item_count else -1))
	ob.item_selected.connect(func(i: int): spec["pick"].call(i); shown[0] = -2; show.call())
	prev.pressed.connect(func():
		var i: int = spec["index"].call()
		if i > 0:
			spec["pick"].call(i - 1)
		shown[0] = -2
		show.call())
	next.pressed.connect(func():
		names[0] = _options(spec)
		var i: int = spec["index"].call()
		if i < names[0].size() - 1:
			spec["pick"].call(i + 1)
		shown[0] = -2
		show.call())
	h.add_child(prev)
	h.add_child(ob)
	h.add_child(next)
	refreshers.append(show)
	return h


static func _icon_button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(16, 16)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", MenuTheme.box(MenuTheme.FIELD, MenuTheme.LINE, 4, 3, 0))
	return b


static func _slider(spec: Dictionary, refreshers: Array) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	var s := HSlider.new()
	s.min_value = spec.get("min", 0.0)
	s.max_value = spec.get("max", 1.0)
	s.step = spec.get("step", 0.0)
	s.custom_minimum_size = Vector2(78, 14)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var val := Label.new()
	val.custom_minimum_size.x = 24
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.add_theme_font_size_override("font_size", MenuTheme.SMALL)
	val.add_theme_color_override("font_color", MenuTheme.MUTED)
	var fmt: Callable = spec.get("format", func(v):
		var span: float = s.max_value - s.min_value
		return "%d%%" % roundi((v - s.min_value) / span * 100.0) if span > 0 else str(v))
	var dragging := [false]
	s.drag_started.connect(func(): dragging[0] = true)
	s.drag_ended.connect(func(_changed):
		dragging[0] = false
		if spec.has("release"):
			spec["release"].call())
	s.value_changed.connect(func(v: float):
		spec["set"].call(v)
		val.text = fmt.call(v)
		if not dragging[0] and spec.has("release"):
			spec["release"].call())
	h.add_child(s)
	h.add_child(val)
	if spec.has("reset"):
		var r := _icon_button("↺", "Back to the default")
		r.pressed.connect(func(): spec["reset"].call(); s.set_value_no_signal(spec["get"].call()); val.text = fmt.call(s.value))
		h.add_child(r)
	refreshers.append(func():
		if dragging[0]:
			return
		s.set_value_no_signal(float(spec["get"].call()))
		val.text = fmt.call(s.value))
	return h


static func _actions(spec: Dictionary) -> Control:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 4)
	f.add_theme_constant_override("v_separation", 4)
	for a in spec.get("buttons", []):
		var b := Button.new()
		b.text = a[0]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(a[1])
		if a.size() > 2:
			b.tooltip_text = a[2]
		f.add_child(b)
	return f


static func _text(spec: Dictionary, refreshers: Array) -> Control:
	var e := LineEdit.new()
	e.custom_minimum_size.x = CONTROL_W
	e.placeholder_text = spec.get("placeholder", "")
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.focus_entered.connect(func(): g.inTextField = true)
	var commit := func(): spec["set"].call(e.text)
	e.focus_exited.connect(func(): g.inTextField = false; commit.call())
	e.text_submitted.connect(func(_t): commit.call(); e.release_focus())
	if spec.get("live", false):
		e.text_changed.connect(func(t): spec["set"].call(t))
	refreshers.append(func():
		if not e.has_focus():
			e.text = str(spec["get"].call()))
	return e


static func _color(spec: Dictionary, refreshers: Array) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(30, 16)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = spec.get("label", "")
	var sw := ColorRect.new()
	sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sw.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sw.offset_left = 3
	sw.offset_top = 3
	sw.offset_right = -3
	sw.offset_bottom = -3
	b.add_child(sw)
	var to_color := func(c) -> Color:
		return Color(c.r / 255.0, c.g / 255.0, c.b / 255.0, float(c.a)) if c != null else Color(0, 0, 0, 0)
	b.pressed.connect(func():
		var pop := PopupPanel.new()
		var cp := ColorPicker.new()
		cp.edit_alpha = spec.get("alpha", true)
		cp.presets_visible = false
		cp.color_modes_visible = false
		cp.color = to_color.call(spec["get"].call())
		cp.color_changed.connect(func(c: Color):
			spec["set"].call({"r": roundi(c.r * 255), "g": roundi(c.g * 255), "b": roundi(c.b * 255), "a": snappedf(c.a, 0.001)})
			sw.color = c)
		pop.add_child(cp)
		pop.popup_hide.connect(func():
			SDTMenu.open_popups -= 1
			if spec.has("release"):
				spec["release"].call()
			pop.queue_free())
		b.add_child(pop)
		SDTMenu.open_popups += 1
		pop.popup(Rect2i(_popup_pos(b, Vector2(230, 300)), Vector2i(0, 0))))
	refreshers.append(func(): sw.color = to_color.call(spec["get"].call()))
	return b


static func _popup_pos(anchor: Control, size: Vector2) -> Vector2i:
	var r := anchor.get_global_rect()
	var vp := anchor.get_viewport_rect().size
	var p := Vector2(r.position.x - size.x - 8, r.position.y - 40)
	if p.x < 4:
		p.x = r.end.x + 8
	p.y = clampf(p.y, 4, vp.y - size.y - 4)
	return Vector2i(p)


const HSL_ROWS := [["Hue", "h", -180.0, 180.0], ["Saturation", "s", 0.0, 4.0], ["Lightness", "l", 0.0, 4.0],
	["Contrast", "c", 0.0, 4.0]]


static func _hsl(spec: Dictionary, refreshers: Array) -> Control:
	var b := Button.new()
	b.text = "Adjust…"
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func():
		var pop := PopupPanel.new()
		var v := VBoxContainer.new()
		v.custom_minimum_size.x = 200
		var cur: Dictionary = spec["get"].call().duplicate()
		var sliders := {}
		for r in HSL_ROWS:
			var h := HBoxContainer.new()
			var l := Label.new()
			l.text = r[0]
			l.custom_minimum_size.x = 62
			var s := HSlider.new()
			s.min_value = r[2]
			s.max_value = r[3]
			s.step = 0.0
			s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			s.value = float(cur.get(r[1], 0.0))
			var key: String = r[1]
			s.value_changed.connect(func(x: float):
				cur[key] = x
				spec["set"].call(cur.duplicate()))
			s.drag_ended.connect(func(_c): if spec.has("release"): spec["release"].call())
			sliders[key] = s
			h.add_child(l)
			h.add_child(s)
			v.add_child(h)
		if spec.has("remove"):
			var rm := Button.new()
			rm.text = "Remove tint"
			rm.pressed.connect(func():
				spec["remove"].call()
				var now: Dictionary = spec["get"].call()
				for k in sliders:
					sliders[k].set_value_no_signal(float(now.get(k, 0.0)))
				cur = now.duplicate())
			v.add_child(rm)
		pop.add_child(v)
		pop.popup_hide.connect(func(): SDTMenu.open_popups -= 1; pop.queue_free())
		b.add_child(pop)
		SDTMenu.open_popups += 1
		pop.popup(Rect2i(_popup_pos(b, Vector2(216, 110)), Vector2i(0, 0))))
	return b


static func _chips(spec: Dictionary, refreshers: Array) -> Control:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", 3)
	f.add_theme_constant_override("v_separation", 3)
	var built := [[]]
	var rebuild := func():
		for c in f.get_children():
			c.queue_free()
		var opts := _options(spec)
		built[0] = opts
		var marked: Callable = spec.get("marked", Callable())
		for o in opts:
			var b := Button.new()
			b.text = str(o)
			b.toggle_mode = true
			b.focus_mode = Control.FOCUS_NONE
			b.add_theme_font_size_override("font_size", MenuTheme.SMALL + 1)
			if marked.is_valid() and marked.call(o):
				b.add_theme_stylebox_override("normal", MenuTheme.box(MenuTheme.FIELD, MenuTheme.PLUGIN.darkened(0.35), 8, 6, 1))
			else:
				b.add_theme_stylebox_override("normal", MenuTheme.box(MenuTheme.FIELD, MenuTheme.LINE, 8, 6, 1))
			b.add_theme_stylebox_override("pressed", MenuTheme.box(MenuTheme.ACCENT, MenuTheme.ACCENT, 8, 6, 1))
			b.add_theme_stylebox_override("hover", MenuTheme.box(MenuTheme.FIELD, MenuTheme.ACCENT, 8, 6, 1))
			b.pressed.connect(func(): spec["set"].call(str(o)))
			f.add_child(b)
	rebuild.call()
	refreshers.append(func():
		if _options(spec) != built[0]:
			rebuild.call()
		var v := str(spec["get"].call())
		for b in f.get_children():
			if b is Button and not b.is_queued_for_deletion():
				b.set_pressed_no_signal(b.text == v))
	return f
