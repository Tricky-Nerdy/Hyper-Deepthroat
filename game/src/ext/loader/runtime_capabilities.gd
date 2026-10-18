extends RefCounted
## Capability reporting must not confuse native acceleration with SWF conversion support.


static func report() -> Dictionary:
	var swf := ClassDB.class_exists(&"SWFFile")
	return {"schema": 1, "loader_api": 1, "platform": OS.get_name(),
		"engine": Engine.get_version_info().string,
		"capabilities": ["package_manifest_v1", "typed_commands_v1", "story_v1", "owned_slots_v1"] \
			+ (["swf_conversion"] if swf else []) \
			+ (["native_acceleration"] if ClassDB.class_exists(&"SDTNative") else []),
		"swf_conversion": swf, "native_acceleration": ClassDB.class_exists(&"SDTNative"),
		"legacy_template_compatibility": "unverified", "pixel_perfect": "unverified"}
