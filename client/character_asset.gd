class_name CharacterAsset
extends RefCounted
## Shared infantry geometry and animation resources. Each soldier owns its pose,
## and marks take their team's colour without adding a material or draw call.

const CLIPS := [&"Idle", &"Walking", &"Running"]
enum Clip { IDLE, WALKING, RUNNING }
const _PERIODS := [2.2, 0.58, 0.47]

const _SHADER := """
shader_type spatial;
instance uniform vec4 team_color : source_color = vec4(0.79, 0.58, 0.22, 1.0);

void fragment() {
	ALBEDO = mix(team_color.rgb, COLOR.rgb, COLOR.a);
	ROUGHNESS = 0.86;
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
	const STEPS := 16
	var animation := Animation.new()
	animation.length = periods[clip]
	animation.loop_mode = Animation.LOOP_LINEAR
	var position := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(position, NodePath("Skeleton3D:Hips"))
	var hips := skeleton.get_bone_rest(bones["Hips"]).origin
	var tracked := ["Hips", "Torso_2", "Head_2", "UpperLeg.L", "UpperLeg.R",
		"LowerLeg.L", "LowerLeg.R", "Foot.L", "Foot.R", "UpperArm.L", "UpperArm.R"]
	for name in tracked:
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, NodePath("Skeleton3D:" + name))

	for sample in STEPS + 1:
		var phase := TAU * sample / STEPS
		var time := animation.length * sample / STEPS
		var bounce := 0.0
		var poses := {}
		if clip == Clip.IDLE:
			poses["Torso_2"] = Vector3(0.013 * sin(phase), 0.012 * sin(phase), 0)
			poses["Head_2"] = Vector3(-0.008 * sin(phase), 0, 0)
		else:
			var running := clip == Clip.RUNNING
			var strength := 1.0 if running else 0.7
			poses["Hips"] = Vector3(0, -0.08 * strength * sin(phase), 0.038 * strength * cos(phase))
			poses["Torso_2"] = Vector3(0.12 * strength, 0.14 * strength * sin(phase), 0)
			poses["Head_2"] = Vector3(-0.07 * strength, -0.05 * strength * sin(phase), 0)
			for side in ["L", "R"]:
				var stride := phase if side == "L" else phase + PI
				var lift := maxf(-cos(stride), 0)
				var thigh := -0.81 * strength * sin(stride)
				var knee := (0.11 + 1.30 * lift) * strength
				poses["UpperLeg." + side] = Vector3(thigh, 0, 0)
				poses["LowerLeg." + side] = Vector3(knee, 0, 0)
				poses["Foot." + side] = Vector3(-0.57 * (thigh + knee), 0, 0)
				poses["UpperArm." + side] = Vector3(0.038 * sin(stride), 0, 0)
			bounce = -_sole_height(skeleton, poses)
		animation.position_track_insert_key(position, time, hips + Vector3.UP * bounce)
		for i in tracked.size():
			var angles: Vector3 = poses.get(tracked[i], Vector3.ZERO)
			animation.rotation_track_insert_key(i + 1, time, Quaternion.from_euler(angles))
	return animation


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


func instantiate() -> CharacterView:
	var view := CharacterView.new()
	view.setup(self, _template.instantiate())
	return view
