class_name CharacterView
extends Node3D
## CharacterView is one soldier drawn with the shared CharacterAsset. It holds
## only its own state: the clip, the flinch of a hit, and once it falls, its
## ragdoll and then its frozen pose (ARCHITECTURE.md, 10.1–10.2).

## A soldier walks from WALK_SPEED and runs from RUN_SPEED, in m/s.
const WALK_SPEED := 0.15
const RUN_SPEED := 6.0
## BLEND_TIME is how long a change of clip takes.
const BLEND_TIME := 0.2

var asset: CharacterAsset
var skeleton: Skeleton3D
var player: AnimationPlayer
var body: MeshInstance3D
var clip := CharacterAsset.Clip.IDLE
var flinch: FlinchModifier
## ragdoll is the ragdoll of the pool while the soldier falls; fallen tells
## it lies as a ragdoll or a frozen body.
var ragdoll: Ragdoll
var fallen := false
## fallen_at is where the hips of a fallen soldier are.
var fallen_at := Vector3.ZERO
var _model: Node3D
var _ragdoll_age := 0.0
var _base_locals: Array[Transform3D] = []


func setup(character: CharacterAsset, model: Node3D) -> void:
	asset = character
	_model = model
	_model.scale = Vector3.ONE * asset.scale
	_model.position = asset.offset
	add_child(_model)
	skeleton = _model.find_child("Skeleton3D", true, false)
	player = _model.find_child("AnimationPlayer", true, false)
	body = skeleton.get_node("Body")
	flinch = FlinchModifier.new()
	flinch.setup(asset)
	skeleton.add_child(flinch)
	player.play(CharacterAsset.CLIPS[clip])


## set_tint paints the accent parts of the soldier.
func set_tint(color: Color) -> void:
	body.set_instance_shader_parameter("team_color", color)


## face places the soldier with its feet at position, looking along yaw: the
## model looks along +Z, a soldier of yaw zero along -Z.
func face(position: Vector3, yaw: float) -> void:
	transform = Transform3D(Basis(Vector3.UP, PI - yaw), position)


## animate advances the animation of a soldier moving at speed.
func animate(delta: float, speed: float) -> void:
	if fallen:
		return
	flinch.advance(delta)
	var next := CharacterAsset.Clip.IDLE
	if speed >= RUN_SPEED:
		next = CharacterAsset.Clip.RUNNING
	elif speed >= WALK_SPEED:
		next = CharacterAsset.Clip.WALKING
	if next != clip:
		var phase := 0.0
		if clip != CharacterAsset.Clip.IDLE and next != CharacterAsset.Clip.IDLE:
			# Walking and running are the same gait: the phase carries over.
			phase = player.current_animation_position / asset.periods[clip]
		player.play(CharacterAsset.CLIPS[next], BLEND_TIME)
		if phase > 0:
			player.seek(phase * asset.periods[next])
		clip = next


## set_detail lets the animation run every frame near the camera and less
## often far away, where it does not show.
func set_detail(full: bool) -> void:
	var mode := AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE if full else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	if player.callback_mode_process != mode:
		player.callback_mode_process = mode


## hit makes a standing soldier flinch from a hit on a ragdoll part by a shot
## travelling along direction.
func hit(part: int, direction: Vector3) -> void:
	if not fallen:
		flinch.kick(part, skeleton.global_basis.orthonormalized().inverse() * direction)


## fall knocks the soldier down from its current pose: a ragdoll of the pool
## takes the pose of its bones, the velocity of the soldier and the strike.
func fall(pool: RagdollPool, velocity: Vector3, strike: Strike) -> bool:
	if fallen:
		return true
	var taken := pool.take()
	if taken == null:
		return false
	player.active = false
	flinch.active = false
	_base_locals.clear()
	for i in skeleton.get_bone_count():
		_base_locals.append(skeleton.get_bone_pose(i))
	var rig := pool.rig
	var poses: Array[Transform3D] = []
	for i in rig.parts.size():
		poses.append(rig.bone_world(skeleton, rig.parts[i].bone) * rig.parts[i].to_part)
	taken.start(poses, velocity, strike)
	ragdoll = taken
	fallen = true
	_ragdoll_age = 0.0
	fallen_at = poses[RagdollRig.Part.HIPS].origin
	return true


## copy_pose takes the pose of another soldier's skeleton, to fall as it
## stands.
func copy_pose(other: CharacterView) -> void:
	player.active = false
	for i in skeleton.get_bone_count():
		skeleton.set_bone_pose(i, other.skeleton.get_bone_pose(i))


## ragdoll_active reports whether the fall is still simulated.
func ragdoll_active() -> bool:
	return ragdoll != null


## update_fall moves the bones to the ragdoll; once the bodies sleep, or after
## RagdollPool.TIME unless it still flies, and after MAX_TIME in any case, the
## pose freezes and the ragdoll goes back to the pool.
func update_fall(delta: float) -> void:
	if ragdoll == null:
		return
	var transforms := ragdoll.transforms()
	_apply(transforms)
	_ragdoll_age += delta
	var hips: Vector3 = transforms[RagdollRig.Part.HIPS].origin
	var speed := 0.0 if delta <= 0 else hips.distance_to(fallen_at) / delta
	fallen_at = hips
	if (_ragdoll_age >= RagdollPool.MIN_TIME and ragdoll.sleeping()) or (_ragdoll_age >= RagdollPool.TIME and speed < RagdollPool.FLYING_SPEED) or _ragdoll_age >= RagdollPool.MAX_TIME:
		freeze()


## freeze ends the physics of a fallen soldier, whose ragdoll goes back to the
## pool; it keeps its last pose.
func freeze() -> void:
	if ragdoll != null:
		ragdoll.give_back()
		ragdoll = null


## stand_up returns a fallen soldier to its animation.
func stand_up() -> void:
	freeze()
	if fallen:
		fallen = false
		player.active = true
		flinch.active = true
		for i in _base_locals.size():
			skeleton.set_bone_pose(i, _base_locals[i])


## _apply moves the bones with ragdoll parts to their bodies. The other bones
## keep their pose relative to their parents, so the hands follow the forearms
## and the head's children the head; only the ancestors of parts need a place,
## to set the parts' poses relative to them. The ancestors of the hips, the
## root and the body, go with the hips as they stood over them: the shell of
## the torso hangs from the body and falls with it.
func _apply(transforms: Array[Transform3D]) -> void:
	var rig := ragdoll.pool.rig
	var to_skeleton := skeleton.global_transform.affine_inverse()
	var rotation := skeleton.global_basis.orthonormalized().inverse()
	if _globals.size() != skeleton.get_bone_count():
		_globals.resize(skeleton.get_bone_count())
	var below := rig.parts[RagdollRig.Part.HIPS].bone
	_globals[below] = _global_of(rig, transforms, RagdollRig.Part.HIPS, to_skeleton, rotation)
	for bone in rig.above_hips:
		_globals[bone] = _globals[below] * _base_locals[below].affine_inverse()
		below = bone
	for bone in rig.moved:
		var parent := skeleton.get_bone_parent(bone)
		var part := rig.part_of_bone[bone]
		var global: Transform3D
		if rig.is_above_hips[bone] == 1:
			global = _globals[bone]
		elif part < 0:
			_globals[bone] = _globals[parent] * _base_locals[bone]
			continue
		else:
			global = _global_of(rig, transforms, part, to_skeleton, rotation)
			_globals[bone] = global
		var local := global if parent < 0 else _globals[parent].affine_inverse() * global
		skeleton.set_bone_pose_position(bone, local.origin)
		skeleton.set_bone_pose_rotation(bone, local.basis.get_rotation_quaternion())


## _global_of is where the bone of a part is in the space of the skeleton.
func _global_of(rig: RagdollRig, transforms: Array[Transform3D], part: int, to_skeleton: Transform3D, rotation: Basis) -> Transform3D:
	var world: Transform3D = transforms[part] * rig.parts[part].to_part.affine_inverse()
	return Transform3D(rotation * world.basis, to_skeleton * world.origin)


var _globals: Array[Transform3D] = []


## Strike is the blow that fells a soldier: an impulse into one part of its
## ragdoll at a point, in N·s. A negative part strikes nothing.
class Strike:
	var part := -1
	var point := Vector3.ZERO
	var impulse := Vector3.ZERO

	func _init(struck: int, at: Vector3, blow: Vector3) -> void:
		part = struck
		point = at
		impulse = blow
