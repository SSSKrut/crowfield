extends Node3D
## Evaluation adapter for the authored tactical uniform. The shipped rig
## supplies animation and weapon placement. The imported rig keeps its
## own bone proportions, garment weights and finger poses.

const MODEL := preload("res://prototypes/authored-infantry/danly-soldier.glb")
const TEAM_MARKS := preload("res://prototypes/authored-infantry/team_marks.gdshader")
const SCALE := 0.96
const PREFIX := "mixamorig_"
# Center of the grip enclosed by the original glove bones, in hand space.
const PALM_CONTACT := Vector3(0.002, 0.151, 0.032)
const TORSO := [
	["Hips_01", "Hips"], ["Spine_02", "Abdomen"], ["Spine1_03", "Torso_2"],
	["Spine2_04", "Torso_2"], ["Neck_05", "Neck"], ["Head_06", "Head_2"],
]
const LEGS := [
	["RightUpLeg_057", "RightLeg_058", "RightFoot_059", "R"],
	["LeftUpLeg_063", "LeftLeg_064", "LeftFoot_065", "L"],
]
const ARMS := [
	["RightArm_09", "RightForeArm_010", "RightHand_011", "R"],
	["LeftArm_033", "LeftForeArm_034", "LeftHand_035", "L"],
]

var skeleton: Skeleton3D
var _actor_from_skin: Transform3D
var _skin_from_actor: Transform3D
var _marked_meshes: Array[MeshInstance3D] = []


func setup() -> void:
	var model := MODEL.instantiate() as Node3D
	add_child(model)
	model.scale = Vector3.ONE * SCALE
	model.position = Vector3(-0.176, 0.0, 0.042) * SCALE
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	_actor_from_skin = global_transform.affine_inverse() * skeleton.global_transform
	_skin_from_actor = _actor_from_skin.affine_inverse()
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.name == &"Object_111": # Floating headset in the source scene.
			mesh.hide()
		if mesh.skin != null:
			# The GLB inverse binds cancel its authored unit conversion.
			# Bound the resulting skinned geometry in native mesh space.
			mesh.custom_aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 3.0, 3.2))

		if mesh.name in [&"Object_105", &"Object_107", &"Object_109"]:
			_marked_meshes.append(mesh)


func set_tint(color: Color, broad := true) -> void:
	for mesh in _marked_meshes:
		if mesh.material_override == null:
			var material := ShaderMaterial.new()
			var source := mesh.mesh.surface_get_material(0) as StandardMaterial3D
			material.shader = TEAM_MARKS
			material.set_shader_parameter("color_map", source.albedo_texture)
			material.set_shader_parameter("normal_map", source.normal_texture)
			material.set_shader_parameter("orm_map", source.ao_texture)
			material.set_shader_parameter("normal_scale", source.normal_scale)
			material.set_shader_parameter("roughness_scale", source.roughness)
			material.set_shader_parameter("specular_scale", source.metallic_specular)
			var layout := 2 if mesh.name == &"Object_109" else (1 if mesh.name == &"Object_105" else 0)
			material.set_shader_parameter("layout_kind", layout)
			mesh.material_override = material
		mesh.set_instance_shader_parameter("team_color", color)
		mesh.set_instance_shader_parameter("broad_marks", broad)


func retarget(driver: CharacterView) -> void:
	global_transform = driver.global_transform
	for pair in TORSO:
		_transfer_rotation(driver, _bone(pair[0]), pair[1])
	for leg in LEGS:
		var side: String = leg[3]
		var hip := _bone(leg[0])
		var knee := _bone(leg[1])
		var foot := _bone(leg[2])
		var driver_foot := _pose(driver, "Foot." + side)
		# Preserve the contact heights from the real stance and stride.
		var ankle := driver_foot.origin + Vector3.UP * 0.003
		_solve_limb(hip, knee, foot, ankle, _pose(driver, "LowerLeg." + side).origin)
		_transfer_rotation(driver, foot, "Foot." + side)
	if driver.armed_pose.active:
		_fit_hand(driver, ARMS[0], false)
		_fit_hand(driver, ARMS[1], true)


func _fit_hand(driver: CharacterView, chain: Array, support: bool) -> void:
	var upper := _bone(chain[0])
	var elbow := _bone(chain[1])
	var hand := _bone(chain[2])
	var side: String = chain[3]
	var weapon := driver.armed_pose.weapon
	var grip_frame := weapon.basis.orthonormalized() * Basis(Vector3.UP, PI)
	# The artist's curled fingers wrap toward their palm's local +Z.
	var hand_frame := Basis(Vector3.FORWARD, Vector3.LEFT, Vector3.UP).rotated(Vector3.UP, 0.9) if support \
		else Basis(Vector3.UP, Vector3.BACK, Vector3.RIGHT)
	var rotation := grip_frame * hand_frame
	var hand_scale := _rest(hand).basis.get_scale().x
	var wrist := weapon * _grip(driver, support) - rotation * (PALM_CONTACT * hand_scale)
	_solve_limb(upper, elbow, hand, wrist, _pose(driver, "LowerArm." + side).origin)
	var hand_pose := _current(hand)
	hand_pose.basis = rotation.scaled(Vector3.ONE * hand_scale)
	_write(hand, hand_pose)


func _grip(driver: CharacterView, support: bool) -> Vector3:
	if support:
		# The authored arms are shorter. Hold the rear of the handguard.
		return driver.armed_pose.support + Vector3.BACK * 0.12
	return driver.armed_pose.trigger


func _solve_limb(upper: int, lower: int, end: int, target: Vector3, bend: Vector3) -> void:
	var start := _current(upper).origin
	var length_a := _rest(upper).origin.distance_to(_rest(lower).origin)
	var length_b := _rest(lower).origin.distance_to(_rest(end).origin)
	var span := target - start
	var direction := span.normalized()
	var reach := clampf(span.length(), absf(length_a - length_b) + 0.001, length_a + length_b - 0.001)
	var depth := (length_a * length_a - length_b * length_b + reach * reach) / (2.0 * reach)
	var perpendicular := bend - start
	perpendicular -= direction * perpendicular.dot(direction)
	var height := sqrt(maxf(0.0, length_a * length_a - depth * depth))
	var hinge := start + direction * depth + perpendicular.normalized() * height
	var end_position := start + direction * reach
	_point_segment(upper, lower, start, hinge)
	_point_segment(lower, end, hinge, end_position)


func _point_segment(bone: int, child: int, origin: Vector3, destination: Vector3) -> void:
	var neutral := _rest(bone)
	var from := (_rest(child).origin - neutral.origin).normalized()
	var along := (destination - origin).normalized()
	_write(bone, Transform3D(Basis(Quaternion(from, along)) * neutral.basis, origin))


func _transfer_rotation(driver: CharacterView, imported: int, driven: String) -> void:
	var neutral := driver.skeleton.get_bone_global_rest(driver.asset.bones[driven])
	var motion := _pose(driver, driven)
	var rotation := motion.basis * neutral.basis.inverse()
	var result := _current(imported)
	result.basis = rotation * _rest(imported).basis
	if driven == "Hips":
		result.origin = _rest(imported).origin + motion.origin - neutral.origin
	_write(imported, result)


func _bone(label: String) -> int:
	return skeleton.find_bone(PREFIX + label)


func _pose(driver: CharacterView, label: String) -> Transform3D:
	return driver.skeleton.get_bone_global_pose(driver.asset.bones[label])


func _rest(index: int) -> Transform3D:
	return _actor_from_skin * skeleton.get_bone_global_rest(index)


func _current(index: int) -> Transform3D:
	return _actor_from_skin * skeleton.get_bone_global_pose(index)


func _write(index: int, actor_pose: Transform3D) -> void:
	skeleton.set_bone_global_pose(index, _skin_from_actor * actor_pose)
