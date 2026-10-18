extends RefCounted
## Atomic replacement on a single filesystem. Callers choose a writable app-private path.


static func save_file(path: String, value: Dictionary) -> Error:
	var temp := path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(value, "\t", true))
	file.flush()
	var result := file.get_error()
	file.close()
	if result != OK:
		return result
	return DirAccess.rename_absolute(temp, path)


static func read_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "cannot_open"}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return {"ok": false, "error": "invalid_json"}
	return {"ok": true, "value": parser.data}
