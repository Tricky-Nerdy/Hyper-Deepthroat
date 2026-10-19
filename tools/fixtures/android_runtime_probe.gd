extends Node
## Read-only DEBUG-preview observer, installed only in the copied export stage.
## No input injection, dialogue, content creation, network access or save mutation.

var _elapsed := 0.0
var _next_sample := 1.0


func _ready() -> void:
	_sample("autoload_ready")


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= _next_sample:
		_sample("frame_sample")
		_next_sample = _elapsed + 10.0


func _sample(phase: String) -> void:
	var features := {}
	for tag in ["android", "arm64", "x86_64", "debug", "release", "template_debug", "template_release"]:
		features[tag] = OS.has_feature(tag)
	var scene := get_tree().current_scene
	var flash := get_node_or_null("/root/Flash")
	var stage: Node = flash.get("stage") if flash != null else null
	var record := {
		"phase": phase,
		"features": features,
		"main_scene": scene.scene_file_path if scene != null else "",
		"main_ready": scene != null and scene.is_node_ready(),
		"scene_children": scene.get_child_count() if scene != null else 0,
		"flash_stage_children": stage.get_child_count() if stage != null else 0,
		"sdt_native_class": ClassDB.class_exists("SDTNative"),
		"swf_file_class": ClassDB.class_exists("SWFFile"),
		"extensions": GDExtensionManager.get_loaded_extensions(),
		"process_frames": Engine.get_process_frames(),
		"drawn_frames": Engine.get_frames_drawn(),
		"fps": Engine.get_frames_per_second(),
		"elapsed_seconds": snappedf(_elapsed, 0.01),
	}
	print("SDT_RUNTIME_PROBE ", JSON.stringify(record))
