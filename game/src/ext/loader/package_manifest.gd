extends RefCounted
## Normalizes the existing plugin.cfg format. No script execution or filesystem writes.

const API_VERSION := 1
const LIST_FIELDS := ["depends", "optional_depends", "load_after", "load_before", "conflicts", "requires", "platforms"]


static func normalize(cfg: ConfigFile, fallback_id: String = "") -> Dictionary:
	var p := {"id": str(cfg.get_value("plugin", "id", fallback_id)),
		"name": str(cfg.get_value("plugin", "name", fallback_id)),
		"author": str(cfg.get_value("plugin", "author", "")),
		"version": str(cfg.get_value("plugin", "version", "1")),
		"main": str(cfg.get_value("plugin", "main", "plugin.gd")),
		"enabled_by_default": cfg.get_value("plugin", "enabled_by_default", true),
		"reloadable": cfg.get_value("plugin", "reloadable", true),
		"loader_api": cfg.get_value("plugin", "loader_api", API_VERSION),
		"dependency_versions": cfg.get_value("plugin", "dependency_versions", {})}
	var errors: Array = []
	var rx := RegEx.create_from_string("^[A-Za-z0-9][A-Za-z0-9_.-]*$")
	if rx.search(p.id) == null:
		errors.append("invalid_id")
	if p.version.is_empty():
		errors.append("invalid_version")
	if not safe_relative(p.main) or not p.main.ends_with(".gd"):
		errors.append("invalid_entry_path")
	if typeof(p.loader_api) != TYPE_INT or p.loader_api != API_VERSION:
		errors.append("unsupported_loader_api")
	for key in ["enabled_by_default", "reloadable"]:
		if typeof(p[key]) != TYPE_BOOL:
			errors.append("invalid_%s" % key)
	for key in LIST_FIELDS:
		var value = cfg.get_value("plugin", key, [])
		p[key] = []
		if not value is Array and not value is PackedStringArray:
			errors.append("invalid_%s" % key)
			continue
		for item in value:
			if not item is String or item.is_empty():
				errors.append("invalid_%s" % key)
				continue
			if key in ["depends", "optional_depends", "load_after", "load_before", "conflicts"] and rx.search(item) == null:
				errors.append("invalid_%s" % key)
				continue
			if not p[key].has(item):
				p[key].append(item)
	if not p.dependency_versions is Dictionary:
		errors.append("invalid_dependency_versions")
		p.dependency_versions = {}
	for dep in p.dependency_versions:
		if not dep is String or not (dep in p.depends or dep in p.optional_depends):
			errors.append("constraint_without_dependency")
		if not p.dependency_versions[dep] is String or not valid_constraint(str(p.dependency_versions[dep])):
			errors.append("invalid_version_constraint")
	return {"manifest": p, "errors": errors}


static func safe_relative(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	return not normalized.is_empty() and not normalized.is_absolute_path() and not ":" in normalized \
		and not ".." in normalized.split("/") and not "" in normalized.split("/")


static func version_parts(text: String) -> Array:
	if RegEx.create_from_string("^[0-9]+(\\.[0-9]+){0,2}$").search(text) == null:
		return []
	var parts: Array = []
	for component in text.split("."):
		parts.append(int(component))
	while parts.size() < 3:
		parts.append(0)
	return parts


static func compare(a: String, b: String) -> int:
	var av := version_parts(a)
	var bv := version_parts(b)
	if av.is_empty() or bv.is_empty():
		return 0
	for i in 3:
		if av[i] != bv[i]:
			return 1 if av[i] > bv[i] else -1
	return 0


static func valid_constraint(text: String) -> bool:
	if text == "*":
		return true
	if text.strip_edges().is_empty():
		return false
	for term in text.split(" ", false):
		if RegEx.create_from_string("^(>=|<=|>|<|=)?[0-9]+(\\.[0-9]+){0,2}$").search(term) == null:
			return false
	return true


static func satisfies(version: String, constraint: String) -> bool:
	if not valid_constraint(constraint):
		return false
	if constraint == "*":
		return true
	if version_parts(version).is_empty():
		return false
	for term in constraint.split(" ", false):
		var match_ := RegEx.create_from_string("^(>=|<=|>|<|=)?(.+)$").search(term)
		var op := match_.get_string(1)
		var c := compare(version, match_.get_string(2))
		if (op == ">=" and c < 0) or (op == "<=" and c > 0) or (op == ">" and c <= 0) \
			or (op == "<" and c >= 0) or (op in ["", "="] and c != 0):
			return false
	return true
