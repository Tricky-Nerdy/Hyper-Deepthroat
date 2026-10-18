extends Control
## Standalone neutral demonstration, staged with the same loader core used by the game.

const Commands = preload("core/asset_commands.gd")
const Story = preload("core/story_runtime.gd")
const Storage = preload("core/atomic_json.gd")
const Manifest = preload("core/package_manifest.gd")
const Capabilities = preload("core/runtime_capabilities.gd")

var commands := Commands.new()
var story := Story.new()
var _request: LineEdit
var _status: Label
var _preview: PanelContainer
var _selection: Label
var _line: Label
var _choices: VBoxContainer
var _next: Button
var _picker: FileDialog


func _ready() -> void:
	for asset in JSON.parse_string(FileAccess.get_file_as_string("res://fixtures/assets.json")):
		commands.register_asset(asset)
	story.load_document(JSON.parse_string(FileAccess.get_file_as_string("res://fixtures/arrival.json")))
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var scroll := ScrollContainer.new()
	margin.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	scroll.add_child(column)
	_label(column, "Portable Mod Workbench · 0.1.0", 25)
	_label(column, "Neutral assets · typed configuration · branching dialogue · package inspection", 14)
	_request = LineEdit.new()
	_request.placeholder_text = "wear Blue Jacket; background Station"
	_request.text = "wear Blue Jacket; background Station"
	_request.custom_minimum_size.y = 44
	_request.text_submitted.connect(func(_text): _apply())
	column.add_child(_request)
	var actions := HFlowContainer.new()
	column.add_child(actions)
	_button(actions, "Apply", _apply)
	_button(actions, "Undo", func(): commands.undo(); _refresh())
	_button(actions, "Save", _save)
	_button(actions, "Load", _load_save)
	_button(actions, "Inspect plugin.cfg", func(): _picker.popup_centered_ratio())
	_button(actions, "Licenses", _licenses)
	_preview = PanelContainer.new()
	_preview.custom_minimum_size.y = 80
	column.add_child(_preview)
	_selection = _label(_preview, "No asset selected", 20)
	_line = _label(column, "", 19)
	_choices = VBoxContainer.new()
	column.add_child(_choices)
	_next = _button(column, "Continue", func(): story.advance(); _refresh())
	_status = _label(column, "Commands use exact asset names. Separate multiple requests with semicolons.", 14)
	_label(column, JSON.stringify(Capabilities.report(), "  "), 12)
	_picker = FileDialog.new()
	_picker.access = FileDialog.ACCESS_FILESYSTEM
	_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_picker.filters = PackedStringArray(["*.cfg ; Plugin manifest"])
	_picker.use_native_dialog = not OS.has_feature("web")
	_picker.file_selected.connect(_inspect)
	add_child(_picker)
	_refresh()
	# Used by portable_release.py smoke: verifies scene construction without game assets.
	if "--smoke" in OS.get_cmdline_user_args():
		_apply()
		await get_tree().process_frame
		print("WORKBENCH SMOKE: ready")
		get_tree().quit()


func _label(parent: Node, text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 44
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _apply() -> void:
	var proposal := commands.propose(_request.text)
	var result: Dictionary = commands.apply(proposal.commands) if proposal.ok else proposal
	_status.text = JSON.stringify(result)
	_refresh()


func _refresh() -> void:
	_selection.text = JSON.stringify(commands.state.slots)
	var style := StyleBoxFlat.new()
	var background: String = commands.state.slots.get("background", "")
	style.bg_color = Color(commands.assets.get(background, {}).get("color", "273952"))
	style.content_margin_left = 12
	style.content_margin_right = 12
	_preview.add_theme_stylebox_override("panel", style)
	for child in _choices.get_children():
		_choices.remove_child(child)
		child.queue_free()
	var n := story.current()
	_next.visible = n.type == "say"
	_line.text = "%s: %s" % [n.get("speaker", ""), n.get("text", "Choose a route." if n.type == "choice" else "Scene complete.")]
	if n.type == "choice":
		for i in n.choices.size():
			_button(_choices, n.choices[i].text, func(): story.choose(i); _refresh())


func _save() -> void:
	var result := Storage.save_file("user://workbench.json", {"schema": 1,
		"assets": commands.state, "story": story.snapshot()})
	_status.text = "Saved locally." if result == OK else "Save failed: %s" % error_string(result)


func _load_save() -> void:
	var saved := Storage.read_file("user://workbench.json")
	if not saved.ok:
		_status.text = JSON.stringify(saved)
		return
	var value: Dictionary = saved.value
	if value.get("schema") != 1 or not value.get("assets") is Dictionary or not value.get("story") is Dictionary:
		_status.text = "Invalid workbench save."
		return
	# Validate both components in temporary runtimes before changing either live component.
	var candidate := Commands.new()
	candidate.assets = commands.assets.duplicate(true)
	var candidate_story := Story.new()
	candidate_story.load_document(story.document)
	var asset_result := candidate.restore(value.assets)
	var story_result := candidate_story.restore(value.story)
	if not asset_result.ok or not story_result.ok:
		_status.text = "Incompatible save: %s / %s" % [asset_result, story_result]
		return
	commands = candidate
	story = candidate_story
	_status.text = "Restored. Unresolved assets: %s" % [asset_result.unresolved]
	_refresh()


func _inspect(path: String) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		_status.text = "Could not read manifest."
		return
	var result := Manifest.normalize(cfg, path.get_base_dir().get_file())
	_status.text = "Manifest inspection (no script execution): " + JSON.stringify(result)


func _licenses() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Code and engine notices"
	var text := TextEdit.new()
	text.editable = false
	text.custom_minimum_size = Vector2(440, 320)
	text.text = FileAccess.get_file_as_string("res://LICENSE.txt") + "\n\n" + Engine.get_license_text() \
		+ "\n\n" + JSON.stringify(Engine.get_copyright_info(), "\t") \
		+ "\n\n" + JSON.stringify(Engine.get_license_info(), "\t")
	dialog.add_child(text)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.85)
