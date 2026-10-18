extends RefCounted
## Deterministic, non-executing dependency resolution. Runtime readiness is checked again at load time.

const Manifest = preload("package_manifest.gd")


static func resolve(packages: Array, available: Dictionary = {}, capabilities: Array = [], platform: String = "") -> Dictionary:
	var nodes: Dictionary = {}
	var errors: Dictionary = {}
	var edges: Dictionary = {}
	for p in packages:
		if nodes.has(p.id) or available.has(p.id):
			_issue(errors, p.id, "duplicate_id", p.id)
		else:
			nodes[p.id] = p
			edges[p.id] = []
	var ids: Array = nodes.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = nodes[id]
		if not p.platforms.is_empty() and not platform in p.platforms:
			_issue(errors, id, "unsupported_platform", platform)
		for cap in p.requires:
			if not cap in capabilities:
				_issue(errors, id, "unsupported_capability", cap)
		for other in p.conflicts:
			if nodes.has(other) or available.has(other):
				_issue(errors, id, "package_conflict", other)
				if nodes.has(other):
					_issue(errors, other, "package_conflict", id)
		for dep in p.depends + p.optional_depends:
			var required: bool = dep in p.depends
			if not nodes.has(dep) and not available.has(dep):
				if required:
					_issue(errors, id, "missing_dependency", dep)
				continue
			var info: Dictionary = nodes.get(dep, available.get(dep, {}))
			var constraint: String = p.dependency_versions.get(dep, "*")
			if not Manifest.satisfies(str(info.get("version", "1")), constraint):
				_issue(errors, id, "version_mismatch", dep)
			if required and not info.get("enabled", true):
				_issue(errors, id, "disabled_dependency", dep)
			if nodes.has(dep):
				_edge(edges, id, dep)
		for dep in p.load_after:
			if nodes.has(dep):
				_edge(edges, id, dep)
		for next in p.load_before:
			if nodes.has(next):
				_edge(edges, next, id)
	# Identify actual cycle members, not every package downstream of a cycle.
	for id in ids:
		if _reaches(id, id, edges, {}):
			_issue(errors, id, "dependency_cycle", id)
	# Propagate required failures; ordering preferences never block a valid package.
	var changed := true
	while changed:
		changed = false
		for id in ids:
			if errors.has(id):
				continue
			for dep in nodes[id].depends:
				if errors.has(dep):
					_issue(errors, id, "blocked_dependency", dep)
					changed = true
					break
	var pending: Array = ids.filter(func(id): return not errors.has(id))
	var order: Array = []
	while not pending.is_empty():
		var progressed := false
		for id in pending.duplicate():
			if edges[id].all(func(dep): return dep in order or errors.has(dep)):
				order.append(id)
				pending.erase(id)
				progressed = true
		if not progressed:
			break
	return {"order": order, "errors": errors}


static func _edge(edges: Dictionary, id: String, dep: String) -> void:
	if not dep in edges[id]:
		edges[id].append(dep)


static func _reaches(origin: String, current: String, edges: Dictionary, visited: Dictionary) -> bool:
	if visited.has(current):
		return false
	visited[current] = true
	for dep in edges.get(current, []):
		if dep == origin or _reaches(origin, dep, edges, visited):
			return true
	return false


static func _issue(errors: Dictionary, id: String, code: String, detail: String) -> void:
	if not errors.has(id):
		errors[id] = []
	errors[id].append({"code": code, "detail": detail})
