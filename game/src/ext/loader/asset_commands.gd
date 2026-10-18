extends RefCounted
## Declarative asset selection. Natural-language helpers propose commands; they never execute code.

var assets: Dictionary = {}
var state: Dictionary = {"schema": 1, "slots": {}}
var _undo: Array = []
const HISTORY_LIMIT := 32
const KINDS := ["background", "costume", "portrait"]


func register_asset(asset: Dictionary) -> Dictionary:
	for key in ["id", "name", "kind", "slot"]:
		if not asset.get(key) is String or asset[key].is_empty():
			return {"ok": false, "error": "invalid_asset_%s" % key}
	if not asset.kind in KINDS or assets.has(asset.id):
		return {"ok": false, "error": "invalid_kind_or_duplicate_id"}
	assets[asset.id] = asset.duplicate(true)
	return {"ok": true}


func propose(text: String) -> Dictionary:
	var commands: Array = []
	for phrase in text.split(";", false):
		var term := phrase.strip_edges()
		var found := RegEx.create_from_string("(?i)^(use|select|wear|background|costume|portrait)\\s+(.+)$").search(term)
		if found == null:
			return {"ok": false, "error": "unsupported_request", "request": term}
		var verb := found.get_string(1).to_lower()
		var name := found.get_string(2).strip_edges()
		if name.to_lower().begins_with("the "):
			name = name.substr(4)
		var kind := verb if verb in KINDS else ("costume" if verb == "wear" else "")
		var matches: Array = []
		for asset in assets.values():
			if (kind == "" or asset.kind == kind) and (asset.name.nocasecmp_to(name) == 0 or asset.id == name):
				matches.append(asset.id)
		matches.sort()
		if matches.size() != 1:
			return {"ok": false, "error": "missing_asset" if matches.is_empty() else "ambiguous_asset",
				"request": name, "candidates": matches}
		commands.append({"op": "select", "asset_id": matches[0]})
	if commands.is_empty():
		return {"ok": false, "error": "empty_request"}
	return {"ok": true, "commands": commands}


func apply(commands: Array) -> Dictionary:
	if commands.is_empty():
		return {"ok": false, "error": "empty_commands"}
	var next := state.duplicate(true)
	var changes: Array = []
	for command in commands:
		if not command is Dictionary or command.get("op") != "select" or not assets.has(command.get("asset_id", "")):
			return {"ok": false, "error": "invalid_command"}
		var asset: Dictionary = assets[command.asset_id]
		next.slots[asset.slot] = asset.id
		changes.append({"slot": asset.slot, "asset_id": asset.id, "name": asset.name})
	_undo.append(state.duplicate(true))
	if _undo.size() > HISTORY_LIMIT:
		_undo.pop_front()
	state = next
	return {"ok": true, "changes": changes}


func undo() -> bool:
	if _undo.is_empty():
		return false
	state = _undo.pop_back()
	return true


func restore(snapshot: Dictionary) -> Dictionary:
	if snapshot.get("schema") != 1 or not snapshot.get("slots") is Dictionary:
		return {"ok": false, "error": "invalid_snapshot"}
	var unresolved: Array = []
	for slot in snapshot.slots:
		var id = snapshot.slots[slot]
		if not slot is String or not id is String:
			return {"ok": false, "error": "invalid_slot"}
		if not assets.has(id):
			unresolved.append(id)
		elif assets[id].slot != slot:
			return {"ok": false, "error": "slot_mismatch"}
	# Keep missing references and unknown fields, so reinstalling a package can resolve them later.
	state = snapshot.duplicate(true)
	_undo.clear()
	return {"ok": true, "unresolved": unresolved}
