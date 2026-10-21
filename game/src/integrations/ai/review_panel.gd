extends VBoxContainer
## Explicit, review-only UI. No gameplay context capture or dialogue/action-parser injection.
const Config = preload("res://src/integrations/ai/provider_config.gd")
const Client = preload("res://src/integrations/ai/provider_client.gd")
const Store = preload("res://src/integrations/ai/profile_store.gd")
const ImageReview = preload("res://src/integrations/ai/image_review.gd")

var profile_path := "user://local_ai/providers.json"
var client: Node = null # Injectable for neutral integration tests.
var enabled: CheckBox
var dialogue_url: LineEdit
var image_url: LineEdit
var model: LineEdit
var dialogue_token: LineEdit
var image_token: LineEdit
var dialogue_env: LineEdit
var image_env: LineEdit
var dialogue_lan: CheckBox
var image_lan: CheckBox
var image_provider: OptionButton
var timeout_seconds: SpinBox
var response_limit: SpinBox
var prompt: LineEdit
var workflow: TextEdit
var job_id: LineEdit
var output: TextEdit
var preview: TextureRect
var status: Label
var _busy := false
var _opened := false
var _actions: Array[Button] = []
var _dialogue_approval := ""
var _image_approval := ""
var _epoch := 0


func _ready() -> void:
	# This is hosted in SDTMenu's dock and its existing scroll container.
	process_mode = Node.PROCESS_MODE_ALWAYS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 5)
	if client == null:
		client = Client.new()
	add_child(client)
	var column: VBoxContainer = self
	var notice := Label.new()
	notice.text = "Optional worker connection. Requests send only text/workflows you enter here.\nNo automatic dialogue replacement, action execution or asset import."
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(notice)
	enabled = CheckBox.new()
	enabled.text = "Enable optional provider requests"
	column.add_child(enabled)
	timeout_seconds = _number(column, "Request timeout (seconds)", 1, 30, 10)
	response_limit = _number(column, "Maximum response/request bytes (1 KiB–16 MiB)", 1024, 16777216, 8388608)
	dialogue_url = _field(column, "LM Studio server root", "http://127.0.0.1:1234")
	model = _field(column, "Model ID (from your worker)", "")
	dialogue_token = _field(column, "Dialogue Bearer token — session only", "", true)
	dialogue_env = _field(column, "Dialogue token environment-variable name (desktop, optional)", "")
	dialogue_lan = _consent(column)
	image_provider = OptionButton.new()
	image_provider.add_item("ComfyUI")
	image_provider.add_item("AUTOMATIC1111")
	column.add_child(image_provider)
	image_url = _field(column, "Image worker server root", "http://127.0.0.1:8188")
	image_token = _field(column, "Image Bearer token — session only", "", true)
	image_env = _field(column, "Image token environment-variable name (desktop, optional)", "")
	image_lan = _consent(column)
	dialogue_lan.toggled.connect(func(approved):
		_dialogue_approval = dialogue_url.text.trim_suffix("/") if approved else ""
		client.revoke_lan_access()
		_epoch += 1)
	image_lan.toggled.connect(func(approved):
		_image_approval = image_url.text.trim_suffix("/") if approved else ""
		client.revoke_lan_access()
		_epoch += 1)
	dialogue_url.text_changed.connect(func(_value):
		dialogue_lan.button_pressed = false
		dialogue_token.text = ""
		dialogue_env.text = ""
		client.revoke_lan_access()
		client.clear_session_tokens())
	image_url.text_changed.connect(func(_value):
		image_lan.button_pressed = false
		image_token.text = ""
		image_env.text = ""
		client.revoke_lan_access()
		client.clear_session_tokens())
	_button(column, "Apply and save non-secret settings", func(): apply_settings(true))
	_button(column, "Test dialogue connection", func(): _connectivity("dialogue"))
	_button(column, "Test image connection", func(): _connectivity("images"))
	prompt = _field(column, "Text/image prompt — entered manually, no captured game context", "")
	_button(column, "Request text for review", request_text)
	var workflow_label := Label.new()
	workflow_label.text = "ComfyUI API graph JSON — use only trusted, rights-checked workflows"
	workflow_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(workflow_label)
	workflow = TextEdit.new()
	workflow.custom_minimum_size.y = 84
	column.add_child(workflow)
	_button(column, "Submit image request", request_image)
	job_id = _field(column, "ComfyUI job ID", "")
	job_id.max_length = 128
	_button(column, "Check job and preview first PNG", poll_image)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)
	output = TextEdit.new()
	output.editable = false
	output.custom_minimum_size.y = 96
	column.add_child(output)
	preview = TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(160, 160)
	column.add_child(preview)
	_button(column, "Close", close_panel, false)
	for field in [dialogue_url, image_url, model, prompt, job_id, dialogue_token, image_token, dialogue_env, image_env]:
		field.text_changed.connect(func(_text): _epoch += 1)
	workflow.text_changed.connect(func(): _epoch += 1)
	enabled.toggled.connect(func(_enabled): _epoch += 1)
	image_provider.item_selected.connect(func(_index): _epoch += 1)
	timeout_seconds.value_changed.connect(func(_value): _epoch += 1)
	response_limit.value_changed.connect(func(_value): _epoch += 1)
	var loaded := Store.load_profile(profile_path)
	var config: Dictionary = loaded.get("config", Config.defaults())
	enabled.button_pressed = config.enabled
	timeout_seconds.value = config.timeout_seconds
	response_limit.value = config.max_response_bytes
	dialogue_url.text = config.dialogue.base_url
	model.text = config.dialogue.get("model", "")
	dialogue_env.text = config.dialogue.get("api_key_env", "")
	image_url.text = config.images.base_url
	image_env.text = config.images.get("api_key_env", "")
	image_provider.select(0 if config.images.provider == "comfyui" else 1)
	status.text = "No connection made. LAN consent and tokens are never restored." if loaded.ok else "Profile rejected; optional AI disabled."
	client.configure(config)
	call_deferred("_register_with_menu")


func _register_with_menu() -> void:
	if SDTMenu.instance != null:
		SDTMenu.instance.register_external_section("local_ai", "Local AI", self)


func _field(parent: Node, label_text: String, initial: String, secret: bool = false) -> LineEdit:
	var label := Label.new()
	label.text = label_text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	var field := LineEdit.new()
	field.text = initial
	field.secret = secret
	field.max_length = 4096
	parent.add_child(field)
	return field


func _consent(parent: Node) -> CheckBox:
	var box := CheckBox.new()
	box.text = "Approve this exact LAN root for this session; HTTP is not encrypted"
	parent.add_child(box)
	return box


func _number(parent: Node, text: String, minimum: float, maximum: float, value: float) -> SpinBox:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	var field := SpinBox.new()
	field.min_value = minimum
	field.max_value = maximum
	field.step = 1
	field.value = value
	parent.add_child(field)
	return field


func _button(parent: Node, text: String, callback: Callable, action: bool = true) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	if action:
		_actions.append(button)


func open_panel() -> void:
	if SDTMenu.instance != null:
		SDTMenu.instance.open_menu("local_ai")


func close_panel() -> void:
	if SDTMenu.instance != null:
		SDTMenu.instance.close_menu()
	else:
		on_menu_closed()


func on_menu_opened() -> void:
	_opened = true


func on_menu_closed() -> void:
	if not _opened:
		return
	_epoch += 1
	dialogue_token.text = ""
	image_token.text = ""
	dialogue_lan.button_pressed = false
	image_lan.button_pressed = false
	client.clear_session_tokens()
	client.revoke_lan_access()
	_opened = false


func _exit_tree() -> void:
	on_menu_closed()


func _set_busy(value: bool) -> void:
	_busy = value
	for button in _actions:
		button.disabled = value


func _current(epoch: int) -> bool:
	if epoch == _epoch:
		return true
	_set_busy(false)
	status.text = "Settings/input changed or panel closed; previous response discarded."
	return false


func apply_settings(save: bool = false) -> bool:
	var config := Config.defaults()
	config.enabled = enabled.button_pressed
	config.timeout_seconds = timeout_seconds.value
	config.max_response_bytes = int(response_limit.value)
	config.dialogue.base_url = dialogue_url.text
	config.dialogue.model = model.text
	config.dialogue.api_key_env = dialogue_env.text
	config.images.base_url = image_url.text
	config.images.api_key_env = image_env.text
	config.images.provider = "comfyui" if image_provider.selected == 0 else "automatic1111"
	var checked: Dictionary = client.configure(config)
	if not checked.ok:
		status.text = "Settings rejected: " + checked.error
		return false
	if dialogue_lan.button_pressed and _dialogue_approval == dialogue_url.text.trim_suffix("/"):
		client.allow_lan_endpoint(dialogue_url.text)
	else:
		dialogue_lan.button_pressed = false
	if image_lan.button_pressed and _image_approval == image_url.text.trim_suffix("/"):
		client.allow_lan_endpoint(image_url.text)
	else:
		image_lan.button_pressed = false
	if not client.set_session_token("dialogue", dialogue_token.text) or not client.set_session_token("images", image_token.text):
		status.text = "Token rejected."
		return false
	if save:
		var written := Store.save_profile(profile_path, config)
		status.text = "Settings saved; no credentials or LAN grants saved." if written.ok else "Could not save settings."
	return true


func _connectivity(section: String) -> void:
	if _busy or not apply_settings():
		return
	_set_busy(true)
	var epoch := _epoch
	var result: Dictionary = await client.connectivity(section)
	if not _current(epoch):
		return
	status.text = "HTTP connectivity succeeded; model/generation readiness is not guaranteed." if result.ok else "Connection failed: " + result.error
	_set_busy(false)


func request_text() -> void:
	if _busy or not apply_settings():
		return
	_set_busy(true)
	var epoch := _epoch
	var result: Dictionary = await client.dialogue([{"role": "user", "content": prompt.text}], "")
	if not _current(epoch):
		return
	if result.ok:
		output.text = result.text # Plain text only. Never invoke the game's action-tag parser.
	status.text = "Text available for review only." if result.ok else "Existing content unchanged: " + result.error
	_set_busy(false)


func request_image() -> void:
	if _busy or not apply_settings():
		return
	var job := {"prompt": prompt.text}
	if image_provider.selected == 0:
		if workflow.text.to_utf8_buffer().size() > 131072:
			status.text = "Workflow exceeds 128 KiB."
			return
		var parser := JSON.new()
		if parser.parse(workflow.text) != OK or not parser.data is Dictionary:
			status.text = "An API-format workflow JSON object is required."
			return
		job = {"workflow": parser.data}
	_set_busy(true)
	var epoch := _epoch
	var result: Dictionary = await client.submit_image(job)
	if not _current(epoch):
		return
	if result.ok and result.get("state") == "queued":
		job_id.text = result.job_id
		status.text = "Queued. Completion and image quality are not yet verified."
	elif result.ok and result.has("image_base64"):
		_show_image(ImageReview.base64_png(result.image_base64))
	else:
		status.text = "Image request failed: " + result.get("error", "invalid_response")
	_set_busy(false)


func poll_image() -> void:
	if _busy or not apply_settings():
		return
	_set_busy(true)
	var epoch := _epoch
	var result: Dictionary = await client.image_status(job_id.text)
	if not _current(epoch):
		return
	if result.ok and result.get("state") == "review_required":
		var found := false
		for node_output in result.outputs.values():
			if not node_output is Dictionary or not node_output.get("images") is Array:
				continue
			for record in node_output.images:
				if record is Dictionary:
					var fetched: Dictionary = await client.image_preview(record)
					if not _current(epoch):
						return
					_show_image(fetched)
					found = true
					break
			if found:
				break
		if not found:
			status.text = "Job completed without a supported PNG reference."
	else:
		status.text = "Job: " + result.get("state", result.get("error", "invalid_response"))
	_set_busy(false)


func _show_image(result: Dictionary) -> void:
	if result.ok:
		preview.texture = ImageTexture.create_from_image(result.image)
		status.text = "PNG preview only. No game asset changed or file imported."
	else:
		status.text = "Image rejected: " + result.error
