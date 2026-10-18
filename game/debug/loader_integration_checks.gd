extends Node
## Integration checks for Extensions, without constructing DT or running gameplay.
## Run with --save-dir=<temporary directory>. Generates only neutral temporary plugin fixtures.

var passed := 0
var failed := 0


func _ready() -> void:
	get_tree().create_timer(30).timeout.connect(func(): get_tree().quit(3))
	call_deferred("_run")


func quit(code: int) -> void:
	get_tree().quit(code)


func check(name_: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
	print("LOADER %s %s" % ["PASS" if condition else "FAIL", name_])


func fixture(root: String, id: String, fields: Dictionary = {}, code: String = "extends SDTExtension\n") -> void:
	var folder := root.path_join(id)
	DirAccess.make_dir_recursive_absolute(folder)
	var cfg := ConfigFile.new()
	cfg.set_value("plugin", "id", id)
	for key in fields:
		cfg.set_value("plugin", key, fields[key])
	cfg.save(folder.path_join("plugin.cfg"))
	var file := FileAccess.open(folder.path_join("plugin.gd"), FileAccess.WRITE)
	file.store_string(code)


func _run() -> void:
	var save := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--save-dir="):
			save = arg.substr(11)
	if save.is_empty():
		push_error("Integration checks require --save-dir=<temporary directory>")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(save)
	FlashSharedObject.save_dir = save
	var root := save.path_join("fixtures")
	fixture(root, "base", {}, "extends SDTExtension\nfunc _enable():\n\treplace_slot(\"test\", \"base\")\n")
	fixture(root, "child", {"depends": ["base"]}, "extends SDTExtension\nfunc _enable():\n\treplace_slot(\"test\", \"child\")\n")
	fixture(root, "failed", {}, "extends SDTExtension\nfunc _enable():\n\treplace_slot(\"test\", \"failed\")\n\tfail_initialization(\"fixture failure\")\n")
	fixture(root, "needs_failed", {"depends": ["failed"]})
	fixture(root, "disabled", {"enabled_by_default": false})
	fixture(root, "needs_disabled", {"depends": ["disabled"]})
	fixture(root, "missing", {"depends": ["absent"]})
	fixture(root, "bad_path", {"main": "../base/plugin.gd"})
	fixture(root, "setup_failed", {}, "extends SDTExtension\nfunc _setup():\n\tfail_initialization(\"setup fixture failure\")\n")
	fixture(root, "duplicate_a", {"id": "duplicate"})
	fixture(root, "duplicate_b", {"id": "duplicate"})
	var value := {"text": "original"}
	Extensions.owned_slots.define("test", func(): return value.text, func(v): value.text = v)
	Extensions._load_config()
	Extensions.load_plugins(root)
	check("base and child active", Extensions.by_id.base.enabled and Extensions.by_id.child.enabled)
	check("dependent loaded later", Extensions.all.find(Extensions.by_id.base) < Extensions.all.find(Extensions.by_id.child))
	check("replacement ownership stack", value.text == "child")
	check("explicit initialization failure recorded", Extensions.plugins.failed.state == "failed")
	check("failed initialization cleaned resources", value.text == "child")
	check("failed requirement blocks dependent", Extensions.plugins.needs_failed.state == "blocked" and not Extensions.by_id.has("needs_failed"))
	check("disabled package is discoverable", Extensions.by_id.has("disabled") and not Extensions.by_id.disabled.enabled)
	check("disabled requirement distinguished", "disabled dependency" in Extensions.plugins.needs_disabled.error)
	check("missing requirement distinguished", "missing dependency" in Extensions.plugins.missing.error)
	check("entry path validated before execution", Extensions.plugins.bad_path.state == "failed")
	check("setup failure cannot enable", Extensions.plugins.setup_failed.state == "failed" and not Extensions.by_id.setup_failed.enabled)
	check("duplicate packages never execute", Extensions.plugins.duplicate.state == "blocked" and not Extensions.by_id.has("duplicate"))
	Extensions.set_enabled("duplicate", true)
	check("duplicate failure cannot be bypassed by enable", not Extensions.by_id.has("duplicate"))
	Extensions.set_enabled("needs_disabled", true)
	check("blocked package can enable its requirement and retry", Extensions.by_id.has("needs_disabled") \
		and Extensions.by_id.needs_disabled.enabled and Extensions.by_id.disabled.enabled)
	Extensions.set_enabled("disabled", false)
	check("retried dependent participates in disable cascade", not Extensions.by_id.needs_disabled.enabled)
	Extensions.set_enabled("base", false)
	check("disable cascades to dependent", not Extensions.by_id.base.enabled and not Extensions.by_id.child.enabled)
	check("disable restores original slot", value.text == "original")
	Extensions.set_enabled("child", true)
	check("enable requirements before dependent", Extensions.by_id.base.enabled and Extensions.by_id.child.enabled and value.text == "child")
	Extensions.set_vanilla_mode(true)
	check("vanilla mode cleans replacements", value.text == "original")
	Extensions.set_vanilla_mode(false)
	check("leaving vanilla mode restores dependency order", Extensions.by_id.child.enabled and value.text == "child")
	var report := Extensions.report()
	check("native capabilities are reported independently", report.swf_conversion == ClassDB.class_exists(&"SWFFile") \
		and report.native_acceleration == ClassDB.class_exists(&"SDTNative"))
	if ClassDB.class_exists(&"SWFFile"):
		var swf = ClassDB.instantiate(&"SWFFile")
		var bytes := PackedByteArray([70, 87, 83, 9, 16, 0, 0, 0, 8, 0, 0, 30, 1, 0, 0, 0])
		check("native parser reads a neutral empty SWF", swf.open(bytes) == OK and is_equal_approx(float(swf.get_info().fps), 30.0))
	else:
		check("native parser available for integration", false)
	check("public report omits local folders", not JSON.stringify(report).contains(save) and not JSON.stringify(report).contains("\"folder\""))
	check("default report excludes arbitrary plugin error text", not JSON.stringify(report).contains("fixture failure"))
	fixture(root, "restart_only", {"reloadable": false})
	# A second discovery pass exercises additions without reloading existing packages.
	Extensions.load_plugins(root)
	Extensions.set_enabled("restart_only", false)
	check("restart-only disable is scheduled rather than forced", Extensions.by_id.restart_only.enabled \
		and Extensions.plugins.restart_only.state == "restart_required" \
		and Extensions._config.get_value("enabled", "restart_only", true) == false)
	Extensions.set_vanilla_mode(true)
	check("restart-only vanilla mode is scheduled", not Extensions.vanilla_mode \
		and Extensions._config.get_value("extensions", "vanilla_mode", false) == true)
	Extensions.shutdown()
	check("shutdown restores state and clears registries", value.text == "original" and Extensions.by_id.is_empty() and Extensions.plugins.is_empty())
	print("LOADER INTEGRATION: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
