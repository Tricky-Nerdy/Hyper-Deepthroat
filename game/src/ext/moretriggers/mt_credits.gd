extends RefCounted
## MoreTriggers' [SHOW_CREDITS]: text areas rolling up the window, set up in the character's credits-settings.txt
## (same keys and defaults as the mod, see its credits-settings.txt), with an optional background (credits-bg.png),
## a logo that first moves in depth, fading, and a tilt of the text plane in perspective (applyXRotation +
## applyPerspFieldOfView, e.g. a Star Wars style crawl). roll() runs once per tick and returns true when done.
##
## Port: the text is laid out by Godot (RichTextLabel, <b> <i> <u> <br> of the mod's htmlText) in an off-screen
## viewport and drawn through credits_plane.gdshader, which does the tilt; fonts are the system's by name, "_sans"
## the game's default font, and the mod's SWCrawlTitle / SWCrawlBody.

const PLANE_SHADER := preload("res://src/ext/moretriggers/credits_plane.gdshader")
const FONT_DIR := "res://assets/mods/moretriggers/"
const STAGE := Vector2(700, 600)
const PROJECTION_CENTER := Vector2(400, 300)   # the mod's
const LOGO_CENTER := Vector2(350, 300)          # Flash's default projection: the window centre, 55 degrees
const LOGO_FOV := 55.0
const MAX_PLANE := 4096.0

const DEFAULTS := {"creditsSpeed": "5", "applyXRotation": "0", "applyPerspFieldOfView": "0", "nbTextareas": "1",
	"textActionsThreshold": "bottom", "creditsEndAtY": "-100", "makeTextFadeOut": "0", "textFadesOutAtY": "0",
	"beforeCreditsLogoFileName": "noImage", "beforeCreditsLogoStartingX": "250", "beforeCreditsLogoStartingY": "350",
	"beforeCreditsLogoStartingZ": "0", "beforeCreditsLogoMoveEndsAtZ": "0", "makeBeforeCreditsLogoFadeOut": "0",
	"beforeCreditsLogoFadesOutAtZ": "0", "beforeCreditsLogoSpeed": "0"}
const AREA_DEFAULTS := {"StartingX": "100", "RelativeY": "700", "Width": "500", "Align": "center", "Color": "000000",
	"FontName": "_sans", "FontSize": "30", "Text": "Default Text"}

var root := FlashSprite.new()
var _plane: TextPlane = null
var _vp: SubViewport = null
var _areas: Array = []       # {"label", "y", "rel"}
var _laid_out := false
var _s: Dictionary
var _frame := 0
var _speed := 1
var _wait := 1
var _fade := false
var _fade_at := 0
var _end_at := -100
var _threshold := "bottom"
# logo
var _logo: FlashLoader = null
var _logo_pos := Vector3()
var _logo_done := true
var _logo_speed := 0
var _logo_end_z := 0
var _logo_fade := false
var _logo_fade_z := 0
var _logo_focal := 0.0


func _init(screen, settings: Dictionary) -> void:
	_s = DEFAULTS.duplicate()
	_s.merge(settings, true)
	root.mouseEnabled = false
	root.mouseChildren = false
	var speed := clampi(_int("creditsSpeed"), 1, 9)
	if speed < 5:
		_speed = 1
		_wait = 6 - speed
	else:
		_speed = speed % 5 + 1
		_wait = 1
	_fade = _s["makeTextFadeOut"] == "1"
	_fade_at = _int("textFadesOutAtY")
	_end_at = _int("creditsEndAtY")
	_threshold = _s["textActionsThreshold"]
	var bg_path: String = screen.path("credits-bg.png")
	if FileAccess.file_exists(bg_path):
		var bg := FlashLoader.new()
		bg.load(bg_path)
		root.addChild(bg)
	_build_plane()
	var logo_file: String = _s["beforeCreditsLogoFileName"]
	if logo_file != "noImage" and logo_file != "":
		_logo = FlashLoader.new()
		var p: String = screen.path(logo_file)
		if FileAccess.file_exists(p):
			_logo.load(p)
		_logo_pos = Vector3(_int("beforeCreditsLogoStartingX"), _int("beforeCreditsLogoStartingY"),
			_int("beforeCreditsLogoStartingZ"))
		_logo_speed = _int("beforeCreditsLogoSpeed")
		_logo_end_z = _int("beforeCreditsLogoMoveEndsAtZ")
		_logo_fade = _s["makeBeforeCreditsLogoFadeOut"] == "1"
		_logo_fade_z = _int("beforeCreditsLogoFadesOutAtZ")
		_logo_focal = STAGE.x / 2.0 / tan(deg_to_rad(LOGO_FOV) / 2.0)
		_logo_done = false
		root.addChild(_logo)
		_place_logo()


func _int(key: String) -> int:
	return int(AS3.Number(_s.get(key, "0")))


# ---------------------------------------------------------------- the text plane

class TextPlane:
	extends FlashSprite
	var texture: Texture2D

	func _draw() -> void:
		if texture != null:
			draw_texture_rect(texture, Rect2(Vector2.ZERO, STAGE), false)


func _build_plane() -> void:
	var angle := deg_to_rad(float(_int("applyXRotation")))
	var fov := float(_int("applyPerspFieldOfView"))
	if angle == 0.0 or fov <= 0.0:
		angle = 0.0
		fov = 55.0
	var focal := STAGE.x / 2.0 / tan(deg_to_rad(clampf(fov, 1.0, 179.0)) / 2.0)
	# the part of the plane the window shows
	var c := cos(angle)
	var sn := sin(angle)
	var ys: Array = []
	for sy in [0.0, STAGE.y]:
		var den: float = c * focal - (sy - PROJECTION_CENTER.y) * sn
		ys.append(sy * focal / den if den > 1e-3 else NAN)
	var y0: float = ys[0] if not is_nan(ys[0]) else ys[1] - MAX_PLANE
	var y1: float = ys[1] if not is_nan(ys[1]) else y0 + MAX_PLANE
	y1 = minf(y1, y0 + MAX_PLANE)
	var k := maxf(1.0, maxf((focal + y0 * sn) / focal, (focal + y1 * sn) / focal))
	k = minf(k, MAX_PLANE / STAGE.x)
	var x0 := PROJECTION_CENTER.x - PROJECTION_CENTER.x * k
	var x1 := PROJECTION_CENTER.x + (STAGE.x - PROJECTION_CENTER.x) * k
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.size = Vector2i(ceili(x1 - x0), ceili(y1 - y0))
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	Flash.add_child(_vp)
	_vp.canvas_transform = Transform2D(0.0, Vector2(-x0, -y0))   # once it has its canvas (in the tree)
	var n := maxi(1, _int("nbTextareas"))
	for i in range(1, n + 1):
		_areas.append(_text_area(i))
	_plane = TextPlane.new()
	_plane.mouseEnabled = false
	_plane.texture = _vp.get_texture()
	var m := ShaderMaterial.new()
	m.shader = PLANE_SHADER
	m.set_shader_parameter("stage", STAGE)
	m.set_shader_parameter("center", PROJECTION_CENTER)
	m.set_shader_parameter("focal", focal)
	m.set_shader_parameter("angle", angle)
	m.set_shader_parameter("plane_origin", Vector2(x0, y0))
	m.set_shader_parameter("plane_size", Vector2(_vp.size))
	_plane.material = m
	root.addChild(_plane)


func _text_area(i: int) -> Dictionary:
	var key := "textarea%d" % i
	var a := {}
	for k in AREA_DEFAULTS:
		a[k] = str(_s.get(key + k, AREA_DEFAULTS[k]))
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.position = Vector2(AS3.Number(a["StartingX"]), 0)
	l.size = Vector2(AS3.Number(a["Width"]), 1)
	var font := _font(a["FontName"])
	var bold := FontVariation.new()
	bold.base_font = font
	bold.variation_embolden = 0.8
	var italic := FontVariation.new()
	italic.base_font = font
	italic.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	var size := int(AS3.Number(a["FontSize"]))
	for f in ["normal", "bold", "italics", "bold_italics"]:
		l.add_theme_font_size_override(f + "_font_size", size)
	l.add_theme_font_override("normal_font", font)
	l.add_theme_font_override("bold_font", bold)
	l.add_theme_font_override("italics_font", italic)
	l.add_theme_color_override("default_color", Color.hex(((("0x" + a["Color"]).hex_to_int()) << 8) | 0xFF))
	var align: String = {"center": "center", "right": "right", "justify": "fill"}.get(a["Align"], "")
	var text := html_to_bbcode(a["Text"])
	l.text = text if align == "" else "[%s]%s[/%s]" % [align, text, align]
	_vp.add_child(l)
	return {"label": l, "y": 0.0, "rel": AS3.Number(a["RelativeY"])}


func _font(name: String) -> Font:
	if name == "_sans" or name == "":
		return ThemeDB.fallback_font
	if name == "SWCrawlTitle" or name == "SWCrawlBody":
		var f = load(FONT_DIR + name + ".ttf")
		if f is Font:
			return f
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray([name])
	sf.fallbacks = [ThemeDB.fallback_font]
	return sf


## The mod's htmlText (<b> <i> <u> <br>, entities) as BBCode.
static func html_to_bbcode(html: String) -> String:
	var t := html.replace("[", "[lb]")
	var re := RegEx.create_from_string("(?i)<br\\s*/?>")
	t = re.sub(t, "\n", true)
	for tag in ["b", "i", "u"]:
		t = RegEx.create_from_string("(?i)<%s>" % tag).sub(t, "[%s]" % tag, true)
		t = RegEx.create_from_string("(?i)</%s>" % tag).sub(t, "[/%s]" % tag, true)
	t = RegEx.create_from_string("<[^>]*>").sub(t, "", true)
	return t.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'") \
		.replace("&nbsp;", " ").replace("&amp;", "&")


## Stacks the text areas once they are laid out: the first at its RelativeY, each next one RelativeY below the
## previous one.
func _layout() -> void:
	var y := 0.0
	for i in _areas.size():
		var a: Dictionary = _areas[i]
		y = a["rel"] if i == 0 else y + _height(_areas[i - 1]) + a["rel"]
		a["y"] = y
		a["label"].position.y = y
	_laid_out = true


func _height(a: Dictionary) -> float:
	return a["label"].get_content_height() + 4.0


# ---------------------------------------------------------------- every tick

func _place_logo() -> void:
	var k := _logo_focal / maxf(1.0, _logo_focal + _logo_pos.z)
	var p := LOGO_CENTER + (Vector2(_logo_pos.x, _logo_pos.y) - LOGO_CENTER) * k
	_logo.x = p.x
	_logo.y = p.y
	_logo.scaleX = k
	_logo.scaleY = k


## One tick; true when the last text area passed creditsEndAtY.
func roll() -> bool:
	if not _laid_out:
		_layout()
	_frame += 1
	if not _logo_done:
		if _logo_fade and _logo_pos.z >= _logo_fade_z and _logo.alpha > 0:
			_logo.alpha -= 0.01
		if (_logo_speed > 0 and _logo_pos.z <= _logo_end_z) or (_logo_speed < 0 and _logo_pos.z >= _logo_end_z):
			_logo_pos.z += _logo_speed
			_place_logo()
		else:
			_logo_done = true
		return false
	if _frame % _wait != 0:
		return false
	if _logo != null:
		_logo_pos.y -= _speed
		_place_logo()
	var at := 0.0
	for a in _areas:
		a["y"] -= _speed
		var l: RichTextLabel = a["label"]
		l.position.y = a["y"]
		var h := _height(a)
		at = a["y"] + h
		if _threshold == "center":
			at = a["y"] + h / 2.0
		elif _threshold == "top":
			at = a["y"]
		if _fade and at <= _fade_at and l.modulate.a > 0:
			l.modulate.a -= 0.01
	return at <= _end_at


func clear() -> void:
	if root._flash_parent != null:
		root._flash_parent.removeChild(root)
	if _vp != null and is_instance_valid(_vp):
		_vp.queue_free()
	_vp = null
