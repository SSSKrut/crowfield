class_name Ragdoll
extends RefCounted
## Ragdoll is one set of the rig's bodies and joints. The joints keep their
## frames in the space of each body, so made in the reference pose they hold
## in any pose the ragdoll starts from. Its parts do not collide with each
## other, nor with living soldiers or shots: they are cosmetic.

var pool: RagdollPool
var _bodies: Array[RID] = []
var _joints: Array[RID] = []
var _transforms: Array[Transform3D] = []


func _init(owner: RagdollPool, shapes: Array[RID]) -> void:
	pool = owner
	var rig := pool.rig
	for i in rig.parts.size():
		var part := rig.parts[i]
		var body := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_RIGID)
		PhysicsServer3D.body_add_shape(body, shapes[i])
		PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_MASS, part.mass)
		PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_FRICTION, 0.8)
		PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP_MODE, PhysicsServer3D.BODY_DAMP_MODE_REPLACE)
		PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP_MODE, PhysicsServer3D.BODY_DAMP_MODE_REPLACE)
		PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_LINEAR_DAMP, 0.08)
		PhysicsServer3D.body_set_param(body, PhysicsServer3D.BODY_PARAM_ANGULAR_DAMP, 0.15)
		PhysicsServer3D.body_set_collision_layer(body, Game.LAYER_COSMETIC)
		PhysicsServer3D.body_set_collision_mask(body, Game.LAYER_STATIC | Game.LAYER_COSMETIC)
		PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, part.reference)
		PhysicsServer3D.body_set_space(body, pool.space)
		_bodies.append(body)
		_transforms.append(part.reference)
	for i in _bodies.size():
		for k in range(i + 1, _bodies.size()):
			PhysicsServer3D.body_add_collision_exception(_bodies[i], _bodies[k])
	for i in rig.parts.size():
		var part := rig.parts[i]
		if part.parent < 0 or part.joint == RagdollRig.Joint.NONE:
			continue
		var parent := rig.parts[part.parent]
		var joint := PhysicsServer3D.joint_create()
		match part.joint:
			RagdollRig.Joint.POINT:
				PhysicsServer3D.joint_make_pin(joint, _bodies[part.parent], parent.reference.affine_inverse() * part.pivot,
					_bodies[i], part.reference.affine_inverse() * part.pivot)
			RagdollRig.Joint.HINGE:
				# A hinge turns about the Z axis of its frame.
				var frame := Transform3D(_frame(part.axis, 2), part.pivot)
				PhysicsServer3D.joint_make_hinge(joint, _bodies[part.parent], parent.reference.affine_inverse() * frame,
					_bodies[i], part.reference.affine_inverse() * frame)
				PhysicsServer3D.hinge_joint_set_flag(joint, PhysicsServer3D.HINGE_JOINT_FLAG_USE_LIMIT, true)
				PhysicsServer3D.hinge_joint_set_param(joint, PhysicsServer3D.HINGE_JOINT_LIMIT_LOWER, -part.limit)
				PhysicsServer3D.hinge_joint_set_param(joint, PhysicsServer3D.HINGE_JOINT_LIMIT_UPPER, part.limit)
			RagdollRig.Joint.SWING_TWIST:
				# A cone twists about the X axis of its frame and swings within
				# the cone around it.
				var frame := Transform3D(_frame(part.axis, 0), part.pivot)
				PhysicsServer3D.joint_make_cone_twist(joint, _bodies[part.parent], parent.reference.affine_inverse() * frame,
					_bodies[i], part.reference.affine_inverse() * frame)
				PhysicsServer3D.cone_twist_joint_set_param(joint, PhysicsServer3D.CONE_TWIST_JOINT_SWING_SPAN, part.limit)
				PhysicsServer3D.cone_twist_joint_set_param(joint, PhysicsServer3D.CONE_TWIST_JOINT_TWIST_SPAN, 0.5 * part.limit)
		PhysicsServer3D.joint_disable_collisions_between_bodies(joint, true)
		_joints.append(joint)
	for body in _bodies:
		PhysicsServer3D.body_set_space(body, RID())


## _frame is a basis whose axis of the given index points along axis.
static func _frame(axis: Vector3, index: int) -> Basis:
	var along := axis.normalized()
	var other := Vector3.UP if absf(along.y) < 0.9 else Vector3.RIGHT
	var first := other.cross(along).normalized()
	var second := along.cross(first)
	match index:
		0:
			return Basis(along, first, second)
		1:
			return Basis(second, along, first)
	return Basis(first, second, along)


## start puts the bodies in a pose, gives them the soldier's velocity and the
## strike, and adds them to the space.
func start(poses: Array[Transform3D], velocity: Vector3, strike: CharacterView.Strike) -> void:
	for i in _bodies.size():
		PhysicsServer3D.body_set_state(_bodies[i], PhysicsServer3D.BODY_STATE_TRANSFORM, poses[i])
		PhysicsServer3D.body_set_state(_bodies[i], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)
		PhysicsServer3D.body_set_state(_bodies[i], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_space(_bodies[i], pool.space)
		PhysicsServer3D.body_set_state(_bodies[i], PhysicsServer3D.BODY_STATE_SLEEPING, false)
		_transforms[i] = poses[i]
	if strike != null and strike.part >= 0 and strike.part < _bodies.size():
		var impulse := strike.impulse
		var limit := pool.rig.parts[strike.part].mass * RagdollPool.MAX_STRIKE_SPEED
		if impulse.length() > limit:
			impulse = impulse * (limit / impulse.length())
		PhysicsServer3D.body_apply_impulse(_bodies[strike.part], impulse, strike.point - poses[strike.part].origin)


## transforms are where the parts are now, in the order of the rig.
func transforms() -> Array[Transform3D]:
	for i in _bodies.size():
		_transforms[i] = PhysicsServer3D.body_get_state(_bodies[i], PhysicsServer3D.BODY_STATE_TRANSFORM)
	return _transforms


## sleeping reports whether every body has come to rest.
func sleeping() -> bool:
	for body in _bodies:
		if not PhysicsServer3D.body_get_state(body, PhysicsServer3D.BODY_STATE_SLEEPING):
			return false
	return true


## give_back takes the bodies out of the space and returns the ragdoll to its
## pool.
func give_back() -> void:
	for body in _bodies:
		PhysicsServer3D.body_set_space(body, RID())
	pool._give(self)


func free_bodies() -> void:
	for joint in _joints:
		PhysicsServer3D.free_rid(joint)
	for body in _bodies:
		PhysicsServer3D.free_rid(body)
	_joints.clear()
	_bodies.clear()
