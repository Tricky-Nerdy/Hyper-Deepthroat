extends RefCounted
## Local-only server roots. No DNS hosts except localhost, credentials, paths or redirects.


static func defaults() -> Dictionary:
	return {
		"enabled": false, "timeout_seconds": 10.0, "max_response_bytes": 8388608,
		"dialogue": {"provider": "lm_studio", "base_url": "http://127.0.0.1:1234", "model": ""},
		"images": {"provider": "comfyui", "base_url": "http://127.0.0.1:8188"},
	}


static func network_build_available(platform: String, network_feature: bool) -> bool:
	return platform != "Android" or network_feature


static func endpoint(url: String, lan_consent: bool = false) -> Dictionary:
	if url != url.strip_edges() or url.contains("\r") or url.contains("\n") or url.contains("\t"):
		return {"ok": false, "error": "invalid_local_endpoint"}
	var regex := RegEx.new()
	regex.compile("^(https?)://(localhost|\\[[0-9a-fA-F:]+\\]|[0-9.]+)(?::([0-9]{1,5}))?/?$")
	var found := regex.search(url)
	if found == null:
		return {"ok": false, "error": "invalid_local_endpoint"}
	var host := found.get_string(2).trim_prefix("[").trim_suffix("]").to_lower()
	var port := found.get_string(3)
	if port != "" and (int(port) < 1 or int(port) > 65535):
		return {"ok": false, "error": "invalid_port"}
	if host != "localhost" and not host.is_valid_ip_address():
		return {"ok": false, "error": "invalid_address"}
	var loopback := host in ["localhost", "::1"] or host.begins_with("127.")
	var parts := host.split(".")
	var private_v4 := parts.size() == 4 and (parts[0] == "10" or
		(parts[0] == "192" and parts[1] == "168") or
		(parts[0] == "172" and int(parts[1]) >= 16 and int(parts[1]) <= 31))
	var private_v6 := host.contains(":") and (host.begins_with("fc") or host.begins_with("fd"))
	if not loopback and not private_v4 and not private_v6:
		return {"ok": false, "error": "public_or_unsupported_address"}
	if not loopback and not lan_consent:
		return {"ok": false, "error": "lan_consent_required"}
	return {"ok": true, "url": url.trim_suffix("/"), "loopback": loopback}


static func validate(config: Dictionary) -> Dictionary:
	for key in config:
		if key not in ["enabled", "timeout_seconds", "max_response_bytes", "dialogue", "images"]:
			return {"ok": false, "error": "unknown_config_key"}
	var value := defaults()
	value.merge(config, true)
	var limit = value.max_response_bytes
	if not value.enabled is bool or not (value.timeout_seconds is float or value.timeout_seconds is int) \
		or not is_finite(float(value.timeout_seconds)) or value.timeout_seconds < 1 or value.timeout_seconds > 30 \
		or not (limit is int or limit is float) or not is_finite(float(limit)) \
		or float(limit) != floor(float(limit)) or limit < 1024 or limit > 16777216:
		return {"ok": false, "error": "invalid_limits"}
	# Godot's JSON parser represents numbers as floats, including integral byte limits.
	value.max_response_bytes = int(limit)
	for section in ["dialogue", "images"]:
		if not value[section] is Dictionary:
			return {"ok": false, "error": "invalid_provider_config"}
		var entry: Dictionary = value[section]
		for key in entry:
			if key not in ["provider", "base_url", "model", "api_key_env"]:
				return {"ok": false, "error": "unknown_provider_key"}
		if not entry.get("base_url") is String or not endpoint(entry.base_url, true).ok:
			return {"ok": false, "error": "invalid_local_endpoint"}
		if section == "dialogue" and entry.get("provider") != "lm_studio" \
			or section == "images" and entry.get("provider") not in ["comfyui", "automatic1111"]:
			return {"ok": false, "error": "unsupported_provider"}
		for key in ["model", "api_key_env"]:
			if key in entry and not entry[key] is String:
				return {"ok": false, "error": "invalid_provider_config"}
	return {"ok": true, "config": value.duplicate(true)}
