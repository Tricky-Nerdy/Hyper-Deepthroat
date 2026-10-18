extends SceneTree
## Pure-core tests, run without the game, autoloads, third-party assets, or native extensions.

const Manifest = preload("core/package_manifest.gd")
const Resolver = preload("core/package_resolver.gd")
const Slots = preload("core/owned_slots.gd")
const Commands = preload("core/asset_commands.gd")
const Story = preload("core/story_runtime.gd")
const Storage = preload("core/atomic_json.gd")

var passed := 0
var failed := 0
var results: Array = []


func _init() -> void:
	call_deferred("_run")


func check(name_: String, condition: bool) -> void:
	results.append({"name": name_, "ok": condition})
	if condition:
		passed += 1
	else:
		failed += 1
	print("%s %s" % ["PASS" if condition else "FAIL", name_])


func package(id: String, fields: Dictionary = {}) -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.set_value("plugin", "id", id)
	for key in fields:
		cfg.set_value("plugin", key, fields[key])
	return Manifest.normalize(cfg).manifest


func _run() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("plugin", "id", "example")
	check("legacy manifest defaults", Manifest.normalize(cfg).errors.is_empty())
	cfg.set_value("plugin", "main", "../escape.gd")
	check("entry traversal rejected", "invalid_entry_path" in Manifest.normalize(cfg).errors)
	cfg.set_value("plugin", "main", "C:\\escape.gd")
	check("Windows absolute entry rejected on every host", not Manifest.normalize(cfg).errors.is_empty())
	cfg.set_value("plugin", "main", "plugin.gd")
	cfg.set_value("plugin", "depends", "not-an-array")
	check("malformed dependency type rejected", "invalid_depends" in Manifest.normalize(cfg).errors)
	check("numeric version ordering", Manifest.satisfies("1.10", ">=1.9 <2"))
	check("invalid constraints rejected", not Manifest.satisfies("1.0", "^1"))
	check("version mismatch rejected", not Manifest.satisfies("2.0", ">=1 <2"))
	check("legacy opaque version accepted without a numeric constraint", Manifest.satisfies("1.0-preview", "*"))
	check("opaque versions cannot falsely satisfy numeric constraints", not Manifest.satisfies("1.0-preview", ">=1"))
	var a := package("a")
	var b := package("b", {"depends": ["a"]})
	check("dependency order independent of discovery", Resolver.resolve([b, a]).order == ["a", "b"])
	check("missing dependency distinguished", Resolver.resolve([b]).errors.b[0].code == "missing_dependency")
	check("disabled dependency distinguished", Resolver.resolve([b], {"a": {"version": "1", "enabled": false}}).errors.b[0].code == "disabled_dependency")
	var v := package("v", {"depends": ["a"], "dependency_versions": {"a": ">=2"}})
	check("dependency version enforced", Resolver.resolve([a, v]).errors.v[0].code == "version_mismatch")
	var ca := package("ca", {"depends": ["cb"]})
	var cb := package("cb", {"depends": ["ca"]})
	var child := package("child", {"depends": ["ca"]})
	var resolution := Resolver.resolve([ca, cb, child, a])
	check("cycle members identified", resolution.errors.ca[0].code == "dependency_cycle")
	check("downstream failure is not mislabeled as cycle", resolution.errors.child[0].code == "blocked_dependency")
	check("unrelated package survives cycle", resolution.order == ["a"])
	check("optional missing dependency accepted", Resolver.resolve([package("optional", {"optional_depends": ["absent"]})]).order == ["optional"])
	check("ordering preference respected", Resolver.resolve([a, package("z", {"load_before": ["a"]})]).order == ["z", "a"])
	check("unavailable capabilities block package", Resolver.resolve([package("native", {"requires": ["swf_conversion"]})]).errors.native[0].code == "unsupported_capability")
	check("platform restriction enforced", Resolver.resolve([package("win", {"platforms": ["Windows"]})], {}, [], "Linux").errors.win[0].code == "unsupported_platform")
	var conflict := Resolver.resolve([a, package("other", {"conflicts": ["a"]})])
	check("conflicts block both sides", conflict.errors.has("a") and conflict.errors.has("other"))
	check("duplicate IDs block ambiguous package", Resolver.resolve([a, a]).errors.a[0].code == "duplicate_id")
	var value := {"current": "base"}
	var slots := Slots.new()
	check("owned slot defined", slots.define("preview", func(): return value.current, func(vv): value.current = vv))
	slots.replace("first", "preview", "one")
	slots.replace("second", "preview", "two")
	slots.release("first")
	check("removing lower replacement preserves top", value.current == "two")
	slots.release("second")
	check("last owner restores original", value.current == "base")
	slots.clear()
	var commands := Commands.new()
	for asset in JSON.parse_string(FileAccess.get_file_as_string("res://fixtures/assets.json")):
		commands.register_asset(asset)
	var proposal := commands.propose("wear the Blue Jacket; background Station")
	check("exact-name natural language proposes typed commands", proposal.ok and proposal.commands.size() == 2)
	commands.apply(proposal.commands)
	check("batch applied", commands.state.slots.outerwear == "sample:blue-jacket")
	var before := commands.state.duplicate(true)
	var invalid := commands.apply([{"op": "select", "asset_id": "sample:gold-jacket"}, {"op": "execute", "script": "no"}])
	check("invalid batch leaves all state unchanged", not invalid.ok and commands.state == before)
	check("missing asset is explicit", commands.propose("wear Missing Jacket").error == "missing_asset")
	commands.register_asset({"id": "another:blue", "name": "Blue Jacket", "kind": "costume", "slot": "outerwear"})
	check("ambiguity never silently chooses", commands.propose("wear Blue Jacket").error == "ambiguous_asset")
	check("undo restores entire batch", commands.undo() and commands.state.slots.is_empty())
	check("missing references and unknown fields survive", commands.restore({"schema": 1, "slots": {"outerwear": "missing:item"}, "future": 42}).unresolved == ["missing:item"] and commands.state.future == 42)
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://fixtures/arrival.json"))
	var story := Story.new()
	check("story fixture validates", story.load_document(doc).ok)
	story.advance()
	check("conditional choices initially hidden", story.current().choices.size() == 2)
	story.choose(0)
	check("automatic assignment before dialogue", story.variables.visited_gallery and story.current().id == "gallery")
	var saved := story.snapshot()
	story.advance()
	check("condition reveals choice", story.current().choices.size() == 3)
	check("story resume restores position and variables", story.restore(saved).ok and story.current().id == "gallery")
	var corrupt := saved.duplicate(true)
	corrupt.variables.visited_gallery = "not-a-bool"
	check("invalid story save leaves state unchanged", not story.restore(corrupt).ok and story.snapshot() == saved)
	var broken := doc.duplicate(true)
	broken.nodes.welcome.next = "absent"
	check("missing story target rejected", not Story.validate(broken).is_empty())
	var loop := {"schema": 1, "id": "loop", "start": "again", "variables": {}, "nodes": {"again": {"type": "jump", "next": "again"}}}
	var before_loop := story.snapshot()
	check("automatic story loop bounded", story.load_document(loop).get("error") == "automatic_step_limit")
	check("failed story load preserves previous scene", story.snapshot() == before_loop)
	var dead_end := doc.duplicate(true)
	dead_end.nodes.route.choices = [{"text": "Hidden", "next": "finish", "when": {"key": "visited_gallery", "equals": true}}]
	var dead_story := Story.new()
	dead_story.load_document(dead_end)
	var dead_save := dead_story.snapshot()
	dead_save.node = "route"
	var before_restore := dead_story.snapshot()
	check("dead-end restore rejected atomically", not dead_story.restore(dead_save).ok and dead_story.snapshot() == before_restore)
	var file := "user://portable-check.json"
	check("atomic save", Storage.save_file(file, {"schema": 1, "value": "first"}) == OK)
	check("atomic replacement", Storage.save_file(file, {"schema": 1, "value": "second"}) == OK and Storage.read_file(file).value.value == "second")
	DirAccess.remove_absolute(file)
	var report := {"schema": 1, "passed": passed, "failed": failed, "checks": results}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--licenses="):
			var notices := FileAccess.open(arg.substr(11), FileAccess.WRITE)
			if notices == null:
				failed += 1
			else:
				notices.store_string(Engine.get_license_text() + "\n\n" + JSON.stringify(Engine.get_copyright_info(), "\t") \
					+ "\n\n" + JSON.stringify(Engine.get_license_info(), "\t"))
				notices.close()
		if arg.begins_with("--report="):
			if Storage.save_file(arg.substr(9), report) != OK:
				failed += 1
	print("PORTABLE CHECKS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
