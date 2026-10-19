extends RefCounted
## Stress test for strand lifetimes: auto mode, cum and a random game action every 20 ticks for 9000 ticks; stops
## (exit code 1) when a strand list or her / his current strand holds a freed strand. SEED=<n> picks the actions.
## Run: godot --headless --fixed-fps 30 --path game -- --save-dir=<folder> --driver=res://debug/stress_strands.gd

var t0 := -1
var history: Array = []
var done := false
var rng := RandomNumberGenerator.new()

func _actions() -> Array:
	var m := g.inGameMenu
	return [
		["ejaculate", func(): g.him.ejaculate()],
		["clear cum", func(): m.clearCumClicked()],
		["clear spit", func(): m.clearSpitClicked()],
		["clear all", func(): m.clearAllClicked()],
		["strand shaders", func(): m.cbStrandShadersClicked()],
		["spit toggle", func(): m.cbSpitClicked()],
		["tears toggle", func(): m.cbTearsClicked()],
		["next character", func(): g.characterControl.nextCharacter()],
		["shuffle", func(): m.shuffle()],
		["mirror", func(): m.cbMirroredClicked()],
		["mood", func(): g.her.setMood(Moods.selectable()[rng.randi() % Moods.selectable().size()])],
		["menu open/close", func(): SDTMenu.instance.toggle_tab(1) if SDTMenu.active() else null],
		["auto style", func(): m.autoRightClicked() if g.autoMode < 3 else m.autoLeftClicked()],
		["costume top", func(): g.characterControl.topControl._step(1 if rng.randf() < 0.5 else -1)],
	]

func step(_f: int) -> void:
	if done or not Extensions.started:
		return
	if t0 < 0:
		rng.seed = int(OS.get_environment("SEED")) if OS.get_environment("SEED") != "" else 7
		Flash.stage.getChildAt(0).playClicked()
		t0 = Flash.tick_count
		return
	var t := Flash.tick_count - t0
	if t == 5:
		g.toggleAutoMode()
	var sc = g.strandControl
	var held: Array = []
	for r in [g.her.currentCumDrool, g.her.currentSpitDrool, g.her.currentNostrilSpray, g.him.currentSpurt]:
		if r != null:
			held.append(r)
	for s in sc.strands + sc.cumStrands + held:
		if not is_instance_valid(s):
			print("STRAND FREED IN LIST at tick %d after: %s" % [t, history.slice(-8)])
			done = true
			Flash.get_tree().quit(1)
			return
	if t % 20 == 0 and t > 10:
		var acts := _actions()
		var a: Array = acts[rng.randi() % acts.size()]
		if SDTMenu.active() and SDTMenu.instance.is_open and a[0] != "menu open/close":
			SDTMenu.instance.close_menu()
		a[1].call()
		history.append("%d:%s" % [t, a[0]])
	if t >= 9000:
		print("STRAND OK after %d ticks, %d actions; strands %d cum %d (native %s); droplets %d; pending disposals %d; orphan nodes %d" % [
			t, history.size(), sc.strand_count(false), sc.strand_count(true), sc.fluids != null, Sweat.droplet_count(),
			Flash._disposals.size(), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)])
		done = true
		Flash.get_tree().quit()
