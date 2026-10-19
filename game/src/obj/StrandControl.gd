class_name StrandControl
extends RefCounted
## Port of obj.StrandControl: owns the spit / cum strands.
##
## Port: with the native extension the strands are simulated and drawn by SDTFluids (native/src/fluids.cpp): plain
## data and one call per tick instead of a display object and dozens of script calls per strand and link. This class
## keeps the game-facing API, returning NativeStrand handles; each tick it sends the body parts' transforms and the
## collision targets, runs the simulation, applies its events (cum on her face, eye hits, the tongue, drips) and
## draws one mesh per strand layer. Without the extension the original GDScript Strand / StrandLink are used.

var strands: Array = []
var cumStrands: Array = []
var lockedStrands: Array = []
const maxStrands := 20

static var native_enabled: bool = ClassDB.class_exists(&"SDTFluids") and not "--nonative" in OS.get_cmdline_user_args()

var fluids = null                    # SDTFluids
var _containers: Dictionary = {}     # display object -> container index
var _container_objs: Array = []      # index -> display object
var _layers: Array = []              # strandBackLayer, strandFrontLayer, cumLayer
var _meshes: Array = []              # a FlashSprite per layer, drawing that layer's strands

enum { EV_CUM_ON_FACE, EV_EYE_HIT, EV_EYE_CLEAR, EV_TONGUE_CUM_HIT, EV_TONGUE_CUM_REMOVED, EV_DROPLET }
const IN_HEAD := 1
const HIM := 2
const SCENE := 4
const TONGUE_TIP := 8
const TARGET_FACE := 1
const TARGET_TONGUE := 2


func newStrand(layer: FlashSprite, links: int, mass: float, a = null, b = null, long: bool = false,
		initialSpeed = null, back: bool = false):
	if _native():
		push_transforms()
		var id: int = fluids.new_strand(_layer_index(layer), links, mass, _anchor(a), _anchor(b), long, back,
			initialSpeed if initialSpeed != null else Vector2())
		return NativeStrand.new(fluids, id)
	var s := Strand.new(layer, links, mass, a, b, long, back)
	s.instancePoints(initialSpeed)
	layer.addChild(s)
	strands.append(s)
	return s


func checkElementAnchors(element: FlashDisplayObject) -> void:
	if _native():
		if _containers.has(element):
			fluids.detach_container(_containers[element])
		return
	for s in strands + cumStrands:
		s.checkElementAnchors(element)


func checkCostumeAnchors() -> void:
	if _native():
		for e in g.costumeHitElements:
			if _containers.has(e):
				fluids.detach_container(_containers[e])
		return
	for s in strands + cumStrands:
		s.checkCostumeAnchors()


func clearSpitStrands() -> void:
	if _native():
		fluids.clear(false)
		_apply_events(fluids.take_events())
		_draw()
		return
	for i in strands.size():
		strands[0].killMe()


func clearCumStrands() -> void:
	if _native():
		fluids.clear(true)
		_apply_events(fluids.take_events())
		_draw()
	else:
		for i in cumStrands.size():
			cumStrands[0].killMe()
	for i in lockedStrands.size():
		lockedStrands[0].kill()


func smearStrands(p: Vector2, radius: float = 25.0) -> void:
	if _native():
		push_transforms()
		fluids.smear(g.sceneLayer.flash_global_transform().affine_inverse() * p, radius)
		_apply_events(fluids.take_events())
		return
	for s in strands + cumStrands:
		s.smear(p, radius)


func newCumStrand(p: Vector2, container: FlashDisplayObject):
	if _native():
		push_transforms()
		var id: int = fluids.new_cum_strand(2, g.randomCumMass(), p, container_index(container))
		return NativeStrand.new(fluids, id)
	var s := Strand.new(g.cumLayer, 1, g.randomCumMass())
	s.addSourceLink(p, container)
	g.cumLayer.addChild(s)
	cumStrands.append(s)
	return s


func addStrand(from: Strand, links: Array, mass: float) -> void:
	var s := Strand.new(from.layer, 0, mass)
	s.giveLinks(links)
	s.age = from.age
	s.ageMax = from.ageMax
	s.cumStrand = from.cumStrand
	from.layer.addChild(s)
	if from.cumStrand:
		cumStrands.append(s)
	else:
		strands.append(s)
	s.distSplitDelay = 10
	s.graphics.copyFrom(from.graphics)


func delistStrand(s: Strand) -> void:
	if s.cumStrand:
		cumStrands.erase(s)
	else:
		strands.erase(s)


func delistLockedStrand(s) -> void:
	lockedStrands.erase(s)


func maxPop() -> bool:
	if _native():
		return fluids.count(false) >= maxStrands
	return strands.size() >= maxStrands


## Number of live spit (cum = false) or cum strands (tests).
func strand_count(cum: bool) -> int:
	if _native():
		return fluids.count(cum)
	return (cumStrands if cum else strands).size()


# ---------------------------------------------------------------- native fluid system

## True once the native fluid system runs (set up on first use, when the scene exists).
func _native() -> bool:
	if fluids != null:
		return true
	if not native_enabled or g.sceneLayer == null or g.strandBackLayer == null or g.her == null:
		return false
	fluids = ClassDB.instantiate(&"SDTFluids")
	_layers = [g.strandBackLayer, g.strandFrontLayer, g.cumLayer]
	for l in _layers:
		var m := FlashSprite.new()
		m.mouseEnabled = false
		l.addChild(m)
		_meshes.append(m)
	var h: Her = g.her
	var scene := container_index(g.sceneLayer)
	fluids.set_special(container_index(h.head.face), container_index(h.head.jaw), container_index(h.eye.hitBox), scene)
	_set_params()
	# after all of the tick's game logic (her movement), whenever this is first used
	Flash.tick_after.append(_tick)
	return true


func _layer_index(layer: FlashSprite) -> int:
	return maxi(0, _layers.find(layer))


## Index of a body part (or any display object strands stick to), registered on first use.
func container_index(o: FlashDisplayObject) -> int:
	if o == null:
		return -1
	if _containers.has(o):
		return _containers[o]
	var flags := 0
	var h: Her = g.her
	if h != null and h.head != null and (o == h.head or h.head.contains(o)):
		flags |= IN_HEAD
	if g.him != null and (o == g.him or o == g.him.penis):
		flags |= HIM
	if o == g.sceneLayer:
		flags |= SCENE
	if h != null and o == h.tongueContainer.tongue.tipPoint:
		flags |= TONGUE_TIP
	var i: int = fluids.add_container(o, flags)
	_containers[o] = i
	_container_objs.append(o)
	push_transforms()
	return i


func _anchor(a):
	if a == null:
		return null
	return {"container": container_index(a.container), "local": a.localPoint, "force": a.forceHit}


## Sends every body part's transform (its space -> scene space).
func push_transforms() -> void:
	if fluids == null:
		return
	var inv := g.sceneLayer.flash_global_transform().affine_inverse()
	var out: Array = []
	out.resize(_container_objs.size())
	for i in _container_objs.size():
		var o = _container_objs[i]
		out[i] = inv * o.flash_global_transform() if is_instance_valid(o) else Transform2D()
	fluids.set_transforms(out)


func _scene_rect(o: FlashDisplayObject, inv: Transform2D) -> Rect2:
	return inv * o.getBounds(null)


## The collision targets in the order Strand.collide tests them.
func _targets(inv: Transform2D) -> Array:
	var h: Her = g.her
	var out: Array = []
	var plain := func(test: FlashDisplayObject, anchor: FlashDisplayObject, force: bool, need: Array = []) -> Dictionary:
		return {"obj": test, "inv": test.flash_global_transform().affine_inverse() * inv.affine_inverse(),
			"anchor": container_index(anchor), "force": force, "need": need}
	for e in g.costumeHitElements:
		if e.showing:
			out.append(plain.call(e, e, true))
	out.append(plain.call(h.eyewear, h.eyewear, true))
	var f: Dictionary = plain.call(h.head.face, h.head.face, false)
	f["kind"] = TARGET_FACE
	f["eye"] = _scene_rect(h.eye.hitBox, inv)
	out.append(f)
	out.append(plain.call(h.head.jaw, h.head.jaw, false))
	var tongue = h.tongueContainer.tongue
	if tongue.okayToHit():
		var t: Dictionary = plain.call(tongue, tongue.tipPoint, true)
		t["kind"] = TARGET_TONGUE
		t["hit_target"] = container_index(tongue)
		out.append(t)
	var breast = h.torso.midLayer.rightBreast
	out.append(plain.call(breast.hitArea, breast, false, [_scene_rect(breast, inv)]))
	var torso := [_scene_rect(h.torso, inv)]
	var leg: Dictionary = plain.call(h.torso.leg, h.torso.leg, false, torso + [_scene_rect(h.torso.leg, inv)])
	var calf = h.torso.rightCalfContainer.calf
	leg["exclude"] = calf
	leg["exclude_inv"] = calf.flash_global_transform().affine_inverse() * inv.affine_inverse()
	out.append(leg)
	out.append(plain.call(h.torso.midLayer.chest, h.torso.midLayer.chest, false, torso))
	out.append(plain.call(h.torso.back, h.torso.back, false, torso))
	if h.penisOn:
		out.append(plain.call(h.torso.penisContainer, h.torso.penisContainer, false, torso))
	return out


func _set_params() -> void:
	fluids.set_params({"gravity": g.gravity, "friction": g.friction, "max_mass": g.maxMass,
		"mass_generate_speed": g.massGenerateSpeed, "mass_flow": g.massFlow, "max_strand_length": g.maxStrandLength,
		"kill_y": g.screenSize.y * (1.0 / g.sceneZoom) + 10.0, "floor_y": 1220.0,
		"him_ejaculating": g.him.isEjaculating() if g.him != null else false,
		"cum_rgb": Color.hex((g.cumRGB << 8) | 0xFF), "tick": Flash.tick_count})


func _tick() -> void:
	if g.gamePaused:
		return
	push_transforms()
	fluids.set_targets(_targets(g.sceneLayer.flash_global_transform().affine_inverse()))
	_set_params()
	_apply_events(fluids.tick())
	_draw()


## Draws the strands at the tick's positions: her body is not interpolated between ticks either (it is drawn inside
## the scene layer's mask viewport), so interpolating the strands would make them trail behind it.
func _draw() -> void:
	for i in _meshes.size():
		var m: Array = fluids.get_mesh(i, 1.0)
		var gr: FlashGraphics = _meshes[i].graphics
		gr.clear()
		if not (m[0] as PackedVector2Array).is_empty():
			gr.setMesh(m[0], m[1], m[2])


func _apply_events(events: Array) -> void:
	for e in events:
		match int(e[0]):
			EV_CUM_ON_FACE:
				g.her.cumOnFace()
			EV_EYE_HIT:
				g.dialogueControl.triggerState(Dialogue.CUM_IN_EYE)
				g.her.eyeHit()
			EV_EYE_CLEAR:
				g.her.eyeClearHit()
			EV_TONGUE_CUM_HIT:
				g.her.tongueContainer.tongue.cumHit()
			EV_TONGUE_CUM_REMOVED:
				g.her.tongueContainer.tongue.cumRemoved()
				g.her.fillMouth(true)
			EV_DROPLET:
				var cum: bool = e[4]
				var drop := Droplet.new(e[1], e[2], 1, 0.02, e[3], cum)
				(g.cumLayer if cum else g.strandFrontLayer).addChild(drop)
