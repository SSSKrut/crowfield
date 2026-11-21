class_name InfantryMesh
extends RefCounted
## Original fabric and field equipment in the skeleton's rest pose. Fabric
## rings across the joints use both adjacent bones so the uniform bends with
## the wearer. The assembled uniform remains one skinned draw surface.

const CLOTH := Color8(92, 99, 75)
const CLOTH_LIGHT := Color8(108, 116, 89)
const CLOTH_DARK := Color8(65, 73, 56)
const ARMOUR := Color8(104, 103, 77)
const WEBBING := Color8(77, 73, 54)
const HARDWARE := Color8(43, 48, 43)
const BOOT := Color8(54, 50, 41)
const SOLE := Color8(32, 35, 33)
const HELMET := Color8(71, 82, 60)
const FACE := Color8(152, 115, 91)
const MARK := Color(1, 1, 1, 0)
const SOLE_CENTER := Vector3(0, -0.102, 0.058)
const SOLE_RADII := Vector3(0.077, 0.018, 0.132)

enum Finish { UNIFORM, FABRIC, POLYMER, METAL }

class Ring:
	var at: Vector3
	var radii: Vector2
	var bone: int
	var neighbor: int
	var blend: float

var _skeleton: Skeleton3D
var _vertices := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uv := PackedVector2Array()
var _materials := PackedVector2Array()
var _bones := PackedInt32Array()
var _weights := PackedFloat32Array()
var _indices := PackedInt32Array()
var _linear_colors := RenderingServer.get_current_rendering_method() != "gl_compatibility"


func build(skeleton: Skeleton3D) -> ArrayMesh:
	_skeleton = skeleton
	_uniform()
	_carrier()
	_head()
	for side in ["L", "R"]:
		_sleeve(side)
		_trousers(side)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = _normals
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_TEX_UV] = _uv
	arrays[Mesh.ARRAY_TEX_UV2] = _materials
	arrays[Mesh.ARRAY_BONES] = _bones
	arrays[Mesh.ARRAY_WEIGHTS] = _weights
	arrays[Mesh.ARRAY_INDEX] = _indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _uniform() -> void:
	_loft([
		_ring(Vector3(0, 0.862, 0), 0.127, 0.094, "Hips"),
		_ring(Vector3(0, 0.920, 0), 0.201, 0.120, "Hips"),
		_ring(Vector3(0, 0.985, 0), 0.205, 0.128, "Hips", "Abdomen", 0.20),
		_ring(Vector3(0, 1.057, 0.003), 0.192, 0.122, "Abdomen", "Hips", 0.20),
		_ring(Vector3(0, 1.116, 0.003), 0.186, 0.115, "Abdomen", "Torso_2", 0.25),
		_ring(Vector3(0, 1.197, 0.002), 0.204, 0.131, "Torso_2", "Abdomen", 0.22),
		_ring(Vector3(0, 1.318, 0.003), 0.217, 0.143, "Torso_2"),
		_ring(Vector3(0, 1.415, 0.000), 0.231, 0.115, "Torso_2"),
		_ring(Vector3(0, 1.463, 0.015), 0.111, 0.083, "Torso_2"),
		_ring(Vector3(0, 1.488, 0.011), 0.069, 0.065, "Neck", "Torso_2", 0.55),
	], CLOTH, 18, 0.025, Finish.UNIFORM)
	_loft([
		_ring(Vector3(0, 0.998, 0), 0.198, 0.133, "Hips"),
		_ring(Vector3(0, 1.040, 0), 0.196, 0.132, "Hips"),
	], WEBBING)
	_pouch("Hips", Vector3(0, 1.019, 0.134), Vector3(0.081, 0.037, 0.019), HARDWARE, Finish.METAL)
	_round("Neck", Vector3(0, 1.522, 0.013), Vector3(0.065, 0.065, 0.064), CLOTH_DARK)


func _carrier() -> void:
	const TORSO := "Torso_2"
	_pouch(TORSO, Vector3(0, 1.282, 0.115), Vector3(0.357, 0.317, 0.093), ARMOUR)
	_pouch(TORSO, Vector3(0, 1.329, 0.154), Vector3(0.306, 0.221, 0.056), CLOTH_DARK)
	for side in [-1, 1]:
		var x: float = side * 0.149
		_pouch(TORSO, Vector3(x, 1.431, -0.003), Vector3(0.053, 0.073, 0.221), WEBBING)
		_pouch(TORSO, Vector3(x, 1.397, 0.137), Vector3(0.034, 0.036, 0.018), HARDWARE, Finish.POLYMER)
		_pouch(TORSO, Vector3(side * 0.182, 1.225, -0.004), Vector3(0.057, 0.125, 0.202), WEBBING)

	for index in [-1, 0, 1]:
		var x: float = index * 0.077
		_pouch(TORSO, Vector3(x, 1.202, 0.178), Vector3(0.066, 0.122, 0.078), WEBBING)
		_pouch(TORSO, Vector3(x, 1.257, 0.195), Vector3(0.059, 0.038, 0.057), ARMOUR)
		_pouch(TORSO, Vector3(x, 1.246, 0.225), Vector3(0.020, 0.016, 0.006), HARDWARE, Finish.POLYMER)

	_pouch(TORSO, Vector3(0, 1.355, 0.185), Vector3(0.151, 0.033, 0.014), HARDWARE)
	_pouch(TORSO, Vector3(0, 1.355, 0.193), Vector3(0.132, 0.021, 0.010), MARK)
	_pouch(TORSO, Vector3(0, 1.276, -0.149), Vector3(0.335, 0.306, 0.146), CLOTH_DARK)
	_pouch(TORSO, Vector3(0, 1.291, -0.219), Vector3(0.252, 0.223, 0.066), ARMOUR)
	_pouch(TORSO, Vector3(0, 1.211, -0.260), Vector3(0.203, 0.093, 0.034), CLOTH_DARK)
	for side in [-1, 1]:
		var x: float = side * 0.105
		_pouch(TORSO, Vector3(x, 1.276, -0.246), Vector3(0.030, 0.230, 0.018), WEBBING)
		_pouch(TORSO, Vector3(x, 1.212, -0.260), Vector3(0.040, 0.027, 0.015), HARDWARE, Finish.POLYMER)
	_pouch(TORSO, Vector3(0, 1.355, -0.254), Vector3(0.173, 0.036, 0.014), HARDWARE)
	_pouch(TORSO, Vector3(0, 1.355, -0.263), Vector3(0.153, 0.023, 0.010), MARK)


func _head() -> void:
	const HEAD := "Head_2"
	_round(HEAD, Vector3(0, 1.629, 0.013), Vector3(0.088, 0.104, 0.085), CLOTH_DARK)
	_round(HEAD, Vector3(0, 1.646, 0.070), Vector3(0.067, 0.040, 0.029), FACE)
	_round(HEAD, Vector3(0, 1.599, 0.028), Vector3(0.079, 0.066, 0.082), CLOTH_DARK)
	_loft([
		_ring(Vector3(0, 1.675, 0.003), 0.102, 0.106, HEAD),
		_ring(Vector3(0, 1.690, 0.003), 0.107, 0.109, HEAD),
		_ring(Vector3(0, 1.740, -0.006), 0.103, 0.104, HEAD),
		_ring(Vector3(0, 1.775, -0.008), 0.076, 0.073, HEAD),
		_ring(Vector3(0, 1.789, -0.011), 0.001, 0.001, HEAD),
	], HELMET, 18, 0.012, Finish.POLYMER)
	_pouch(HEAD, Vector3(0, 1.666, 0.084), Vector3(0.172, 0.043, 0.026), HARDWARE, Finish.POLYMER)
	_pouch(HEAD, Vector3(0, 1.668, 0.098), Vector3(0.144, 0.028, 0.012), Color8(72, 77, 62), Finish.POLYMER)
	for side in [-1, 1]:
		var x: float = side * 0.090
		_pouch(HEAD, Vector3(x, 1.666, -0.019), Vector3(0.036, 0.059, 0.072), HARDWARE, Finish.POLYMER)
		_strap(HEAD, Vector3(x, 1.655, 0.014), Vector3(side * 0.057, 1.580, 0.071), 0.008)
	_pouch(HEAD, Vector3(0, 1.705, -0.103), Vector3(0.076, 0.024, 0.012), WEBBING)


func _sleeve(side: String) -> void:
	var upper := "UpperArm." + side
	var lower := "LowerArm." + side
	var palm := "Palm1." + side
	var shoulder := _joint(upper)
	var elbow := _joint(lower)
	var hand := _joint(palm)
	var outer := Vector3.RIGHT if side == "L" else Vector3.LEFT
	_loft([
		_ring(shoulder.lerp(elbow, -0.13), 0.044, 0.048, upper),
		_ring(shoulder.lerp(elbow, 0.06), 0.073, 0.075, upper),
		_ring(shoulder.lerp(elbow, 0.36), 0.069, 0.068, upper),
		_ring(shoulder.lerp(elbow, 0.77), 0.061, 0.060, upper, lower, 0.08),
		_ring(elbow, 0.062, 0.061, upper, lower, 0.50),
		_ring(elbow.lerp(hand, 0.24), 0.060, 0.061, lower, upper, 0.10),
		_ring(elbow.lerp(hand, 0.62), 0.052, 0.054, lower),
		_ring(elbow.lerp(hand, 0.85), 0.043, 0.046, lower),
		_ring(hand, 0.038, 0.042, lower, palm, 0.15),
	], CLOTH, 14, 0.050, Finish.UNIFORM)
	var patch := shoulder.lerp(elbow, 0.29) + outer * 0.065
	_pouch(upper, patch, Vector3(0.028, 0.095, 0.097), CLOTH_DARK)
	_pouch(upper, patch + outer * 0.013 + Vector3.UP * 0.012, Vector3(0.012, 0.051, 0.075), MARK)
	_round(lower, elbow.lerp(hand, 0.11) + outer * 0.048, Vector3(0.020, 0.060, 0.049), WEBBING)
	_pouch(lower, elbow.lerp(hand, 0.87) + Vector3.UP * 0.026, Vector3(0.061, 0.032, 0.052), WEBBING)
	_round(palm, hand, Vector3(0.049, 0.036, 0.062), HARDWARE)
	_pouch(palm, hand + Vector3(0, 0.025, 0.014), Vector3(0.071, 0.027, 0.066), BOOT, Finish.POLYMER)


func _trousers(side: String) -> void:
	var upper := "UpperLeg." + side
	var lower := "LowerLeg." + side
	var foot := "Foot." + side
	var hip := _joint(upper)
	var knee := _joint(lower)
	var ankle := _joint(foot)
	var outer := Vector3.RIGHT if side == "L" else Vector3.LEFT
	_loft([
		_ring(hip.lerp(knee, -0.09), 0.103, 0.104, upper, "Hips", 0.26),
		_ring(hip.lerp(knee, 0.13), 0.107, 0.114, upper),
		_ring(hip.lerp(knee, 0.37), 0.101, 0.103, upper),
		_ring(hip.lerp(knee, 0.73), 0.089, 0.089, upper, lower, 0.13),
		_ring(knee, 0.082, 0.077, lower, upper, 0.50),
		_ring(knee.lerp(ankle, 0.24), 0.078, 0.078, lower, upper, 0.13),
		_ring(knee.lerp(ankle, 0.52), 0.072, 0.075, lower),
		_ring(knee.lerp(ankle, 0.78), 0.059, 0.066, lower),
		_ring(ankle, 0.059, 0.062, lower, foot, 0.22),
	], CLOTH_DARK, 16, 0.051, Finish.UNIFORM)
	_pouch(upper, hip.lerp(knee, 0.42) + outer * 0.078, Vector3(0.057, 0.131, 0.131), CLOTH)
	_pouch(upper, hip.lerp(knee, 0.29) + outer * 0.088, Vector3(0.054, 0.037, 0.140), CLOTH_LIGHT)
	_round(lower, knee + Vector3(0, -0.042, 0.066), Vector3(0.066, 0.084, 0.035), WEBBING)
	_pouch(lower, knee + Vector3(0, -0.042, 0.085), Vector3(0.094, 0.113, 0.031), HARDWARE, Finish.POLYMER)
	_round(lower, ankle + Vector3(0, 0.067, 0.002), Vector3(0.064, 0.097, 0.069), BOOT)
	_pouch(foot, ankle + Vector3(0, -0.066, 0.050), Vector3(0.139, 0.087, 0.235), BOOT, Finish.POLYMER)
	_round(foot, ankle + Vector3(0, -0.050, 0.080), Vector3(0.068, 0.060, 0.100), BOOT)
	_round(foot, ankle + SOLE_CENTER, SOLE_RADII, SOLE, Finish.POLYMER)


func _joint(name: String) -> Vector3:
	return _skeleton.get_bone_global_rest(_skeleton.find_bone(name)).origin


func _ring(at: Vector3, width: float, depth: float, bone: String,
		neighbor: String = "", blend: float = 0.0) -> Ring:
	var ring := Ring.new()
	ring.at = at
	ring.radii = Vector2(width, depth)
	ring.bone = _skeleton.find_bone(bone)
	ring.neighbor = _skeleton.find_bone(neighbor) if not neighbor.is_empty() else ring.bone
	ring.blend = blend
	return ring


## Loft a garment along its posed axis. Rings are continuous at joints and
## store their weights individually; the seam duplicates only the UV edge.
func _loft(rings: Array[Ring], color: Color, sides: int = 14, fold: float = 0.0,
		material: int = Finish.FABRIC, exponent: float = 1.0) -> void:
	var base := _vertices.size()
	var length := 0.0
	for row in rings.size():
		var ring := rings[row]
		if row > 0:
			length += ring.at.distance_to(rings[row - 1].at)
		var previous := rings[maxi(row - 1, 0)]
		var next := rings[mini(row + 1, rings.size() - 1)]
		var axis := (next.at - previous.at).normalized()
		var side := (Vector3.RIGHT - axis * axis.x).normalized()
		var depth := side.cross(axis)
		var radius_delta := (next.radii - previous.radii) / maxf(0.001, next.at.distance_to(previous.at))
		for column in sides + 1:
			var u := float(column) / sides
			var angle := TAU * u
			var cosine := cos(angle)
			var sine := sin(angle)
			var x := signf(cosine) * pow(absf(cosine), exponent)
			var z := signf(sine) * pow(absf(sine), exponent)
			var wrinkle := sin(angle * 3.0 + row * 1.7) * fold
			var offset := side * x * ring.radii.x + depth * z * ring.radii.y
			var nx := signf(cosine) * pow(absf(cosine), 2.0 - exponent) / ring.radii.x
			var nz := signf(sine) * pow(absf(sine), 2.0 - exponent) / ring.radii.y
			var normal := side * nx + depth * nz
			normal = (normal.normalized() - axis * (absf(x) * radius_delta.x + absf(z) * radius_delta.y)).normalized()
			var shade := color.lightened(wrinkle) if wrinkle >= 0.0 else color.darkened(-wrinkle)
			_vertex(ring.at + offset * (1.0 + wrinkle), normal, shade, Vector2(u * 2.0, length * 5.0),
				material, ring.bone, ring.neighbor, ring.blend)
		if row == 0:
			continue
		var before := base + (row - 1) * (sides + 1)
		var current := before + sides + 1
		for column in sides:
			var a := before + column
			var b := current + column
			_indices.append_array([a, a + 1, b, a + 1, b + 1, b])


func _strap(bone: String, start: Vector3, end: Vector3, radius: float) -> void:
	_loft([_ring(start, radius, radius, bone), _ring(end, radius, radius, bone)], WEBBING, 8)


func _round(bone: String, at: Vector3, radii: Vector3, color: Color, material: int = Finish.FABRIC) -> void:
	var shape := SphereMesh.new()
	shape.radial_segments = 14
	shape.rings = 7
	_append(shape, bone, Transform3D(Basis.from_scale(radii * 2.0), at), color, material)


## The layered gear uses a rounded rectangular surface rather than square
## blocks. A tightened perimeter forms the welt around each padded shell.
func _pouch(bone: String, at: Vector3, size: Vector3, color: Color,
		material: int = Finish.FABRIC) -> void:
	var y := size.y * 0.5
	var x := size.x * 0.5
	var z := size.z * 0.5
	var edge := minf(y * 0.60, minf(x, z) * 0.40)
	_loft([
		_ring(at + Vector3.DOWN * y, 0.001, 0.001, bone),
		_ring(at + Vector3.DOWN * (y - edge * 0.2), maxf(0.001, x - edge), maxf(0.001, z - edge), bone),
		_ring(at + Vector3.DOWN * (y - edge), x, z, bone),
		_ring(at + Vector3.UP * (y - edge), x, z, bone),
		_ring(at + Vector3.UP * (y - edge * 0.2), maxf(0.001, x - edge), maxf(0.001, z - edge), bone),
		_ring(at + Vector3.UP * y, 0.001, 0.001, bone),
	], color, 16, 0.0, material, 0.37)


func _append(shape: PrimitiveMesh, bone: String, pose: Transform3D, color: Color, material: int) -> void:
	var part := shape.get_mesh_arrays()
	var vertices: PackedVector3Array = part[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = part[Mesh.ARRAY_NORMAL]
	var coordinates: PackedVector2Array = part[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = part[Mesh.ARRAY_INDEX]
	var normal_basis := pose.basis.inverse().transposed()
	var bone_index := _skeleton.find_bone(bone)
	var base := _vertices.size()
	for i in vertices.size():
		_vertex(pose * vertices[i], (normal_basis * normals[i]).normalized(), color, coordinates[i], material, bone_index)
	for index in indices:
		_indices.append(base + index)


func _vertex(at: Vector3, normal: Vector3, color: Color, uv: Vector2, material: int,
		bone: int, neighbor: int = 0, blend: float = 0.0) -> void:
	_vertices.append(at)
	_normals.append(normal)
	_colors.append(color.srgb_to_linear() if _linear_colors else color)
	_uv.append(uv)
	_materials.append(Vector2(material / 3.0, 0))
	_bones.append_array([bone, neighbor, 0, 0])
	_weights.append_array([1.0 - blend, blend, 0.0, 0.0])
