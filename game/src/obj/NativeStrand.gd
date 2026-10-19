class_name NativeStrand
extends RefCounted
## Port addition: the game's handle to a strand simulated by the native fluid system (SDTFluids, see
## StrandControl). It offers what the game calls on a Strand (her drool and nostril spray, his spurts). A killed
## strand's handle keeps working harmlessly, as a dead Strand did in Flash.

var id := -1
var _fluids = null


func _init(p_fluids = null, p_id := -1) -> void:
	_fluids = p_fluids
	id = p_id


var myGravity: float:
	get:
		return _fluids.get_gravity(id)
	set(value):
		_fluids.set_gravity(id, value)

var collisionFree: int:
	get:
		return _fluids.get_collision_free(id)
	set(value):
		_fluids.set_collision_free(id, value)

var alive: bool:
	get:
		return _fluids.is_alive(id)


func insertLink(v: Vector2, delay: int, mass: float) -> void:
	_fluids.insert_link(id, v, delay, mass)


func detachSourceLink(v: Vector2, delay: int = 0) -> void:
	_fluids.detach_source_link(id, v, delay)


func addSourceLink(p: Vector2, container: FlashDisplayObject, cum: bool = true) -> void:
	g.strandControl.push_transforms()
	_fluids.add_source_link(id, p, g.strandControl.container_index(container), cum)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _fluids != null:
		_fluids.release(id)
