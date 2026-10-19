extends CanvasLayer
## Frames-per-second overlay (not part of the original game). F3 toggles it.

const INTERVAL_US := 250000   # the frame rate over the last quarter second (Godot's own value changes once a second)

var _label := Label.new()
var _start := 0
var _frames := 0


func _ready() -> void:
	layer = 100
	_label.position = Vector2(6, 4)
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_label.add_theme_constant_override("outline_size", 4)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	_label.text = "%d fps" % Engine.get_frames_per_second()
	_start = Time.get_ticks_usec()


func _process(_delta: float) -> void:
	_frames += 1
	var now := Time.get_ticks_usec()
	if now - _start >= INTERVAL_US:
		_label.text = "%d fps" % roundi(_frames * 1000000.0 / (now - _start))
		_frames = 0
		_start = now


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible
