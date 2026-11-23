class_name RagdollPool
extends RefCounted
## RagdollPool lends ragdolls of a rig in a physics space, at most LIMIT at
## once. Loading creates all bodies, shapes and joints, so a fall allocates
## none of them. A ragdoll of the pool lies outside the
## space until it is lent.

## LIMIT is how many ragdolls are simulated at once.
const LIMIT := 64
## A ragdoll freezes once its bodies sleep, or after TIME unless it is still
## flying, and after MAX_TIME in any case. A frozen body keeps its pose and
## costs no physics.
const TIME := 4.0
## MIN_TIME passes before a ragdoll may freeze for sleeping: its bodies only
## wake with the first step of the physics.
const MIN_TIME := 0.3
const MAX_TIME := 8.0
const FLYING_SPEED := 1.0
## A strike gives the part it hits at most MAX_STRIKE_SPEED m/s: a light
## forearm struck as hard as the body would fling the whole ragdoll away.
const MAX_STRIKE_SPEED := 4.0

var rig: RagdollRig
var space: RID
var _shapes: Array[RID] = []
var _idle: Array[Ragdoll] = []
var _all: Array[Ragdoll] = []


func _init(ragdoll_rig: RagdollRig, physics_space: RID) -> void:
	rig = ragdoll_rig
	space = physics_space
	for part in rig.parts:
		var shape: RID
		match part.shape:
			RagdollRig.Shape.BOX:
				shape = PhysicsServer3D.box_shape_create()
				PhysicsServer3D.shape_set_data(shape, part.size)
			RagdollRig.Shape.CAPSULE:
				shape = PhysicsServer3D.capsule_shape_create()
				PhysicsServer3D.shape_set_data(shape, {"radius": part.size.x, "height": 2 * (part.size.x + part.size.y)})
			_:
				shape = PhysicsServer3D.sphere_shape_create()
				PhysicsServer3D.shape_set_data(shape, part.size.x)
		_shapes.append(shape)


## fill makes every ragdoll of the pool now, while loading.
func fill() -> void:
	while _all.size() < LIMIT:
		var ragdoll := Ragdoll.new(self, _shapes)
		_all.append(ragdoll)
		_idle.append(ragdoll)


func full() -> bool:
	return _idle.is_empty() and _all.size() >= LIMIT


## lent is how many ragdolls are simulated now; made how many exist.
func lent() -> int:
	return _all.size() - _idle.size()


func made() -> int:
	return _all.size()


## take lends a ragdoll, or returns null when every one is lent.
func take() -> Ragdoll:
	if _idle.is_empty():
		if _all.size() >= LIMIT:
			return null
		var ragdoll := Ragdoll.new(self, _shapes)
		_all.append(ragdoll)
		return ragdoll
	return _idle.pop_back()


func _give(ragdoll: Ragdoll) -> void:
	_idle.append(ragdoll)


func close() -> void:
	for ragdoll in _all:
		ragdoll.free_bodies()
	for shape in _shapes:
		PhysicsServer3D.free_rid(shape)
	_all.clear()
	_idle.clear()
	_shapes.clear()
