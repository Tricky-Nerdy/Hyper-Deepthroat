class_name PortSettings
extends RefCounted
## Port addition (not in the original game): settings of the port itself (for now the new menu's), kept in
## port.cfg next to the save files (FlashSharedObject.save_dir, so --save-dir test runs use their own copy).

const FILE := "port.cfg"

static var _cfg: ConfigFile = null


static func get_value(section: String, key: String, default = null):
	_load()
	return _cfg.get_value(section, key) if _cfg.has_section_key(section, key) else default


static func set_value(section: String, key: String, value) -> void:
	_load()
	if _cfg.has_section_key(section, key) and _cfg.get_value(section, key) == value:
		return
	_cfg.set_value(section, key, value)
	var err := _cfg.save(FlashSharedObject.save_dir.path_join(FILE))
	if err != OK:
		push_error("port settings: cannot save %s (%s)" % [FILE, error_string(err)])


static func _load() -> void:
	if _cfg != null:
		return
	_cfg = ConfigFile.new()
	var path := FlashSharedObject.save_dir.path_join(FILE)
	if FileAccess.file_exists(path):
		_cfg.load(path)
