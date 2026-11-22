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
var grounded_feet: GroundedFeet
var armed_pose: ArmedPose
## ragdoll is the ragdoll of the pool while the soldier falls; fallen tells
## it lies as a ragdoll or a frozen body.
var ragdoll: Ragdoll
var fallen := false
## fallen_at is where the hips of a fallen soldier are.
var fallen_at := Vector3.ZERO
var _model: Node3D
var _shot_age := 1.0
var _aim := 0.0
var _sprint := 0.0
var _ragdoll_age := 0.0
var _base_locals: Array[Transform3D] = []


func setup(character: CharacterAsset, model: Node3D) -> void:
	asset = character
	_model = model
	add_child(_model)
	skeleton = _model.find_child("Skeleton3D", true, false)
	player = _model.find_child("AnimationPlayer", true, false)
	body = skeleton.get_node("Body")
	flinch = FlinchModifier.new()
	flinch.setup(asset)
	skeleton.add_child(flinch)
	grounded_feet = GroundedFeet.new()
	grounded_feet.setup(asset)
	grounded_feet.active = false
	skeleton.add_child(grounded_feet)
	armed_pose = ArmedPose.new()
	armed_pose.setup(asset)
	armed_pose.active = false
	skeleton.add_child(armed_pose)
	player.play(CharacterAsset.CLIPS[clip])


## set_tint paints the accent parts of the soldier.
func set_tint(color: Color) -> void:
	body.set_instance_shader_parameter("team_color", color)


## face places the soldier with its feet at position, looking along yaw: the
## model looks along +Z, a soldier of yaw zero along -Z.
func face(position: Vector3, yaw: float) -> void:
	transform = Transform3D(Basis(Vector3.UP, PI - yaw), position)


## animate advances the animation of a soldier moving at speed.
func animate(delta: float, speed: float, crouched := false, aiming := false) -> void:
	if fallen:
		return
	flinch.advance(delta)
	_shot_age += delta
	_aim = move_toward(_aim, 1.0 if aiming or _shot_age < 0.24 else 0.0, 8.0 * delta)
	_sprint = move_toward(_sprint, 1.0 if not crouched and speed >= RUN_SPEED else 0.0, 6.5 * delta)
	var next := CharacterAsset.Clip.IDLE
	if crouched:
		next = CharacterAsset.Clip.CROUCH_WALKING if speed >= WALK_SPEED else CharacterAsset.Clip.CROUCH_IDLE
	elif speed >= RUN_SPEED:
		next = CharacterAsset.Clip.RUNNING
	elif speed >= WALK_SPEED:
		next = CharacterAsset.Clip.WALKING
	if next != clip:
		var phase := 0.0
		const WALKING_CLIPS := [CharacterAsset.Clip.WALKING, CharacterAsset.Clip.RUNNING, CharacterAsset.Clip.CROUCH_WALKING]
		if clip in WALKING_CLIPS and next in WALKING_CLIPS:
			phase = player.current_animation_position / asset.periods[clip]
		var stance_changed := crouched != (clip >= CharacterAsset.Clip.CROUCH_IDLE)
		# Stance is an exact tick state shared by shots and collision.
		player.play(CharacterAsset.CLIPS[next], 0.0 if stance_changed else BLEND_TIME)
		if phase > 0:
			player.seek(phase * asset.periods[next])
		if stance_changed:
			player.advance(0.0)
		clip = next
	if clip in [CharacterAsset.Clip.IDLE, CharacterAsset.Clip.CROUCH_IDLE]:
		player.speed_scale = 1.0
	else:
		player.speed_scale = minf(speed / asset.stride_speed(clip), 1.65)

## Start a brief shoulder and weapon response for visible third-person shots.
func fired() -> void:
	_aim = maxf(_aim, 0.72)
	_shot_age = 0.0


## Both hands, the displayed weapon and muzzle effects share this transform.
## The shoulder carries the stock as the torso leans under the rifle.
func carry(weapons: ViewModel, kind: int, pitch: float) -> Transform3D:
	armed_pose.active = kind != WeaponTuning.Kind.NONE and not fallen
	if not armed_pose.active:
		return global_transform
	var shoulder: Transform3D = skeleton.get_bone_global_pose(asset.bones["UpperArm.R"])
	var running := _sprint * (1.0 - _aim)
	var kick := clampf(1.0 - _shot_age / 0.16, 0.0, 1.0)
	var offset := Vector3(0.118 + 0.045 * running, lerpf(-0.125, 0.062, _aim) - 0.079 * running, 0.28 - 0.04 * running)
	var at := shoulder.origin + offset - Vector3(0.0, 0.0, 0.05 * kick)
	var looking := clampf(pitch, -1.08, 1.08)
	var elevation := looking - lerpf(0.18, 0.0, _aim) - 0.20 * running + 0.076 * kick
	if clip >= CharacterAsset.Clip.CROUCH_IDLE:
		elevation = maxf(elevation, -0.67)
	var turn := Basis(Vector3.UP, 0.05 * (1.0 - _aim) + 0.29 * running)
	# The mesh faces -Z, while the character and elevation are authored along +Z.
	var rifle := turn * Basis(Vector3.RIGHT, -elevation) * Basis(Vector3.UP, PI)
	armed_pose.weapon = Transform3D(rifle.scaled(Vector3.ONE * ViewModel.HELD_SCALE), at)
	armed_pose.trigger = weapons.held_grip(kind, false)
	armed_pose.support = weapons.held_grip(kind, true)
	armed_pose.aim = _aim
	armed_pose.pitch = looking
	armed_pose.recoil = kick
	return skeleton.global_transform * armed_pose.weapon


## set_detail lets the animation run every frame near the camera and less
## often far away, where it does not show.
func set_detail(full: bool) -> void:
	var mode := AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE if full else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	if player.callback_mode_process != mode:
		player.callback_mode_process = mode


## Supply terrain for a grounded detail pose. Airborne and coarse poses use
## their authored leg motion, and retain no correction from the last frame.
func set_foot_terrain(terrain: Terrain) -> void:
	grounded_feet.terrain = terrain
	grounded_feet.active = terrain != null and not fallen


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
	if grounded_feet.active:
		grounded_feet.place_boots()
		grounded_feet.active = false
	if armed_pose.active:
		armed_pose.apply_pose()
		armed_pose.active = false
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
	if other.armed_pose.active:
		armed_pose.weapon = other.armed_pose.weapon
		armed_pose.trigger = other.armed_pose.trigger
		armed_pose.support = other.armed_pose.support
		armed_pose.aim = other.armed_pose.aim
		armed_pose.pitch = other.armed_pose.pitch
		armed_pose.recoil = other.armed_pose.recoil
		armed_pose.active = true


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
		_shot_age = 1.0
		_aim = 0.0
		_sprint = 0.0
		player.active = true
		flinch.active = true
		for i in _base_locals.size():
			skeleton.set_bone_pose(i, _base_locals[i])
		player.advance(0.0)


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
