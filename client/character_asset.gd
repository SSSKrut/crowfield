class_name CharacterAsset
extends RefCounted
## Shared infantry geometry and animation resources. Each soldier owns its pose,
## and marks take their team's colour without adding a material or draw call.

const CLIPS := [&"Idle", &"Walking", &"Running", &"CrouchIdle", &"CrouchWalking"]
enum Clip { IDLE, WALKING, RUNNING, CROUCH_IDLE, CROUCH_WALKING }
const _PERIODS := [2.6, 0.46, 0.43, 2.0, 0.42]
const _STEP_LENGTH := [0.0, 0.98, 1.10, 0.0, 0.42]
const _STANCE_PORTION := [0.0, 0.52, 0.40, 0.0, 0.60]
const _CROUCH_HIP_SHIFT := 0.07
const _CROUCH_ANKLE_DROP := 0.32

const _SHADER := """
shader_type spatial;
instance uniform vec4 team_color : source_color = vec4(0.79, 0.58, 0.22, 1.0);

// The garment's UVs are skinned with the mesh. Grain stays on the fabric
// as the limbs bend, and fades away before it aliases at a distance.
void fragment() {
	float footprint = max(length(dFdx(UV)), length(dFdy(UV)));
	float grain_mask = 1.0 - smoothstep(0.002, 0.014, footprint);
	float fabric = 1.0 - smoothstep(0.35, 0.66, UV2.x);
	vec2 thread = sin(UV * vec2(749.0, 771.0));
	float weave = 1.0 + thread.x * thread.y * 0.11 * fabric * grain_mask;
	float panels = sin(UV.x * 13.0 + sin(UV.y * 12.0)) * sin(UV.y * 17.0);
	float wear = 1.0 + panels * mix(0.045, 0.085, fabric);
	float mottling = sin(UV.x * 12.0 + sin(UV.y * 8.7))
		+ sin(UV.y * 14.2 - cos(UV.x * 9.0))
		+ 0.5 * sin(UV.x * 19.0 + UV.y * 19.0);
	float uniform_area = 1.0 - step(0.16, UV2.x);
	float pattern = 1.0 - 0.11 * smoothstep(0.35, 1.05, mottling) * uniform_area;
	ALBEDO = mix(team_color.rgb * 0.9, COLOR.rgb * pattern, COLOR.a) * weave * wear;
	ROUGHNESS = mix(0.92, 0.58, UV2.x);
	METALLIC = smoothstep(0.52, 1.0, UV2.x) * 0.42;
}
"""

var accent := Color(0.79, 0.58, 0.22)
var bones := {}
var periods := PackedFloat32Array(_PERIODS)
var rig: RagdollRig
var _template := PackedScene.new()


static func load_asset() -> CharacterAsset:
	var asset := CharacterAsset.new()
	asset._build()
	return asset


func _build() -> void:
	var root := Node3D.new()
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	root.add_child(skeleton)
	skeleton.owner = root

	_bone(skeleton, "Hips", "", Vector3(0, 0.94, 0))
	_bone(skeleton, "Abdomen", "Hips", Vector3(0, 1.04, 0))
	_bone(skeleton, "Torso_2", "Abdomen", Vector3(0, 1.16, 0))
	_bone(skeleton, "Neck", "Torso_2", Vector3(0, 1.48, 0))
	_bone(skeleton, "Head_2", "Neck", Vector3(0, 1.55, 0))
	for side in ["L", "R"]:
		var sign_x := 1.0 if side == "L" else -1.0
		_bone(skeleton, "UpperLeg." + side, "Hips", Vector3(0.118 * sign_x, 0.92, 0))
		_bone(skeleton, "LowerLeg." + side, "UpperLeg." + side, Vector3(0.118 * sign_x, 0.52, 0.028))
		_bone(skeleton, "Foot." + side, "LowerLeg." + side, Vector3(0.118 * sign_x, 0.12, 0))
		_bone(skeleton, "UpperArm." + side, "Torso_2", Vector3(0.23 * sign_x, 1.415, 0))
		var elbow := Vector3(0.20, 1.22, 0.22) if side == "L" else Vector3(-0.255, 1.155, 0.105)
		_bone(skeleton, "LowerArm." + side, "UpperArm." + side, elbow)
		var palm := Vector3(-0.075, 1.215, 0.515) if side == "L" else Vector3(-0.085, 1.205, 0.26)
		_bone(skeleton, "Palm1." + side, "LowerArm." + side, palm)

	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = InfantryMesh.new().build(skeleton)
	body.skin = skeleton.create_skin_from_rest_transforms()
	var shader := Shader.new()
	shader.code = _SHADER
	var material := ShaderMaterial.new()
	material.shader = shader
	body.material_override = material
	skeleton.add_child(body)
	body.owner = root
	body.skeleton = NodePath("..")

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	player.owner = root
	var library := AnimationLibrary.new()
	for clip in CLIPS.size():
		library.add_animation(CLIPS[clip], _clip(skeleton, clip))
	player.add_animation_library("", library)
	_template.pack(root)
	root.free()


func _bone(skeleton: Skeleton3D, name: String, parent: String, position: Vector3) -> void:
	var index := skeleton.get_bone_count()
	var parent_index := bones.get(parent, -1) as int
	skeleton.add_bone(name)
	skeleton.set_bone_parent(index, parent_index)
	var local := position if parent_index < 0 else position - skeleton.get_bone_global_rest(parent_index).origin
	skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, local))
	skeleton.set_bone_pose_position(index, local)
	bones[name] = index


## In-place clips share the same leg phase, so switching pace preserves the
## stride. The shoulders stay close to the ready position as the torso turns.
func _clip(skeleton: Skeleton3D, clip: int) -> Animation:
	const STEPS := 24
	var animation := Animation.new()
	animation.length = periods[clip]
	animation.loop_mode = Animation.LOOP_LINEAR
	var position := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(position, NodePath("Skeleton3D:Hips"))
	var hips := skeleton.get_bone_rest(bones["Hips"]).origin
	var tracked := ["Hips", "Abdomen", "Torso_2", "Head_2", "UpperLeg.L", "UpperLeg.R",
		"LowerLeg.L", "LowerLeg.R", "Foot.L", "Foot.R", "UpperArm.L", "UpperArm.R",
		"LowerArm.L", "LowerArm.R", "Palm1.L", "Palm1.R"]
	for name in tracked:
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("Skeleton3D:" + name))

	for sample in STEPS + 1:
		var phase := TAU * sample / STEPS
		var time := animation.length * sample / STEPS
		var bounce := 0.0
		var pelvis := hips
		var poses := {}
		if clip == Clip.IDLE:
			_ready_pose(poses, phase)
			bounce = -_sole_height(skeleton, poses)
		elif clip == Clip.CROUCH_IDLE or clip == Clip.CROUCH_WALKING:
			_crouch_pose(poses, clip, float(sample) / STEPS)
			pelvis.z -= _CROUCH_HIP_SHIFT
			bounce = -_sole_height(skeleton, poses)
		else:
			var running := clip == Clip.RUNNING
			var strength := 1.0 if running else 0.7
			poses["Hips"] = Vector3(0.035, -0.08 * strength * sin(phase), 0.04 * strength * cos(phase))
			poses["Torso_2"] = Vector3(0.24 * strength, -0.05 + 0.13 * strength * sin(phase), -0.035)
			poses["Head_2"] = Vector3(-0.24 * strength, 0.05 - 0.05 * strength * sin(phase), 0.025)
			for side in ["L", "R"]:
				var foot_phase := fposmod(float(sample) / STEPS + (0.0 if side == "L" else 0.5), 1.0)
				var leg := _stride(foot_phase, clip)
				poses["UpperLeg." + side] = Vector3(leg.x, 0, 0)
				poses["LowerLeg." + side] = Vector3(leg.y, 0, 0)
				poses["Foot." + side] = Vector3(leg.z, 0, 0)
				poses["UpperArm." + side] = Vector3(0.028 * sin(TAU * foot_phase), 0, 0)
			bounce = -_sole_height(skeleton, poses)
			if running:
				var half_step := fposmod(float(sample) / STEPS, 0.5)
				var flight := smoothstep(_STANCE_PORTION[clip], 0.45, half_step) * (1.0 - smoothstep(0.45, 0.5, half_step))
				bounce += 0.06 * flight
		animation.position_track_insert_key(position, time, pelvis + Vector3.UP * bounce)
		for i in tracked.size():
			var angles: Vector3 = poses.get(tracked[i], Vector3.ZERO)
			animation.rotation_track_insert_key(i + 1, time, Quaternion.from_euler(angles))
	return animation


## The leading boot takes weight under the rifle, with the rear boot
## staggered and both knees unlocked.
func _ready_pose(poses: Dictionary, phase: float) -> void:
	var breath := sin(phase)
	poses["Hips"] = Vector3(0, 0, 0)
	poses["Torso_2"] = Vector3(0.095 + 0.017 * breath, -0.14 + 0.014 * breath, -0.035)
	poses["Head_2"] = Vector3(-0.075 - 0.011 * breath, 0.13, 0.025)
	for side in ["L", "R"]:
		var forward := 0.115 if side == "L" else -0.14
		var leg := _leg_angles(0.769, forward, 0.0)
		poses["UpperLeg." + side] = Vector3(leg.x, 0, 0)
		poses["LowerLeg." + side] = Vector3(leg.y, 0, 0)
		poses["Foot." + side] = Vector3(leg.z, 0, 0)


## Keep weight between staggered boots, bending at the knees and hips
## without folding the chest down onto the thighs.
func _crouch_pose(poses: Dictionary, clip: int, cycle: float) -> void:
	var moving := clip == Clip.CROUCH_WALKING
	var sway := sin(TAU * cycle)
	poses["Hips"] = Vector3(0.02, -0.04 * sway if moving else -0.08, 0)
	poses["Abdomen"] = Vector3(0.40 + 0.012 * sway, 0, 0)
	poses["Torso_2"] = Vector3(0.23, 0.04 * sway if moving else -0.08, -0.025)
	poses["Head_2"] = Vector3(-0.62, 0.15, 0.02)
	for side in ["L", "R"]:
		var leading: bool = side == "L"
		var phase := fposmod(cycle + (0.0 if leading else 0.5), 1.0)
		var reach := 0.36 if leading else -0.16
		var drop := _CROUCH_ANKLE_DROP if leading else _CROUCH_ANKLE_DROP - 0.017
		var roll := 0.0 if leading else 0.22
		var leg := _stride(phase, clip) if moving else _leg_angles(drop, reach, roll)
		poses["UpperLeg." + side] = Vector3(leg.x, 0, 0)
		poses["LowerLeg." + side] = Vector3(leg.y, 0, 0)
		poses["Foot." + side] = Vector3(leg.z, 0, 0)
		poses["UpperArm." + side] = Vector3(-0.61, 0, 0)


## The stance foot moves back along a level path at constant speed; the
## swing foot returns in a higher curved arc. Solve both joints against the
## desired ankle position to avoid the old simultaneous knee swivel.
func _stride(phase: float, clip: int) -> Vector3:
	var stance: float = _STANCE_PORTION[clip]
	var reach: float = _STEP_LENGTH[clip] * 0.5
	var running := clip == Clip.RUNNING
	var crouched := clip == Clip.CROUCH_WALKING
	# The standing pelvis rises as the supporting leg comes beneath the body.
	var other_phase := fposmod(phase + 0.5, 1.0)
	var reach_under_load := 0.0
	for support_phase in [phase, other_phase]:
		if support_phase < stance:
			reach_under_load = maxf(reach_under_load, absf(lerpf(reach, -reach, support_phase / stance)))
	var extension := 0.789 if running else 0.783
	var down := _CROUCH_ANKLE_DROP if crouched else sqrt(extension * extension - reach_under_load * reach_under_load)
	var forward := 0.0
	var foot_roll := 0.0
	if phase < stance:
		var progress := phase / stance
		forward = lerpf(reach, -reach, progress)
		foot_roll = 0.16 * smoothstep(0.76, 1.0, progress)
	else:
		var progress := (phase - stance) / (1.0 - stance)
		forward = lerpf(-reach, reach, smoothstep(0.0, 1.0, progress))
		down -= sin(PI * progress) * (0.046 if crouched else 0.175 if running else 0.102)
		foot_roll = lerpf(0.16, 0.0, smoothstep(0.0, 1.0, progress))
	if crouched:
		forward += _CROUCH_HIP_SHIFT
	return _leg_angles(down, forward, foot_roll)


static func _leg_angles(down: float, forward: float, foot_roll: float) -> Vector3:
	const LENGTH := 0.401
	const REST_PITCH := 0.070
	var distance := minf(Vector2(forward, down).length(), 2.0 * LENGTH - 0.001)
	var opposite := acos(distance / (2.0 * LENGTH))
	var thigh := REST_PITCH - atan2(forward, down) - opposite
	var knee := 2.0 * (opposite - REST_PITCH)
	return Vector3(thigh, knee, -thigh - knee + foot_roll)


## Shift the pelvis so the lower boot sole reaches the ground at each key.
func _sole_height(skeleton: Skeleton3D, poses: Dictionary) -> float:
	var lowest := INF
	for side in ["L", "R"]:
		var pose := Transform3D.IDENTITY
		for name in ["Hips", "UpperLeg." + side, "LowerLeg." + side, "Foot." + side]:
			pose *= Transform3D(Basis.from_euler(poses[name]), skeleton.get_bone_rest(bones[name]).origin)
		var y_axis := Vector3(pose.basis.x.y, pose.basis.y.y, pose.basis.z.y) * InfantryMesh.SOLE_RADII
		lowest = minf(lowest, (pose * InfantryMesh.SOLE_CENTER).y - y_axis.length())
	return lowest


## Ground speed of the clip's stance foot at its authored playback rate.
func stride_speed(clip: int) -> float:
	return _STEP_LENGTH[clip] / (periods[clip] * _STANCE_PORTION[clip])


func instantiate() -> CharacterView:
	var view := CharacterView.new()
	view.setup(self, _template.instantiate())
	return view
