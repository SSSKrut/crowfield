class_name AuthoredSoldier
extends Node3D
## Retargets the authored tactical uniform. The gameplay rig
## supplies animation and weapon placement. The imported rig keeps its
## own bone proportions, garment weights and finger poses.

const MODEL := preload("res://assets/infantry/danly-soldier.glb")
const TEAM_MARKS := preload("res://assets/infantry/team_marks.gdshader")
const SCALE := 0.96
const PREFIX := "mixamorig_"
# Center of the grip enclosed by the original glove bones, in hand space.
const PALM_CONTACT := Vector3(0.002, 0.151, 0.032)
# Bottom vertices of each boot in driver ankle space. These support points
# come from Object_123's skinned rest pose and cover the toe, heel and sides.
const LEFT_SOLE := [
	Vector3(-0.0144, -0.1176, 0.1421), Vector3(-0.0474, -0.1084, -0.0157),
	Vector3(-0.0412, -0.1047, -0.0495), Vector3(-0.0172, -0.0974, -0.0686),
	Vector3(0.0050, -0.0952, -0.0723), Vector3(0.0491, -0.0993, -0.0362),
	Vector3(0.0299, -0.0966, -0.0643), Vector3(0.1122, -0.1071, 0.1408),
	Vector3(0.1079, -0.1029, 0.1839), Vector3(0.0935, -0.0925, 0.2125),
	Vector3(0.0103, -0.1043, 0.2145), Vector3(0.0213, -0.0970, 0.2301),
	Vector3(0.0488, -0.0854, 0.2404), Vector3(-0.0052, -0.1141, 0.1802),
]
const RIGHT_SOLE := [
	Vector3(-0.0374, -0.1118, 0.1412), Vector3(-0.1542, -0.0965, 0.0962),
	Vector3(-0.1647, -0.0911, 0.1392), Vector3(-0.0660, -0.1022, -0.0069),
	Vector3(-0.0437, -0.0962, -0.0485), Vector3(0.0123, -0.0930, -0.0723),
	Vector3(-0.0132, -0.0929, -0.0725), Vector3(0.0531, -0.1071, -0.0331),
	Vector3(-0.0583, -0.1068, 0.1741), Vector3(-0.0995, -0.0873, 0.2118),
	Vector3(-0.1559, -0.0728, 0.1904),
]
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
var outfit: MeshInstance3D
var _bones: Dictionary[String, int] = {}
var _rest_poses: Array[Transform3D] = []
# Each team shares a material across live and fallen bodies.
static var _team_materials: Dictionary[Color, ShaderMaterial] = {}


func setup() -> void:
	var model := MODEL.instantiate() as Node3D
	add_child(model)
	model.scale = Vector3.ONE * SCALE
	model.position = Vector3(-0.176, 0.0, 0.042) * SCALE
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	_actor_from_skin = global_transform.affine_inverse() * skeleton.global_transform
	_skin_from_actor = _actor_from_skin.affine_inverse()
	for index in skeleton.get_bone_count():
		_bones[skeleton.get_bone_name(index).trim_prefix(PREFIX)] = index
		_rest_poses.append(_actor_from_skin * skeleton.get_bone_global_rest(index))
	outfit = model.find_child("Object_123", true, false) as MeshInstance3D
	# The GLB inverse binds cancel its authored unit conversion.
	# Bound the resulting skinned geometry in native mesh space.
	outfit.custom_aabb = AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 3.0, 3.2))


func set_tint(color: Color) -> void:
	if not _team_materials.has(color):
		var material := ShaderMaterial.new()
		var source := outfit.mesh.surface_get_material(0) as StandardMaterial3D
		material.shader = TEAM_MARKS
		material.set_shader_parameter("color_map", source.albedo_texture)
		material.set_shader_parameter("normal_map", source.normal_texture)
		material.set_shader_parameter("orm_map", source.ao_texture)
		material.set_shader_parameter("team_color", color)
		_team_materials[color] = material
	outfit.material_override = _team_materials[color]


func retarget(driver: CharacterView) -> void:
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
	else:
		for arm in ARMS:
			var side: String = arm[3]
			var hand := _bone(arm[2])
			_solve_limb(_bone(arm[0]), _bone(arm[1]), hand,
				_pose(driver, "Palm1." + side).origin, _pose(driver, "LowerArm." + side).origin)
			_transfer_rotation(driver, hand, "Palm1." + side)


## The lowest point of the boot along the terrain normal, in world space.
static func sole_contact(foot: Transform3D, ground: Terrain, left: bool) -> Vector3:
	var center := foot * Vector3(0.0, -0.103, 0.069)
	var normal := ground.normal_at(center.x, center.z)
	var local_normal := foot.basis.transposed() * normal
	var lowest := Vector3.ZERO
	var height := INF
	for point: Vector3 in LEFT_SOLE if left else RIGHT_SOLE:
		var distance := point.dot(local_normal)
		if distance < height:
			lowest = point
			height = distance
	return foot * lowest


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
	if not support:
		return driver.armed_pose.trigger
	# Both long guns have space to grip the rear of their handguards.
	# The pistol's support hand braces the grip beside the trigger hand.
	match driver.held_kind:
		WeaponTuning.Kind.ASSAULT_RIFLE:
			return driver.armed_pose.support + Vector3.BACK * 0.12
		WeaponTuning.Kind.RIFLE:
			return driver.armed_pose.support + Vector3.BACK * 0.06
	return driver.armed_pose.support


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
	return _bones[label]


func _pose(driver: CharacterView, label: String) -> Transform3D:
	return driver.skeleton.get_bone_global_pose(driver.asset.bones[label])


func _rest(index: int) -> Transform3D:
	return _rest_poses[index]


func _current(index: int) -> Transform3D:
	return _actor_from_skin * skeleton.get_bone_global_pose(index)


func _write(index: int, actor_pose: Transform3D) -> void:
	skeleton.set_bone_global_pose(index, _skin_from_actor * actor_pose)
