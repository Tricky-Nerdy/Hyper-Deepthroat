extends Node
## Fixture-only observer. Reads UI/state and captures its own viewport; never invokes action handlers.

var root: Control
var evidence := ""
var session := ""
var elapsed := 0.0
var connected := false
var actions: Array = []
var inputs: Array = []
var input_count := 0
var last_capture := ""
var capturing := false


func _ready() -> void:
	root = get_parent()
	evidence = OS.get_environment("NEUTRAL_GUI_EVIDENCE")
	session = OS.get_environment("NEUTRAL_GUI_SESSION")
	DisplayServer.window_set_title("Neutral GUI Workbench " + str(OS.get_process_id()))


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		input_count += 1
		inputs.append({"key": OS.get_keycode_string(event.keycode), "pressed": event.pressed,
			"ctrl": event.ctrl_pressed, "shift": event.shift_pressed, "meta": event.meta_pressed,
			"echo": event.echo, "unicode": event.unicode})
		if inputs.size() > 64:
			inputs.pop_front()


func _pressed(label: String) -> void:
	actions.append({"button": label, "frame": Engine.get_process_frames(), "input_count": input_count})


func _process(delta: float) -> void:
	if root._request == null:
		return
	if not connected:
		for button in root.find_children("*", "Button", true, false):
			button.pressed.connect(_pressed.bind(button.text))
		connected = true
	elapsed += delta
	if elapsed < 0.05:
		return
	elapsed = 0.0
	_snapshot()
	var request := evidence.path_join("capture-request.json")
	if not capturing and FileAccess.file_exists(request):
		var capture = JSON.parse_string(FileAccess.get_file_as_string(request))
		if capture is Dictionary and capture.get("session") == session and capture.get("name") is String:
			var name_: String = capture.name
			if RegEx.create_from_string("^[a-z0-9_-]+$").search(name_) != null:
				capturing = true
				DirAccess.remove_absolute(request)
				await RenderingServer.frame_post_draw
				var result := get_viewport().get_texture().get_image().save_png(evidence.path_join(name_ + ".png"))
				last_capture = name_ if result == OK else "failed"
				capturing = false
				_snapshot()


func _snapshot() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	var focus_name := ""
	if focus == root._request:
		focus_name = "request"
	elif focus is Button:
		focus_name = focus.text
	var size_ := get_viewport().get_visible_rect().size
	var data := {"schema": 1, "pid": OS.get_process_id(), "session": session,
		"headless": DisplayServer.get_name() == "headless", "focus": focus_name,
		"request": root._request.text, "selection": root.commands.state.duplicate(true),
		"story": root.story.snapshot(), "undo_count": root.commands._undo.size(),
		"status": root._status.text, "selection_label": root._selection.text,
		"save_path": OS.get_user_data_dir().path_join("workbench.json"),
		"action_count": actions.size(), "actions": actions.duplicate(true),
		"input_count": input_count, "inputs": inputs.duplicate(true),
		"last_capture": last_capture, "viewport_size": [size_.x, size_.y]}
	var path := evidence.path_join("snapshot-" + session + ".json")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		push_error("Could not write neutral GUI observation")
		return
	file.store_string(JSON.stringify(data))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)
