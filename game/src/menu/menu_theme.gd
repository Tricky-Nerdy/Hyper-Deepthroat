class_name MenuTheme
extends RefCounted
## Port addition (not in the original game): colours, fonts and the Godot Theme of the new menu (SDTMenu).
## Sizes are in stage pixels (the window scales the 700x600 stage, and the menu with it).

const PANEL := Color("161a22")
const CARD := Color("1e2430")
const FIELD := Color("121620")
const LINE := Color("2c3442")
const TEXT := Color("e8ecf2")
const MUTED := Color("a3aec0")
const ACCENT := Color("5bb2e8")
const INK := Color("08131d")
const PLUGIN := Color("f0b45a")
const PLUGIN_INK := Color("2a1b05")
const TRACK := Color("3a4354")

const FONT_SIZE := 10
const SMALL := 8
const HEADING := 8
const TITLE := 12

static var _theme: Theme = null
static var _font: Font = null


## The menu's text font: Godot's default (the game's own fonts from the SWF only hold the glyphs the game uses).
static func font() -> Font:
	if _font == null:
		_font = ThemeDB.fallback_font
	return _font


static func box(bg: Color, border := Color(0, 0, 0, 0), radius := 4, pad_h := 6, pad_v := 3, border_w := 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	if border.a > 0:
		s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	s.anti_aliasing = true
	return s


static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = FONT_SIZE
	for c in ["Label", "Button", "LineEdit", "OptionButton", "CheckButton", "PopupMenu", "TooltipLabel", "RichTextLabel"]:
		t.set_color("font_color", c, TEXT)
	t.set_color("font_hover_color", "Button", TEXT)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_hover_pressed_color", "Button", INK)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", MUTED)
	t.set_color("font_placeholder_color", "LineEdit", MUTED)
	t.set_color("caret_color", "LineEdit", TEXT)
	t.set_color("selection_color", "LineEdit", ACCENT.darkened(0.4))

	var btn := box(FIELD, LINE, 4, 6, 2)
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", box(FIELD, ACCENT, 4, 6, 2))
	t.set_stylebox("pressed", "Button", box(ACCENT, ACCENT, 4, 6, 2))
	t.set_stylebox("hover_pressed", "Button", box(ACCENT.lightened(0.1), ACCENT, 4, 6, 2))
	t.set_stylebox("disabled", "Button", box(FIELD.darkened(0.2), LINE, 4, 6, 2))
	t.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), ACCENT, 4, 6, 2))
	for c in ["OptionButton"]:
		for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			t.set_stylebox(st, c, t.get_stylebox(st, "Button"))
		t.set_color("font_pressed_color", c, TEXT)
		t.set_color("font_hover_pressed_color", c, TEXT)
	t.set_stylebox("normal", "LineEdit", box(FIELD, LINE, 4, 5, 2))
	t.set_stylebox("focus", "LineEdit", box(Color(0, 0, 0, 0), ACCENT, 4, 5, 2))
	t.set_stylebox("read_only", "LineEdit", box(FIELD.darkened(0.2), LINE, 4, 5, 2))

	var pm := box(CARD, LINE, 4, 4, 4)
	t.set_stylebox("panel", "PopupMenu", pm)
	t.set_stylebox("hover", "PopupMenu", box(ACCENT, Color(0, 0, 0, 0), 3, 4, 1))
	t.set_color("font_hover_color", "PopupMenu", INK)
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_font_size("font_size", "PopupMenu", FONT_SIZE)
	t.set_stylebox("panel", "PopupPanel", box(CARD, LINE, 6, 8, 8))
	t.set_stylebox("panel", "TooltipPanel", box(TEXT, Color(0, 0, 0, 0), 4, 6, 3))
	t.set_color("font_color", "TooltipLabel", PANEL)
	t.set_font_size("font_size", "TooltipLabel", SMALL + 1)

	# switches (CheckButton) and sliders
	t.set_icon("checked", "CheckButton", _switch_icon(true))
	t.set_icon("unchecked", "CheckButton", _switch_icon(false))
	t.set_icon("checked_disabled", "CheckButton", _switch_icon(true, true))
	t.set_icon("unchecked_disabled", "CheckButton", _switch_icon(false, true))
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		t.set_stylebox(st, "CheckButton", empty)
	var track := box(TRACK, Color(0, 0, 0, 0), 2, 0, 2)
	t.set_stylebox("slider", "HSlider", track)
	var fill := box(ACCENT, Color(0, 0, 0, 0), 2, 0, 2)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_icon("grabber", "HSlider", _dot_icon(TEXT))
	t.set_icon("grabber_highlight", "HSlider", _dot_icon(Color.WHITE))
	t.set_icon("grabber_disabled", "HSlider", _dot_icon(MUTED))

	var sb := box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 2, 0, 0)
	t.set_stylebox("scroll", "VScrollBar", sb)
	t.set_stylebox("grabber", "VScrollBar", box(LINE, Color(0, 0, 0, 0), 2, 2, 2))
	t.set_stylebox("grabber_highlight", "VScrollBar", box(MUTED, Color(0, 0, 0, 0), 2, 2, 2))
	t.set_stylebox("grabber_pressed", "VScrollBar", box(ACCENT, Color(0, 0, 0, 0), 2, 2, 2))
	t.set_stylebox("panel", "PanelContainer", box(CARD, LINE, 6, 8, 5))
	_theme = t
	return t


static func _switch_icon(on: bool, disabled := false) -> ImageTexture:
	# drawn at 3x and shown at 1/3 (the window scale makes it sharp)
	var w := 54
	var h := 30
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var bg := ACCENT if on else TRACK
	var knob := Color.WHITE if on else Color("c9d1dd")
	if disabled:
		bg = bg.darkened(0.4)
		knob = knob.darkened(0.4)
	var r := h / 2.0
	for y in h:
		for x in w:
			var cx := clampf(x + 0.5, r, w - r)
			var d := Vector2(x + 0.5 - cx, y + 0.5 - r).length()
			if d <= r:
				img.set_pixel(x, y, bg if d < r - 1 else Color(bg, r - d))
	var kx := w - r if on else r
	for y in h:
		for x in w:
			var d := Vector2(x + 0.5 - kx, y + 0.5 - r).length()
			if d <= r - 3:
				img.set_pixel(x, y, knob if d < r - 4 else Color(knob, r - 3 - d))
	img.resize(18, 10, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)


static func _dot_icon(c: Color) -> ImageTexture:
	var s := 30
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var r := s / 2.0
	for y in s:
		for x in s:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			if d <= r:
				img.set_pixel(x, y, c if d < r - 1 else Color(c, r - d))
	img.resize(10, 10, Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(img)
