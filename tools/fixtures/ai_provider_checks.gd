extends Node
const Config = preload("res://src/integrations/ai/provider_config.gd")
const Client = preload("res://src/integrations/ai/provider_client.gd")
const Transport = preload("res://src/integrations/ai/http_transport.gd")
const Store = preload("res://src/integrations/ai/profile_store.gd")
const Review = preload("res://src/integrations/ai/image_review.gd")
const ReviewPanel = preload("res://src/integrations/ai/review_panel.gd")

class MockTransport extends Node:
	var calls := 0
	var reply: Dictionary = {"ok": false, "error": "unavailable"}
	func send(_method: int, _url: String, _headers: PackedStringArray, _payload: Dictionary, _timeout: float, _limit: int) -> Dictionary:
		calls += 1
		return reply.duplicate(true)

class DelayedTransport extends MockTransport:
	signal started
	func send(_method: int, _url: String, _headers: PackedStringArray, _payload: Dictionary, _timeout: float, _limit: int) -> Dictionary:
		calls += 1
		started.emit()
		await get_tree().create_timer(0.05).timeout
		return reply.duplicate(true)


func _ready() -> void:
	var client := Client.new()
	add_child(client)
	var mock := MockTransport.new()
	client.add_child(mock)
	client.transport = mock
	var answer: Dictionary = await client.dialogue([], "Authored fallback")
	assert(not answer.ok and answer.used_fallback and answer.text == "Authored fallback" and mock.calls == 0)
	for invalid in ["https://example.com", "http://8.8.8.8", "http://0.0.0.0:8188", "http://169.254.169.254",
		"http://user:secret@localhost", "http://localhost:0", "http://localhost:65536", "file:///tmp/socket",
		"http://localhost/path", "http://localhost?key=secret", "http://localhost#fragment", "http://localhost\n"]:
		assert(not Config.endpoint(invalid, true).ok, "unsafe root accepted")
	for valid in ["http://localhost:1234", "http://127.0.0.1", "https://[::1]:8188"]:
		assert(Config.endpoint(valid).ok)
	for lan in ["http://192.168.1.10:1234", "http://10.1.2.3", "https://172.16.0.1", "http://[fd00::1]:8188"]:
		assert(Config.endpoint(lan).error == "lan_consent_required")
		assert(Config.endpoint(lan, true).ok)
	assert(not Config.validate({"api_key": "not-a-real-key"}).ok)
	assert(not Config.validate({"timeout_seconds": 0}).ok)
	assert(not Config.validate({"timeout_seconds": NAN}).ok)
	assert(not Config.validate({"max_response_bytes": 999999999}).ok)
	assert(not Config.validate({"max_response_bytes": 1024.5}).ok)
	assert(Config.validate(JSON.parse_string(JSON.stringify(Config.defaults()))).ok)
	assert(not Config.network_build_available("Android", false))
	assert(Config.network_build_available("Android", true))
	for target in ["Linux", "Windows", "macOS", "iOS", "Web"]:
		assert(Config.network_build_available(target, false))
	var config := Config.defaults()
	config.enabled = true
	config.dialogue.base_url = "http://192.168.1.10:1234"
	config.dialogue.model = "mock-model"
	assert(client.configure(config).ok)
	assert((await client.connectivity("dialogue")).error == "lan_consent_required" and mock.calls == 0)
	assert(client.allow_lan_endpoint(config.dialogue.base_url))
	mock.reply = {"ok": true, "data": {"choices": [{"message": {"content": "Neutral reply"}}]}}
	answer = await client.dialogue([{"role": "user", "content": "Hello"}])
	assert(answer.ok and answer.text == "Neutral reply" and not answer.used_fallback)
	mock.reply = {"ok": false, "error": "unavailable"}
	answer = await client.dialogue([], "kept")
	assert(not answer.ok and answer.used_fallback and answer.text == "kept")
	mock.reply = {"ok": true, "data": {"choices": []}}
	assert((await client.dialogue([], "kept")).error == "invalid_dialogue_response")
	assert((await client.dialogue([{"role": "tool", "content": "unsupported"}], "kept")).error == "invalid_messages")
	assert(client.configure(config).ok)
	assert((await client.connectivity("dialogue")).error == "lan_consent_required")
	assert(not client.set_session_token("dialogue", "injected\r\nheader"))
	assert(not client.configure({"unknown": true}).ok)
	assert((await client.dialogue([], "kept")).text == "kept")
	client.transport = Transport.new()
	client.add_child(client.transport)
	config = Config.defaults()
	config.enabled = true
	config.timeout_seconds = 1.0
	config.max_response_bytes = 4096
	var base := OS.get_environment("SDT_AI_TEST_ENDPOINT")
	config.dialogue.base_url = base
	config.dialogue.model = "fixture"
	config.images.base_url = base
	assert(client.configure(config).ok)
	assert(client.set_session_token("dialogue", "test-only-token"))
	client.transport._busy = true
	assert((await client.connectivity("dialogue")).error == "busy")
	client.transport._busy = false
	assert((await client.connectivity("dialogue")).ok)
	client.clear_session_tokens()
	config.dialogue.api_key_env = "SDT_AI_TEST_BEARER"
	assert(client.configure(config).ok)
	assert((await client.connectivity("dialogue")).ok)
	answer = await client.dialogue([{"role": "user", "content": "Hello"}], "kept")
	assert(answer.ok and answer.text == "Loopback fixture reply")
	answer = await client.dialogue([{"role": "user", "content": "x".repeat(5000)}], "kept")
	assert(not answer.ok and answer.error == "request_too_large" and answer.text == "kept")
	for failure in ["unavailable", "badjson", "badschema", "redirect", "oversized", "slow"]:
		config.dialogue.model = failure
		assert(client.configure(config).ok)
		answer = await client.dialogue([], "kept")
		assert(not answer.ok and answer.used_fallback and answer.text == "kept", "failure did not degrade safely")
	config.dialogue.model = "fixture"
	assert(client.configure(config).ok)
	assert((await client.connectivity("images")).ok)
	assert((await client.submit_image({})).error == "workflow_required")
	var submitted: Dictionary = await client.submit_image({"workflow": {"1": {"class_type": "NeutralFixture", "inputs": {}}}})
	assert(submitted.ok and submitted.state == "queued" and submitted.job_id == "fixture-job")
	assert((await client.image_status("not-ready")).state == "pending")
	assert((await client.image_status("fixture-job")).state == "review_required")
	assert((await client.image_status("failed-job")).error == "generation_failed")
	assert((await client.image_status("../system_stats")).error == "unsupported_job")
	var downloaded: Dictionary = await client.image_preview({"filename": "neutral.png", "type": "output"})
	assert(downloaded.ok and downloaded.image.get_width() == 1 and downloaded.image.get_height() == 1)
	for filename in ["../secret.png", "/secret.png", "x.svg", "x.png?file=secret", "x\\secret.png"]:
		assert(not Review.comfy_route({"filename": filename}).ok)
	assert(not Review.comfy_route({"filename": "neutral.png", "subfolder": "../private"}).ok)
	assert(not Review.png(PackedByteArray()).ok)
	assert(not Review.base64_png("not-base64").ok)
	var huge: PackedByteArray = downloaded.image.save_png_to_buffer()
	huge[16] = 127 # Reject malicious dimensions before invoking the image decoder.
	assert(Review.png(huge).error == "image_dimensions_exceeded")
	config.images.provider = "automatic1111"
	assert(client.configure(config).ok)
	assert((await client.connectivity("images")).ok)
	submitted = await client.submit_image({"prompt": "A neutral blue square"})
	assert(submitted.ok and submitted.state == "review_required" and Review.base64_png(submitted.image_base64).ok)
	assert((await client.image_status("fixture-job")).error == "unsupported_job")
	var profile := OS.get_environment("SDT_AI_TEST_PROFILE")
	assert(Store.load_profile(profile).config.enabled == false)
	assert(not Store.save_profile(profile, {"api_key": "not-a-real-key"}).ok)
	assert(Store.save_profile(profile, config).ok)
	assert(Store.load_profile(profile).config.images.provider == "automatic1111")
	var panel := ReviewPanel.new()
	panel.profile_path = profile
	panel.client = Client.new()
	var ui_mock := MockTransport.new()
	panel.client.add_child(ui_mock)
	panel.client.transport = ui_mock
	add_child(panel)
	assert(ui_mock.calls == 0 and not panel.dialogue_lan.button_pressed)
	panel.dialogue_url.text = "http://10.1.2.3:1234"
	panel.dialogue_token.text = "ui-test-secret"
	panel.model.text = "mock-model"
	panel.enabled.button_pressed = true
	panel.on_menu_opened()
	assert(panel._opened) # The dock menu owns gameplay pause state; the review view never pauses the tree.
	await panel.request_text()
	assert(ui_mock.calls == 0) # Opening/loading a profile is not LAN approval.
	panel.dialogue_lan.button_pressed = true
	ui_mock.reply = {"ok": true, "data": {"choices": [{"message": {"content": "[UNTRUSTED_ACTION] plain text only"}}]}}
	await panel.request_text()
	assert(ui_mock.calls == 1 and panel.output.text == "[UNTRUSTED_ACTION] plain text only")
	assert(panel.apply_settings(true))
	var saved := FileAccess.get_file_as_string(profile)
	assert(not saved.contains("ui-test-secret") and not saved.contains("consent"))
	panel.dialogue_url.text = "http://10.1.2.4:1234"
	panel.dialogue_url.text_changed.emit(panel.dialogue_url.text) # Exercise the connected user-edit handler.
	assert(not panel.dialogue_lan.button_pressed and panel.dialogue_token.text == "")
	panel.on_menu_closed()
	assert(not panel._opened)
	get_tree().paused = true
	panel.open_panel()
	panel.close_panel()
	assert(get_tree().paused) # Preserve a pre-existing pause rather than forcibly resuming gameplay.
	get_tree().paused = false
	var delayed := DelayedTransport.new()
	delayed.reply = {"ok": true, "data": {"choices": [{"message": {"content": "stale reply"}}]}}
	panel.client.add_child(delayed)
	panel.client.transport = delayed
	panel.dialogue_url.text = "http://127.0.0.1:1234"
	panel.output.text = "keep existing preview"
	panel.on_menu_opened()
	panel.call_deferred("request_text")
	await delayed.started
	panel.prompt.text = "Changed request"
	panel.prompt.text_changed.emit(panel.prompt.text)
	await get_tree().create_timer(0.12).timeout
	assert(panel.output.text == "keep existing preview" and not panel._busy)
	panel.on_menu_closed()
	var broken := FileAccess.open(profile, FileAccess.WRITE)
	broken.store_string("{broken")
	broken.close()
	assert(not Store.load_profile(profile).ok)
	print("AI_PROVIDER_CHECKS_OK")
	get_tree().quit(0)
