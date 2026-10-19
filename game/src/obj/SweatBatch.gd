class_name SweatBatch
extends FlashSprite
## Port addition: draws all native sweat droplets (SDTSweat, see Sweat.gd) on one body part. The original made a
## display object per droplet, each with its own overlay blend and screen copy; this is one node per body part, kept
## on top of the part like the droplets were, with one overlay blend for all of them.

static var _art: Array = []   # the Sweat symbol's shapes: [texture, rect, transform inside the clip]

var data := PackedFloat32Array()   # per droplet: x, y, rotation (degrees), scale x, scale y, alpha


func _init() -> void:
	mouseEnabled = false
	blendMode = "overlay"
	var m := ShaderMaterial.new()
	m.shader = Flash.SHAPE_SHADERS["screen_read"]
	m.set_shader_parameter("mode", Flash.SCREEN_BLEND_MODES["overlay"])
	material = m
	if _art.is_empty():
		_load_art()


## The Sweat symbol's pictures, from an inactive Sweat clip.
static func _load_art() -> void:
	var clip := Sweat.new()
	_collect(clip, Transform2D())
	if _art.is_empty():
		push_error("SweatBatch: no droplet art in the Sweat symbol")
	clip.free()


static func _collect(o: FlashDisplayObject, xf: Transform2D) -> void:
	if o is FlashShape and o._entry.has("img"):
		var t: Texture2D = o._library.get_texture(o._entry["img"])
		var k: float = o._library.scale
		_art.append([t, Rect2(o._entry["x"], o._entry["y"], t.get_width() / k, t.get_height() / k), xf])
	if o is FlashSprite:
		for c in o._children:
			_collect(c, xf * c.transform)


func set_drops(d: PackedFloat32Array) -> void:
	if d != data:
		data = d
		queue_redraw()


func _draw() -> void:
	for i in range(0, data.size(), 6):
		var xf := Transform2D(deg_to_rad(data[i + 2]), Vector2(data[i + 3], data[i + 4]), 0.0, Vector2(data[i], data[i + 1]))
		var c := Color(1, 1, 1, clampf(data[i + 5], 0.0, 1.0))
		for a in _art:
			draw_set_transform_matrix(xf * a[2])
			draw_texture_rect(a[0], a[1], false, c)
	draw_set_transform_matrix(Transform2D())
