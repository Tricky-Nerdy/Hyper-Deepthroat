class_name Sweat
extends FlashMovieClip
## Port of obj.Sweat: sweat droplets that grow, slide over body parts (following their shape with hit tests),
## merge, and drip off.

static var debug = null
const MAX_DROPLETS := 50
static var currentDroplets: int = 0
static var parentPos: Dictionary = {}
static var parentLastPos: Dictionary = {}
static var parentSpeed: Dictionary = {}
static var parentLastSpeed: Dictionary = {}
static var parentAccel: Dictionary = {}
static var parentDown: Dictionary = {}
static var sweatGroups: Dictionary = {}
static var staticPrepComplete := false
static var staticTickDone := false

const nearDist := 4.0
const freeGravity := 3.0
const attachedGravity := 0.15
const friction := 0.9
var predictDist: float = 0.8
var sweatParent: FlashSprite
var parentsToCheck: Array = []
var parentChildren: Array = []
var onChild: FlashSprite
var notOnParent := false
var attached := false
var dripping := false
var justDetached := false
var localPoint := Vector2()
var speed := Vector2()
var globalPoint := Vector2()
var predictToggle: int = 0
var gVec := Vector2()
var sVec := Vector2()
var lastVelocity: float = 0.0
var velocity: float = NAN
var mass: float = 0.1
var maxMass: float = 1.2
var leftPush: float = 0.0
var rightPush: float = 0.0


func _init(container: FlashSprite = null, p: Vector2 = Vector2.ZERO, spread: Vector2 = Vector2.ZERO,
		others: Array = []) -> void:
	super()
	if container == null:
		return
	if currentDroplets < MAX_DROPLETS and g.sweat:
		currentDroplets += 1
		parentsToCheck = others if others != null else []
		p.x += ((randf() + randf() + randf()) / 3.0 - 0.5) * spread.x
		p.y += ((randf() + randf() + randf()) / 3.0 - 0.5) * spread.y
		x = p.x
		y = p.y
		localPoint = Vector2(x, y)
		alpha = 0
		predictDist = 7.0 + randf() * 6.0
		maxMass = 0.8 + randf() * 0.4
		blendMode = "overlay"
		addEventListener(FlashEvent.ENTER_FRAME, tick)
		if not staticPrepComplete:
			parentPos = {}
			parentLastPos = {}
			parentSpeed = {}
			parentLastSpeed = {}
			parentAccel = {}
			parentDown = {}
			sweatGroups = {}
			staticPrepComplete = true
		addToParent(container)
	else:
		# Flash would garbage-collect the unused droplet; a Godot node must be freed explicitly.
		queue_free()


## Port: a droplet's shape tests ask whether a point is on the body part's skin; many droplets ask the same body part
## every tick, so they use the native test against the part flattened once per tick (SDTNative.hit_flat), which
## leaves droplets out (the original left out only the testing droplet).
static var _flat: bool = FlashDisplayObject.native and ClassDB.class_has_method(&"SDTNative", &"hit_flat")


static func _hit(o: FlashDisplayObject, px: float, py: float) -> bool:
	if _flat:
		var lp := o.flash_global_transform().affine_inverse() * Vector2(px, py)
		return ClassDB.class_call_static(&"SDTNative", &"hit_flat", o, lp, Flash.tick_count)
	return o.hitTestPoint(px, py, true)


static func clearDroplets() -> void:
	if _sys != null:
		_sys.clear()
		for b in _batches.values():
			b.set_drops(PackedFloat32Array())
	for group in sweatGroups.values():
		for s in group.duplicate():
			s.kill()
	sweatGroups = {}


# ---------------------------------------------------------------- native droplets

## Port: with the native extension the droplets are simulated by SDTSweat (native/src/sweat.cpp) as plain data and
## drawn by one SweatBatch per body part, instead of a display object, a listener and a screen copy per droplet.
## The game creates droplets with spawn(); without the extension it makes Sweat objects as in the original.
static var native_enabled: bool = ClassDB.class_exists(&"SDTSweat") and not "--nonative" in OS.get_cmdline_user_args()
static var _sys = null                 # SDTSweat
static var _cont: Dictionary = {}      # display object -> container index
static var _cont_objs: Array = []
static var _batches: Dictionary = {}   # container index -> SweatBatch


## A new droplet on `container` near p (its space), spread at random, that may land on `others` when it falls
## (Sweat.new in the original).
static func spawn(container: FlashSprite, p: Vector2, spread: Vector2, others: Array) -> void:
	if not native_enabled:
		Sweat.new(container, p, spread, others)
		return
	if not g.sweat:
		return
	if _sys == null:
		_sys = ClassDB.instantiate(&"SDTSweat")
		Flash.tick_after.append(_native_tick)   # after all of the tick's game logic (her movement)
	var parent := _index(container, true)
	var o := PackedInt32Array()
	for c in others:
		o.append(_index(c, true))
	_push()
	_sys.spawn(parent, p, spread, o, MAX_DROPLETS)


static func droplet_count() -> int:
	return _sys.count() if _sys != null else currentDroplets


## Index of a body part; with_children: (re)sends its sprite children (the parts a droplet can slide onto).
static func _index(o: FlashDisplayObject, with_children := false) -> int:
	var i: int
	if _cont.has(o):
		i = _cont[o]
	else:
		i = _sys.add_container(o)
		_cont[o] = i
		_cont_objs.append(o)
	if with_children and o is FlashSprite:
		var kids := PackedInt32Array()
		for c in o._children:
			if c is FlashSprite and not (c is Sweat) and not (c is SweatBatch):
				kids.append(_index(c))
		var p: FlashDisplayObject = o._flash_parent
		_sys.set_children(i, kids, p.get_instance_id() if p != null else 0, p.getChildIndex(o) if p != null else 0)
	return i


## Stage transforms and summed rotations of the body parts.
static func _push() -> void:
	var xf: Array = []
	var rot := PackedFloat32Array()
	var own := PackedFloat32Array()
	xf.resize(_cont_objs.size())
	rot.resize(_cont_objs.size())
	own.resize(_cont_objs.size())
	for i in _cont_objs.size():
		var o = _cont_objs[i]
		if not is_instance_valid(o):
			xf[i] = Transform2D()
			continue
		xf[i] = o.flash_global_transform()
		own[i] = o.rotation_degrees
		var r := 0.0
		var a: FlashDisplayObject = o
		while a != null and a != Flash.stage:
			r += a.rotation_degrees
			a = a._flash_parent
		rot[i] = r
	_sys.set_transforms(xf, rot, own)


static func _native_tick() -> void:
	if g.gamePaused:
		return
	_push()
	_sys.tick(Flash.tick_count)
	var used := {}
	for c in _sys.parents_in_use():
		used[c] = true
		var b: SweatBatch = _batches.get(c)
		var part = _cont_objs[c]
		if b == null:
			b = SweatBatch.new()
			_batches[c] = b
		if is_instance_valid(part) and (b._flash_parent != part or part._children.back() != b):
			part.addChild(b)   # on top of the part, as the droplets re-added themselves
		b.set_drops(_sys.get_draw(c))
	for c in _batches:
		if not used.has(c):
			_batches[c].set_drops(PackedFloat32Array())


static func staticTick() -> void:
	parentAccel = {}
	parentDown = {}
	staticTickDone = true


func addToParent(container: FlashSprite) -> void:
	sweatParent = container
	sweatParent.addChild(self)
	parentChildren = []
	for i in sweatParent.numChildren:
		var c := sweatParent.getChildAt(i)
		if c is FlashSprite and not (c is Sweat):
			parentChildren.append(c)
	onChild = sweatParent
	jumpToChild()
	if not sweatGroups.has(sweatParent):
		sweatGroups[sweatParent] = []
	sweatGroups[sweatParent].append(self)


func kill() -> void:
	if sweatGroups.has(sweatParent) and sweatGroups[sweatParent].has(self):
		removeEventListener(FlashEvent.ENTER_FRAME, tick)
		if parent:
			parent.removeChild(self)
		sweatGroups[sweatParent].erase(self)
		currentDroplets -= 1
		# kill() can run mid-tick, after which tick() re-adds the droplet to its parent (as in the original), so
		# only free it if it is really off the display list once the tick is over.
		_free_if_detached.call_deferred()


func _free_if_detached() -> void:
	if is_instance_valid(self) and _flash_parent == null:
		queue_free()


func jumpToChild() -> void:
	globalPoint = sweatParent.localToGlobal(Vector2(x, y))
	var ahead: Vector2 = onChild.localToGlobal(localPoint + speed)
	for c in parentChildren:
		if c.hitTestPoint(globalPoint.x, globalPoint.y, false):
			if _hit(c, globalPoint.x, globalPoint.y):
				onChild = c
				ahead = onChild.globalToLocal(ahead)
				localPoint = onChild.globalToLocal(globalPoint)
				speed = ahead - localPoint
				notOnParent = true
				return
	onChild = sweatParent
	notOnParent = false
	localPoint = Vector2(x, y)
	ahead = onChild.globalToLocal(ahead)
	speed = ahead - localPoint


var currentMass: float:
	get:
		return mass


func isNear(o: Sweat) -> bool:
	return o.x >= x - nearDist * mass and o.x <= x + nearDist * mass \
		and o.y >= y - nearDist * mass and o.y <= y + nearDist * mass


func absorb(o: Sweat) -> void:
	mass = minf(maxMass, mass + o.currentMass)
	o.kill()


func _is_stage(o) -> bool:
	return o == Flash.stage


func tick() -> void:
	if g.gamePaused:
		return
	if not parentAccel.has(sweatParent):
		parentLastPos[sweatParent] = parentPos.get(sweatParent, Vector2())
		parentPos[sweatParent] = Vector2(sweatParent.x, sweatParent.y)
		parentLastSpeed[sweatParent] = parentSpeed.get(sweatParent, Vector2())
		parentSpeed[sweatParent] = parentPos[sweatParent] - parentLastPos[sweatParent]
		parentAccel[sweatParent] = parentSpeed[sweatParent] - parentLastSpeed[sweatParent]
	if not parentDown.has(sweatParent):
		var down := 180.0
		var o: FlashDisplayObject = sweatParent
		while o and not _is_stage(o):
			down -= o.rotation_degrees
			o = o.parent
		parentDown[sweatParent] = down
	if not parentDown.has(onChild):
		if _is_stage(onChild):
			parentDown[onChild] = 180.0
		else:
			parentDown[onChild] = parentDown[sweatParent] - onChild.rotation_degrees
	# Port: droplets that cannot be near even at full mass are skipped up front (the same result as testing every
	# droplet with isNear, which cost most of the tick with many droplets).
	var near: Array = []
	var p := position
	var r := nearDist * maxf(mass, maxMass)
	for s in sweatGroups[sweatParent]:
		if s != self:
			var q: Vector2 = s.position
			if q.x >= p.x - r and q.x <= p.x + r and q.y >= p.y - r and q.y <= p.y + r:
				near.append(s)
	for s in near:
		if is_instance_valid(s):
			if isNear(s):
				if s.currentMass > mass:
					s.absorb(self)
					return
				absorb(s)
	# Port: rotation, position and scale are each set once per tick (every transform change walks up the display
	# list to invalidate cached bounds, and the original set them field by field, up to 7 times per tick).
	var rot_deg: float = parentDown[sweatParent] + 180.0
	var ang: float = parentDown[onChild] * PI / 180.0
	gVec = Vector2(sin(ang), -cos(ang))
	localPoint += speed
	speed *= friction
	globalPoint = onChild.localToGlobal(localPoint)
	var newpos: Vector2 = sweatParent.globalToLocal(globalPoint) if notOnParent else localPoint
	transform = Transform2D(deg_to_rad(rot_deg), scale, skew, newpos)
	if globalPoint.y > 1000 or is_nan(globalPoint.x) or is_nan(globalPoint.y):   # port: NaN as a last resort
		kill()
		return
	lastVelocity = velocity
	velocity = sqrt(speed.x * speed.x + speed.y * speed.y)
	# Port fix: a droplet at rest has no direction (the original divided by 0 here; the NaN then spread to its
	# speed and position, and the probe loop below never ended, freezing the game).
	sVec = Vector2(speed.x / velocity, speed.y / velocity) if velocity > 0 else Vector2.ZERO
	# The droplet leaves its parent while testing the parent's shape, then rejoins on top. Port: instead of taking
	# it off the display list (slow here), the shape tests skip it, and it only moves when something is above it.
	FlashDisplayObject.hit_exclude = self
	if attached:
		var sy := 1.0 + maxf(-0.3, minf(0.3, (velocity - lastVelocity) * 0.5))
		scale = Vector2(1.0 / sy * mass, sy * mass)
		alpha = mass + 0.5
		mass = minf(maxMass, mass + randf() * 0.01)
		speed += attachedGravity * gVec * maxf(0.0, mass - 0.5)
		if _hit(sweatParent, globalPoint.x, globalPoint.y):
			leftPush *= 0.8
			rightPush *= 0.8
			if predictToggle < 1:
				predictToggle += 1
			else:
				predictToggle = 0
				var gp := globalPoint
				var pd := predictDist
				if not _hit(sweatParent, gp.x - sVec.y * pd * 2, gp.y + sVec.x * pd * 2):
					rightPush = minf(velocity * 0.4, leftPush + 0.08)
				if not _hit(sweatParent, gp.x + sVec.y * pd * 2, gp.y - sVec.x * pd * 2):
					leftPush = minf(velocity * 0.4, rightPush + 0.08)
				if not _hit(sweatParent, gp.x + sVec.x * 8 * pd - sVec.y * pd, gp.y + sVec.y * 8 * pd + sVec.x * pd):
					leftPush = minf(velocity * 0.2, leftPush + 0.08)
				if not _hit(sweatParent, gp.x + sVec.x * 8 * pd + sVec.y * pd, gp.y + sVec.y * 8 * pd - sVec.x * pd):
					rightPush = minf(velocity * 0.2, rightPush + 0.08)
				if notOnParent:
					if not _hit(onChild, gp.x, gp.y):
						jumpToChild()
				else:
					jumpToChild()
			speed.x += leftPush * sVec.y - rightPush * sVec.y
			speed.y += rightPush * sVec.x - leftPush * sVec.x
		else:
			var probe := 1.0
			var maxProbe := minf(8.0, absf(speed.y * 2.0))
			while attached:
				if absf(probe) > maxProbe:
					leftPush = 0
					rightPush = 0
					attached = false
					localPoint = Flash.stage.globalToLocal(globalPoint)
					onChild = Flash.stage
					notOnParent = true
					justDetached = true
				else:
					if _hit(sweatParent, globalPoint.x + gVec.y * probe, globalPoint.y + gVec.x * probe):
						speed.x += gVec.y * probe * 0.8
						speed.y += gVec.x * probe * 0.8
						var l := sqrt(speed.x * speed.x + speed.y * speed.y)
						if l > 0:   # port fix: see sVec above
							speed *= velocity / l
						break
					if probe > 0:
						probe = -probe
					else:
						probe = -probe + 1.0
	else:
		speed += freeGravity * gVec
		if _hit(sweatParent, globalPoint.x, globalPoint.y):
			attached = true
			speed *= 0.4
		else:
			for c in parentsToCheck.duplicate():
				if _hit(c, globalPoint.x, globalPoint.y):
					if not justDetached:
						var ahead: Vector2 = onChild.localToGlobal(localPoint + speed)
						ahead = c.globalToLocal(ahead)
						localPoint = c.globalToLocal(globalPoint)
						speed = ahead - localPoint
						x = localPoint.x
						y = localPoint.y
						attached = true
						speed *= 0.4
						sweatGroups[sweatParent].erase(self)
						addToParent(c)
						break
					if sweatParent.parent == c.parent and sweatParent.parent.getChildIndex(sweatParent) < sweatParent.parent.getChildIndex(c):
						parentsToCheck.erase(c)
		justDetached = false
	FlashDisplayObject.hit_exclude = null
	if parent != sweatParent or not _on_top():
		sweatParent.addChild(self)


## True if only other droplets are above this one in its parent (re-adding it would only reorder droplets).
func _on_top() -> bool:
	var kids: Array = sweatParent._children
	for i in range(kids.size() - 1, -1, -1):
		var c = kids[i]
		if c == self:
			return true
		if not c is Sweat:
			return false
	return false
