extends RefCounted
## Small deterministic, non-explicit story format. No expressions, scripts, or external code evaluation.

const STEP_LIMIT := 128
var document: Dictionary = {}
var variables: Dictionary = {}
var node_id := ""
var error := ""
var _digest := ""


func load_document(source: Dictionary) -> Dictionary:
	var errors := validate(source)
	if not errors.is_empty():
		return {"ok": false, "errors": errors}
	var previous := [document, variables, node_id, error, _digest]
	document = source.duplicate(true)
	_digest = JSON.stringify(document, "", true).sha256_text()
	variables = document.variables.duplicate(true)
	node_id = document.start
	error = ""
	_settle()
	var failure := error
	if not failure.is_empty():
		document = previous[0]
		variables = previous[1]
		node_id = previous[2]
		error = previous[3]
		_digest = previous[4]
	return {"ok": failure.is_empty(), "error": failure}


static func _scalar(value) -> bool:
	return typeof(value) in [TYPE_BOOL, TYPE_INT, TYPE_STRING] or (value is float and is_finite(value))


static func _same_type(a, b) -> bool:
	return _scalar(a) and _scalar(b) and (typeof(a) == typeof(b) \
		or (typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]))


static func validate(source: Dictionary) -> Array:
	var errors: Array = []
	if source.get("schema") != 1 or not source.get("id") is String or source.get("id", "").is_empty() \
		or not source.get("nodes") is Dictionary or not source.get("variables") is Dictionary:
		return ["invalid_document"]
	var nodes: Dictionary = source.nodes
	if not source.get("start") is String or not nodes.has(source.get("start")):
		errors.append("invalid_start")
	for key in source.variables:
		if not key is String or not _scalar(source.variables[key]):
			errors.append("invalid_variable")
	for id in nodes:
		var n = nodes[id]
		if not id is String or not n is Dictionary:
			errors.append("invalid_node")
			continue
		var type: String = str(n.get("type", ""))
		if not type in ["say", "choice", "set", "jump", "end"]:
			errors.append("unknown_node_type:%s" % id)
			continue
		if type in ["say", "set", "jump"] and (not n.get("next") is String or not nodes.has(n.get("next"))):
			errors.append("missing_target:%s" % id)
		if type == "say" and (not n.get("text") is String or not n.get("speaker", "") is String):
			errors.append("invalid_line:%s" % id)
		if type == "set":
			var key = n.get("key", "")
			if not source.variables.has(key) or not _same_type(source.variables.get(key), n.get("value")):
				errors.append("invalid_assignment:%s" % id)
		if type == "choice":
			if not n.get("choices") is Array or n.get("choices", []).is_empty():
				errors.append("invalid_choices:%s" % id)
				continue
			for c in n.choices:
				if not c is Dictionary or not c.get("text") is String or not c.get("next") is String or not nodes.has(c.get("next")):
					errors.append("invalid_choice:%s" % id)
					continue
				if c.has("when"):
					var w = c.when
					if not w is Dictionary or not source.variables.has(w.get("key", "")) \
						or not _same_type(source.variables.get(w.get("key", "")), w.get("equals")):
						errors.append("invalid_condition:%s" % id)
	return errors


func current() -> Dictionary:
	if not error.is_empty():
		return {"type": "error", "error": error}
	if document.is_empty():
		return {"type": "end"}
	var n: Dictionary = document.nodes[node_id].duplicate(true)
	n["id"] = node_id
	if n.type == "choice":
		n.choices = _choices(n.choices)
	return n


func advance() -> bool:
	if current().type != "say":
		return false
	node_id = document.nodes[node_id].next
	_settle()
	return error.is_empty()


func choose(index: int) -> bool:
	var n := current()
	if n.type != "choice" or index < 0 or index >= n.choices.size():
		return false
	node_id = n.choices[index].next
	_settle()
	return error.is_empty()


func _choices(choices: Array) -> Array:
	return choices.filter(func(c): return not c.has("when") or variables[c.when.key] == c.when.equals)


func _settle() -> void:
	for _step in STEP_LIMIT:
		var n: Dictionary = document.nodes[node_id]
		if n.type == "set":
			variables[n.key] = n.value
		elif n.type != "jump":
			if n.type == "choice" and _choices(n.choices).is_empty():
				error = "no_available_choices"
			return
		node_id = n.next
	error = "automatic_step_limit"


func snapshot() -> Dictionary:
	return {"schema": 1, "document_id": document.get("id", ""), "document_digest": _digest,
		"node": node_id, "variables": variables.duplicate(true)}


func restore(saved: Dictionary) -> Dictionary:
	if document.is_empty() or saved.get("schema") != 1 or saved.get("document_id") != document.id \
		or saved.get("document_digest") != _digest or not document.nodes.has(saved.get("node", "")) \
		or not saved.get("variables") is Dictionary or saved.variables.size() != document.variables.size():
		return {"ok": false, "error": "incompatible_story_save"}
	for key in document.variables:
		if not saved.variables.has(key) or not _same_type(document.variables[key], saved.variables[key]):
			return {"ok": false, "error": "invalid_story_variables"}
	var previous := [variables, node_id, error]
	variables = saved.variables.duplicate(true)
	node_id = saved.node
	error = ""
	_settle()
	var failure := error
	if not failure.is_empty():
		variables = previous[0]
		node_id = previous[1]
		error = previous[2]
	return {"ok": failure.is_empty(), "error": failure}
