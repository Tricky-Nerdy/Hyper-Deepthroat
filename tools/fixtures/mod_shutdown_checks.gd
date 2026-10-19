extends Node
## Neutral ownership graph only: no third-party mod, SWF conversion or gameplay inputs.


func _ready() -> void:
	var detached := FlashSprite.new()
	var detached_id := detached.get_instance_id()
	assert(FlashDisplayObject.off_tree.has(detached_id), "never-attached display objects must be tracked")
	Flash.attach_stage(self)
	var attached := FlashSprite.new()
	add_child(attached)
	assert(not FlashDisplayObject.off_tree.has(attached.get_instance_id()), "in-tree nodes must not be orphan candidates")
	Flash.free_orphans_at_exit()
	assert(not is_instance_valid(detached), "final cleanup must free a never-attached display object")
	assert(is_instance_valid(attached), "final orphan cleanup must preserve in-tree nodes")
	assert(not FlashDisplayObject.off_tree.has(detached_id), "freed display objects must be untracked")
	var mod := FlashSwfMod.new()
	var lib := FlashLibrary.new()
	var code := FlashAbc.new()
	mod.library = lib
	lib.mod = mod
	mod.abc.append(code)
	code.host = mod
	FlashSwfMod._loaded["neutral-fixture"] = mod
	var observed: WeakRef = weakref(mod)
	mod = null
	assert(observed.get_ref() != null, "fixture must reproduce retained ownership")
	var unrelated := func(_path: String, _bytes: PackedByteArray): return null
	FlashLoader.handlers.append(unrelated)
	FlashLoader.handlers.append(FlashSwfMod._loader_handler)
	FlashSwfMod.shutdown()
	assert(observed.get_ref() == null, "shutdown must release the cached mod")
	assert(lib.mod == null and code.host == null, "back-references must be released")
	assert(FlashSwfMod._loaded.is_empty(), "cache must be empty")
	assert(FlashLoader.handlers.has(unrelated), "another loader's handler must survive")
	assert(not FlashLoader.handlers.has(FlashSwfMod._loader_handler), "owned handler must be removed")
	FlashSwfMod.shutdown()
	assert(FlashLoader.handlers.has(unrelated), "shutdown must be repeatable")
	FlashLoader.handlers.erase(unrelated)
	FlashSwfMod.register()
	FlashSwfMod.register()
	var expected := 1 if ClassDB.class_exists(&"SWFFile") else 0
	assert(FlashLoader.handlers.count(FlashSwfMod._loader_handler) == expected, "registration must be idempotent")
	FlashSwfMod.shutdown()
	print("MOD_SHUTDOWN_CHECKS_OK")
	get_tree().quit(0)
