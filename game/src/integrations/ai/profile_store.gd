extends RefCounted
## Only validated non-secret configuration is persisted. Consent and tokens are session state.
const Config = preload("res://src/integrations/ai/provider_config.gd")
const Atomic = preload("res://src/ext/loader/atomic_json.gd")
const MAX_PROFILE_BYTES := 16384


static func load_profile(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "config": Config.defaults(), "missing": true}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "profile_unreadable"}
	if file.get_length() > MAX_PROFILE_BYTES:
		return {"ok": false, "error": "profile_too_large"}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "invalid_profile"}
	return Config.validate(parser.data)


static func save_profile(path: String, config: Dictionary) -> Dictionary:
	var validated := Config.validate(config)
	if not validated.ok:
		return validated
	if JSON.stringify(validated.config).to_utf8_buffer().size() > MAX_PROFILE_BYTES:
		return {"ok": false, "error": "profile_too_large"}
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		return {"ok": false, "error": "profile_directory_failed"}
	if Atomic.save_file(path, validated.config) != OK:
		return {"ok": false, "error": "profile_write_failed"}
	return {"ok": true}
