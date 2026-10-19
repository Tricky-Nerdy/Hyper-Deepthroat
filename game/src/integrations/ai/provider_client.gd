extends Node
## Opt-in provider API. Not an autoload; never edits game state or imports generated assets.
const Config = preload("res://src/integrations/ai/provider_config.gd")
const Transport = preload("res://src/integrations/ai/http_transport.gd")
const ImageReview = preload("res://src/integrations/ai/image_review.gd")

var transport: Node = null # May be replaced by a mock implementing send().
var _config: Dictionary = Config.defaults()
var _consents: Dictionary = {}
var _tokens: Dictionary = {}


func configure(value: Dictionary) -> Dictionary:
	_consents.clear()
	_tokens.clear()
	_config = Config.defaults() # Invalid reconfiguration fails closed.
	var result := Config.validate(value)
	if result.ok:
		_config = result.config
	return {"ok": result.ok, "error": result.get("error", "")}


## Call only after an explicit user action approving transmission to this exact server root.
## Consent is session-only and is revoked on reconfiguration. Config files cannot grant consent.
func allow_lan_endpoint(url: String) -> bool:
	var checked := Config.endpoint(url, true)
	if not checked.ok:
		return false
	_consents[checked.url] = true
	return true


func set_session_token(section: String, token: String) -> bool:
	if section not in ["dialogue", "images"] or token.contains("\r") or token.contains("\n"):
		return false
	_tokens[section] = token
	return true


func clear_session_tokens() -> void:
	_tokens.clear()


func revoke_lan_access() -> void:
	_consents.clear()


func _call(section: String, route: String, method: int = HTTPClient.METHOD_GET, payload: Dictionary = {}, binary: bool = false) -> Dictionary:
	if not _config.enabled:
		return {"ok": false, "error": "disabled"}
	if not Config.network_build_available(OS.get_name(), OS.has_feature("local_ai_network")):
		return {"ok": false, "error": "network_disabled_in_build"}
	var provider: Dictionary = _config[section]
	var root: String = provider.base_url.trim_suffix("/")
	var endpoint := Config.endpoint(root, _consents.has(root))
	if not endpoint.ok:
		return endpoint
	var token: String = _tokens.get(section, "")
	if token == "" and provider.get("api_key_env", "") != "":
		token = OS.get_environment(provider.api_key_env)
	if token.contains("\r") or token.contains("\n"):
		return {"ok": false, "error": "invalid_token"}
	var headers := PackedStringArray(["Content-Type: application/json"])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	if transport == null:
		transport = Transport.new()
		add_child(transport)
	if binary:
		if not transport.has_method("send_binary"):
			return {"ok": false, "error": "binary_transport_unavailable"}
		return await transport.send_binary(method, root + route, headers, payload,
			float(_config.timeout_seconds), mini(int(_config.max_response_bytes), ImageReview.MAX_BYTES))
	return await transport.send(method, root + route, headers, payload,
		float(_config.timeout_seconds), int(_config.max_response_bytes))


func connectivity(section: String) -> Dictionary:
	if section not in ["dialogue", "images"]:
		return {"ok": false, "error": "unsupported_section"}
	var route := "/v1/models" if section == "dialogue" else (
		"/system_stats" if _config.images.provider == "comfyui" else "/sdapi/v1/options")
	return await _call(section, route)


func dialogue(messages: Array, fallback_text: String = "") -> Dictionary:
	if _config.enabled and _config.dialogue.get("model", "").strip_edges() == "":
		return {"ok": false, "error": "model_required", "text": fallback_text, "used_fallback": true}
	for message in messages:
		if not message is Dictionary or message.get("role") not in ["system", "user", "assistant"] \
			or not message.get("content") is String:
			return {"ok": false, "error": "invalid_messages", "text": fallback_text, "used_fallback": true}
	var result := await _call("dialogue", "/v1/chat/completions", HTTPClient.METHOD_POST,
		{"model": _config.dialogue.get("model", ""), "messages": messages, "stream": false, "max_tokens": 256})
	if result.ok:
		var choices = result.data.get("choices")
		if choices is Array and not choices.is_empty() and choices[0] is Dictionary:
			var message = choices[0].get("message")
			if message is Dictionary and message.get("content") is String:
				return {"ok": true, "text": message.content, "used_fallback": false}
		result = {"ok": false, "error": "invalid_dialogue_response"}
	result["text"] = fallback_text
	result["used_fallback"] = true
	return result


## ComfyUI accepts a user-supplied API-format graph, not a copied/bundled workflow.
## Submission is asynchronous: a prompt ID is not proof of a finished image.
func submit_image(job: Dictionary) -> Dictionary:
	if _config.images.provider == "comfyui":
		if not job.get("workflow") is Dictionary or job.workflow.is_empty():
			return {"ok": false, "error": "workflow_required"}
		var result := await _call("images", "/prompt", HTTPClient.METHOD_POST, {"prompt": job.workflow})
		if result.ok and result.data.get("prompt_id") is String and result.data.prompt_id != "":
			return {"ok": true, "state": "queued", "job_id": result.data.prompt_id}
		return result if not result.ok else {"ok": false, "error": "invalid_job_response"}
	if not job.get("prompt") is String or job.prompt.length() > 4096:
		return {"ok": false, "error": "invalid_image_prompt"}
	var result := await _call("images", "/sdapi/v1/txt2img", HTTPClient.METHOD_POST,
		{"prompt": job.prompt, "steps": 12, "width": 512, "height": 512, "batch_size": 1, "n_iter": 1})
	if result.ok and result.data.get("images") is Array and not result.data.images.is_empty() \
		and result.data.images[0] is String:
		return {"ok": true, "state": "review_required", "image_base64": result.data.images[0]}
	return result if not result.ok else {"ok": false, "error": "invalid_image_response"}


func image_status(job_id: String) -> Dictionary:
	if _config.images.provider != "comfyui" or job_id == "" or job_id.length() > 128:
		return {"ok": false, "error": "unsupported_job"}
	var id_pattern := RegEx.new()
	id_pattern.compile("^[A-Za-z0-9_-]+$")
	if id_pattern.search(job_id) == null:
		return {"ok": false, "error": "unsupported_job"}
	var result := await _call("images", "/history/" + job_id.uri_encode())
	if not result.ok:
		return result
	var entry = result.data.get(job_id)
	if entry == null:
		return {"ok": true, "state": "pending"}
	if not entry is Dictionary:
		return {"ok": false, "error": "invalid_job_response"}
	var status = entry.get("status", {})
	if not status is Dictionary:
		return {"ok": false, "error": "invalid_job_response"}
	if status.get("status_str") == "error":
		return {"ok": false, "error": "generation_failed"}
	if not status.get("completed", false) is bool:
		return {"ok": false, "error": "invalid_job_response"}
	if not status.get("completed", false):
		return {"ok": true, "state": "pending"}
	var outputs = entry.get("outputs", {})
	if not outputs is Dictionary:
		return {"ok": false, "error": "invalid_job_response"}
	return {"ok": true, "state": "review_required", "outputs": outputs}


func image_preview(record: Dictionary) -> Dictionary:
	if _config.images.provider != "comfyui":
		return {"ok": false, "error": "unsupported_provider"}
	var checked := ImageReview.comfy_route(record)
	if not checked.ok:
		return checked
	var fetched := await _call("images", checked.route, HTTPClient.METHOD_GET, {}, true)
	return ImageReview.png(fetched.bytes) if fetched.ok else fetched
