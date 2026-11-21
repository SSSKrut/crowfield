class_name InfantryMesh
extends RefCounted
## Original Crowfield uniform geometry in the infantry skeleton's rest pose.
## All parts, including the coloured cloth panels, end up in one skin surface.

const CLOTH := Color8(98, 106, 78)
const CLOTH_LIGHT := Color8(116, 122, 88)
const CLOTH_DARK := Color8(69, 78, 58)
const ARMOUR := Color8(117, 110, 76)
const WEBBING := Color8(84, 76, 54)
const HARDWARE := Color8(46, 50, 44)
const BOOT := Color8(51, 48, 40)
const SOLE := Color8(35, 36, 32)
const HELMET := Color8(87, 94, 62)
const FACE := Color8(170, 127, 96)
const MARK := Color(1, 1, 1, 0)
const SOLE_CENTER := Vector3(0, -0.102, 0.058)
const SOLE_RADII := Vector3(0.077, 0.018, 0.132)

var _skeleton: Skeleton3D
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _bones := PackedInt32Array()
var _weights := PackedFloat32Array()
var _indices := PackedInt32Array()
var _linear_colors := RenderingServer.get_current_rendering_method() != "gl_compatibility"


func build(skeleton: Skeleton3D) -> ArrayMesh:
	_skeleton = skeleton
	_clothing()
	_carrier()
	_helmet()
	for side in ["L", "R"]:
		_sleeve(side)
		_trousers(side)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_BONES] = _bones
	arrays[Mesh.ARRAY_WEIGHTS] = _weights
	arrays[Mesh.ARRAY_INDEX] = _indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _clothing() -> void:
	_round("Hips", Vector3(0, 0.962, 0), Vector3(0.214, 0.144, 0.132), CLOTH_DARK)
	_round("Abdomen", Vector3(0, 1.077, 0), Vector3(0.21, 0.156, 0.132), CLOTH)
	_round("Torso_2", Vector3(0, 1.283, 0), Vector3(0.242, 0.218, 0.136), CLOTH_LIGHT)
	_box("Hips", Vector3(0, 1.018, 0), Vector3(0.378, 0.056, 0.248), WEBBING)
	_box("Hips", Vector3(0, 1.018, 0.126), Vector3(0.088, 0.047, 0.024), HARDWARE)
	_tube("Neck", Vector3(0, 1.462, 0), Vector3(0, 1.555, 0), 0.070, 0.061, CLOTH_DARK)
	_round("Torso_2", Vector3(0, 1.469, 0.012), Vector3(0.097, 0.043, 0.091), CLOTH)


func _carrier() -> void:
	const TORSO := "Torso_2"
	_round(TORSO, Vector3(0, 1.283, 0.082), Vector3(0.207, 0.178, 0.097), ARMOUR)
	_box(TORSO, Vector3(0, 1.275, 0.152), Vector3(0.303, 0.216, 0.059), ARMOUR)
	_box(TORSO, Vector3(0, 1.342, 0.187), Vector3(0.174, 0.046, 0.014), HARDWARE)
	_box(TORSO, Vector3(0, 1.342, 0.197), Vector3(0.154, 0.032, 0.013), MARK)
	for i in [-1, 0, 1]:
		var x: float = 0.081 * i
		_box(TORSO, Vector3(x, 1.198, 0.196), Vector3(0.072, 0.112, 0.063), WEBBING)
		_box(TORSO, Vector3(x, 1.233, 0.231), Vector3(0.064, 0.021, 0.015), ARMOUR)
	for sign_x in [-1, 1]:
		var x: float = 0.151 * sign_x
		_box(TORSO, Vector3(x, 1.412, 0.047), Vector3(0.049, 0.108, 0.205), WEBBING)
		_box(TORSO, Vector3(x, 1.385, 0.153), Vector3(0.032, 0.036, 0.021), HARDWARE)

	_round(TORSO, Vector3(0, 1.286, -0.132), Vector3(0.197, 0.178, 0.104), CLOTH_DARK)
	_box(TORSO, Vector3(0, 1.269, -0.201), Vector3(0.295, 0.243, 0.107), CLOTH_DARK)
	_box(TORSO, Vector3(0, 1.216, -0.263), Vector3(0.230, 0.095, 0.037), WEBBING)
	_box(TORSO, Vector3(0, 1.343, -0.262), Vector3(0.263, 0.061, 0.025), HARDWARE)
	_box(TORSO, Vector3(0, 1.343, -0.277), Vector3(0.239, 0.044, 0.013), MARK)


func _helmet() -> void:
	const HEAD := "Head_2"
	_round(HEAD, Vector3(0, 1.636, 0.014), Vector3(0.090, 0.112, 0.088), FACE)
	_round(HEAD, Vector3(0, 1.622, 0.076), Vector3(0.026, 0.035, 0.037), FACE)
	_round(HEAD, Vector3(0, 1.708, -0.006), Vector3(0.112, 0.092, 0.113), HELMET)
	_round(HEAD, Vector3(0, 1.688, 0.008), Vector3(0.116, 0.025, 0.117), CLOTH_DARK)
	for sign_x in [-1, 1]:
		var x: float = 0.086 * sign_x
		_round(HEAD, Vector3(x, 1.660, -0.015), Vector3(0.022, 0.046, 0.037), HELMET)
		_box(HEAD, Vector3(0.038 * sign_x, 1.657, 0.093), Vector3(0.031, 0.012, 0.018), HARDWARE)
		_tube(HEAD, Vector3(x, 1.655, 0.018), Vector3(0.058 * sign_x, 1.581, 0.071), 0.008, 0.008, WEBBING, 6)
	_box(HEAD, Vector3(0, 1.708, -0.112), Vector3(0.10, 0.029, 0.020), MARK)


func _sleeve(side: String) -> void:
	var upper := "UpperArm." + side
	var lower := "LowerArm." + side
	var palm := "Palm1." + side
	var shoulder := _joint(upper)
	var elbow := _joint(lower)
	var hand := _joint(palm)
	_round(upper, shoulder, Vector3(0.079, 0.090, 0.073), CLOTH)
	_tube(upper, shoulder, elbow.lerp(shoulder, -0.10), 0.078, 0.062, CLOTH)
	_tube(upper, shoulder.lerp(elbow, 0.15), shoulder.lerp(elbow, 0.40), 0.079, 0.076, MARK)
	_round(lower, elbow, Vector3(0.064, 0.058, 0.061), CLOTH_DARK)
	_tube(lower, elbow, hand, 0.062, 0.040, CLOTH_LIGHT)
	_tube(lower, elbow.lerp(hand, 0.83), hand, 0.047, 0.043, WEBBING)
	_round(palm, hand, Vector3(0.048, 0.038, 0.065), HARDWARE)


func _trousers(side: String) -> void:
	var upper := "UpperLeg." + side
	var lower := "LowerLeg." + side
	var foot := "Foot." + side
	var hip := _joint(upper)
	var knee := _joint(lower)
	var ankle := _joint(foot)
	var sign_x := 1.0 if side == "L" else -1.0
	_round(upper, hip, Vector3(0.105, 0.103, 0.102), CLOTH)
	_tube(upper, hip, knee, 0.106, 0.081, CLOTH)
	_box(upper, hip + Vector3(0.073 * sign_x, -0.154, 0), Vector3(0.073, 0.140, 0.131), CLOTH_DARK)
	_box(upper, hip + Vector3(0.078 * sign_x, -0.108, 0), Vector3(0.076, 0.034, 0.145), CLOTH_LIGHT)
	_round(lower, knee, Vector3(0.082, 0.088, 0.080), CLOTH)
	_tube(lower, knee, ankle, 0.078, 0.062, CLOTH_DARK)
	_round(lower, knee + Vector3(0, -0.043, 0.067), Vector3(0.068, 0.077, 0.029), WEBBING)
	_tube(lower, ankle + Vector3(0, 0.115, 0), ankle, 0.061, 0.064, BOOT)
	_round(foot, ankle + Vector3(0, -0.056, 0.057), Vector3(0.073, 0.060, 0.123), BOOT)
	_round(foot, ankle + SOLE_CENTER, SOLE_RADII, SOLE)


func _joint(name: String) -> Vector3:
	return _skeleton.get_bone_global_rest(_skeleton.find_bone(name)).origin


func _round(bone: String, at: Vector3, radii: Vector3, color: Color) -> void:
	var shape := SphereMesh.new()
	shape.radius = 1.0
	shape.height = 2.0
	shape.radial_segments = 10
	shape.rings = 5
	_append(shape, bone, Transform3D(Basis.from_scale(radii), at), color)


func _box(bone: String, at: Vector3, size: Vector3, color: Color) -> void:
	var shape := BoxMesh.new()
	shape.size = size
	_append(shape, bone, Transform3D(Basis.IDENTITY, at), color)


func _tube(bone: String, start: Vector3, end: Vector3, start_radius: float, end_radius: float,
		color: Color, sides: int = 10) -> void:
	var shape := CylinderMesh.new()
	shape.top_radius = end_radius
	shape.bottom_radius = start_radius
	shape.height = start.distance_to(end)
	shape.radial_segments = sides
	shape.rings = 0
	var basis := Basis(Quaternion(Vector3.UP, (end - start).normalized()))
	_append(shape, bone, Transform3D(basis, (start + end) * 0.5), color)


func _append(shape: PrimitiveMesh, bone: String, pose: Transform3D, color: Color) -> void:
	var part := shape.get_mesh_arrays()
	var vertices: PackedVector3Array = part[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = part[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = part[Mesh.ARRAY_INDEX]
	var normal_basis := pose.basis.inverse().transposed()
	var bone_index := _skeleton.find_bone(bone)
	var tint := color.srgb_to_linear() if _linear_colors else color
	var base := _vertices.size()
	for i in vertices.size():
		_vertices.append(pose * vertices[i])
		_normals.append((normal_basis * normals[i]).normalized())
		_colors.append(tint)
		_bones.append_array([bone_index, 0, 0, 0])
		_weights.append_array([1.0, 0.0, 0.0, 0.0])
	for index in indices:
		_indices.append(base + index)
