class_name InfantryMesh
extends RefCounted
## Original fabric and field equipment in the skeleton's rest pose. Fabric
## rings across the joints use both adjacent bones so the uniform bends with
## the wearer. The assembled uniform remains one skinned draw surface.

const CLOTH := Color8(101, 104, 83)
const CLOTH_LIGHT := Color8(117, 118, 94)
const CLOTH_DARK := Color8(78, 81, 64)
const ARMOUR := Color8(83, 73, 55)
const WEBBING := Color8(51, 46, 36)
const HARDWARE := Color8(43, 48, 43)
const BOOT := Color8(55, 44, 33)
const GLOVE := Color8(58, 55, 43)
const SOLE := Color8(32, 35, 33)
const HELMET := Color8(48, 54, 45)
const FACE := Color8(148, 115, 94)
const SCARF := Color8(69, 70, 62)
const EYEWEAR := Color8(36, 40, 34)
const LENS := Color8(46, 55, 49)
const TROUSER_SIDES := 16
const MARK := Color(1, 1, 1, 0)
const SOLE_CENTER := Vector3(0, -0.102, 0.058)
const SOLE_RADII := Vector3(0.085, 0.018, 0.132)
const TRIGGER_CONTACT := Vector3(0.028, 0.006, 0.035)
const SUPPORT_CONTACT := Vector3(-0.023, 0.031, 0.032)

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
	_join_trousers(_trousers("L"), _trousers("R"))
	_sleeve("L")
	_sleeve("R")

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
	# The blouse sits over a separate waistband. Its shoulder runs into the
	# inset sleeve cap, while a rising collar wraps the actual neck.
	_loft([
		_ring(Vector3(0, 0.960, 0), 0.188, 0.127, "Hips"),
		_ring(Vector3(0, 0.988, 0), 0.193, 0.128, "Hips"),
		_ring(Vector3(0, 1.066, 0.003), 0.180, 0.117, "Abdomen", "Hips", 0.15),
		_ring(Vector3(0, 1.142, 0.003), 0.184, 0.121, "Abdomen", "Torso_2", 0.38),
		_ring(Vector3(0, 1.232, 0.001), 0.206, 0.131, "Torso_2", "Abdomen", 0.12),
		_ring(Vector3(0, 1.341, 0.002), 0.222, 0.122, "Torso_2"),
		_ring(Vector3(0, 1.408, 0.002), 0.235, 0.105, "Torso_2"),
		_ring(Vector3(0, 1.450, 0.008), 0.202, 0.087, "Torso_2"),
		_ring(Vector3(0, 1.475, 0.013), 0.089, 0.061, "Torso_2", "Neck", 0.20),
		_ring(Vector3(0, 1.500, 0.015), 0.062, 0.062, "Neck", "Torso_2", 0.22),
	], CLOTH, 18, 0.018, Finish.UNIFORM, 0.94)
	_loft([
		_ring(Vector3(0, 1.458, 0.014), 0.087, 0.072, "Torso_2", "Neck", 0.18),
		_ring(Vector3(0, 1.484, 0.018), 0.072, 0.067, "Neck", "Torso_2", 0.35),
		_ring(Vector3(0, 1.508, 0.021), 0.059, 0.059, "Neck"),
		_ring(Vector3(0, 1.532, 0.027), 0.054, 0.056, "Neck", "Head_2", 0.35),
		_ring(Vector3(0, 1.578, 0.032), 0.053, 0.057, "Head_2", "Neck", 0.10),
	], SCARF, 16, 0.018, Finish.FABRIC, 0.91)
	_loft([
		_ring(Vector3(0, 0.985, 0), 0.195, 0.134, "Hips"),
		_ring(Vector3(0, 1.016, 0), 0.193, 0.131, "Hips"),
	], WEBBING, 18, 0.0, Finish.FABRIC, 0.78)
	_pouch("Hips", Vector3(0.015, 1.001, 0.131), Vector3(0.062, 0.027, 0.017), HARDWARE, Finish.METAL)
	_pouch("Hips", Vector3(0.156, 0.978, -0.088), Vector3(0.075, 0.113, 0.086), WEBBING)


func _carrier() -> void:
	const TORSO := "Torso_2"
	# A low chest rig leaves the blouse and shoulder visible. Webbing crosses
	# the real shoulder shape and the rig is held by a separate side strap.
	_pouch(TORSO, Vector3(0, 1.240, 0.120), Vector3(0.327, 0.223, 0.072), WEBBING)
	_pouch(TORSO, Vector3(0, 1.284, 0.147), Vector3(0.286, 0.096, 0.043), ARMOUR)
	for side in [-1, 1]:
		var x: float = side * 0.123
		_pouch(TORSO, Vector3(x, 1.380, 0.103), Vector3(0.046, 0.135, 0.047), WEBBING)
		_pouch(TORSO, Vector3(x, 1.446, 0.022), Vector3(0.042, 0.045, 0.146), WEBBING)
		_pouch(TORSO, Vector3(x, 1.387, -0.076), Vector3(0.047, 0.107, 0.047), WEBBING)
		_pouch(TORSO, Vector3(side * 0.174, 1.203, -0.008), Vector3(0.043, 0.056, 0.199), WEBBING)
		_pouch(TORSO, Vector3(x, 1.348, 0.132), Vector3(0.029, 0.033, 0.014), HARDWARE, Finish.POLYMER)

	for index in [-1, 0, 1]:
		var x: float = index * 0.077
		_pouch(TORSO, Vector3(x, 1.185, 0.164), Vector3(0.071, 0.107, 0.069), ARMOUR)
		_pouch(TORSO, Vector3(x, 1.22, 0.185), Vector3(0.067, 0.042, 0.039), WEBBING)
		_pouch(TORSO, Vector3(x, 1.19, 0.199), Vector3(0.015, 0.039, 0.008), CLOTH_DARK)

	_pouch(TORSO, Vector3(0.023, 1.311, 0.172), Vector3(0.109, 0.037, 0.006), MARK)
	_pouch(TORSO, Vector3(0, 1.281, -0.146), Vector3(0.278, 0.275, 0.099), WEBBING)
	_pouch(TORSO, Vector3(0, 1.334, -0.177), Vector3(0.274, 0.123, 0.056), ARMOUR)
	_pouch(TORSO, Vector3(0, 1.233, -0.181), Vector3(0.221, 0.081, 0.044), CLOTH_DARK)
	for side in [-1, 1]:
		var x: float = side * 0.084
		_pouch(TORSO, Vector3(x, 1.278, -0.201), Vector3(0.026, 0.206, 0.011), WEBBING)
		_pouch(TORSO, Vector3(x, 1.229, -0.207), Vector3(0.035, 0.025, 0.010), HARDWARE, Finish.POLYMER)
	_pouch(TORSO, Vector3(0, 1.34, -0.211), Vector3(0.187, 0.080, 0.008), MARK)


func _head() -> void:
	const HEAD := "Head_2"
	# A tucked field scarf meets the jaw below protective lenses.
	# The visible skin is a small band between the upper scarf and the helmet.
	_loft([
		_ring(Vector3(0, 1.541, 0.033), 0.049, 0.052, HEAD, "Neck", 0.48),
		_ring(Vector3(0, 1.580, 0.033), 0.061, 0.067, HEAD),
		_ring(Vector3(0, 1.610, 0.030), 0.072, 0.075, HEAD),
		_ring(Vector3(0, 1.633, 0.030), 0.070, 0.077, HEAD),
	], SCARF, 16, 0.014, Finish.FABRIC, 0.82)
	_loft([
		_ring(Vector3(0, 1.625, 0.022), 0.066, 0.071, HEAD),
		_ring(Vector3(0, 1.660, 0.014), 0.073, 0.077, HEAD),
		_ring(Vector3(0, 1.698, 0.005), 0.073, 0.079, HEAD),
		_ring(Vector3(0, 1.723, 0.002), 0.069, 0.074, HEAD),
	], FACE, 14, 0.0, Finish.FABRIC, 0.77)
	# The wraparound goggles stay flush with the face at the temples.
	_loft([
		_ring(Vector3(0, 1.639, 0.071), 0.063, 0.031, HEAD),
		_ring(Vector3(0, 1.645, 0.071), 0.078, 0.038, HEAD),
		_ring(Vector3(0, 1.670, 0.069), 0.080, 0.039, HEAD),
		_ring(Vector3(0, 1.677, 0.066), 0.071, 0.033, HEAD),
	], EYEWEAR, 16, 0.0, Finish.POLYMER, 0.52, Vector3.UP)
	_loft([
		_ring(Vector3(0, 1.646, 0.092), 0.061, 0.016, HEAD),
		_ring(Vector3(0, 1.651, 0.094), 0.071, 0.019, HEAD),
		_ring(Vector3(0, 1.666, 0.090), 0.072, 0.021, HEAD),
		_ring(Vector3(0, 1.671, 0.086), 0.064, 0.020, HEAD),
	], LENS, 16, 0.0, Finish.POLYMER, 0.57, Vector3.UP)
	for side in [-1, 1]:
		_pouch(HEAD, Vector3(side * 0.075, 1.654, 0.020),
			Vector3(0.014, 0.018, 0.111), WEBBING)
		_strap(HEAD, Vector3(side * 0.080, 1.683, 0.008), Vector3(side * 0.053, 1.575, 0.058), 0.005)
	_loft([
		_ring(Vector3(0, 1.682, -0.011), 0.083, 0.087, HEAD),
		_ring(Vector3(0, 1.691, 0.004), 0.100, 0.109, HEAD),
		_ring(Vector3(0, 1.701, 0.004), 0.100, 0.112, HEAD),
	], HARDWARE, 16, 0.0, Finish.POLYMER, 0.82, Vector3.UP)
	_loft([
		_ring(Vector3(0, 1.698, 0.002), 0.098, 0.109, HEAD),
		_ring(Vector3(0, 1.716, -0.004), 0.099, 0.107, HEAD),
		_ring(Vector3(0, 1.754, -0.013), 0.091, 0.095, HEAD),
		_ring(Vector3(0, 1.774, -0.014), 0.073, 0.079, HEAD),
		_ring(Vector3(0, 1.784, -0.014), 0.049, 0.054, HEAD),
		_ring(Vector3(0, 1.787, -0.014), 0.001, 0.001, HEAD),
	], HELMET, 16, 0.0, Finish.POLYMER, 0.82, Vector3.UP)
	_pouch(HEAD, Vector3(0, 1.721, 0.102), Vector3(0.039, 0.030, 0.012), HARDWARE, Finish.POLYMER)


func _sleeve(side: String) -> void:
	var upper := "UpperArm." + side
	var lower := "LowerArm." + side
	var palm := "Palm1." + side
	var shoulder := _joint(upper)
	var elbow := _joint(lower)
	var hand := _joint(palm)
	var inset := shoulder.lerp(Vector3(0, 1.409, 0.0), 0.27)
	_loft([
		_ring(inset, 0.059, 0.054, "Torso_2", upper, 0.31),
		_ring(shoulder.lerp(elbow, 0.045), 0.083, 0.081, upper, "Torso_2", 0.24),
		_ring(shoulder.lerp(elbow, 0.28), 0.081, 0.077, upper, "Torso_2", 0.06),
		_ring(shoulder.lerp(elbow, 0.58), 0.072, 0.068, upper),
		_ring(shoulder.lerp(elbow, 0.79), 0.065, 0.062, upper, lower, 0.16),
		_ring(elbow, 0.060, 0.061, upper, lower, 0.50),
		_ring(elbow.lerp(hand, 0.22), 0.061, 0.058, lower, upper, 0.15),
		_ring(elbow.lerp(hand, 0.42), 0.057, 0.056, lower),
		_ring(elbow.lerp(hand, 0.61), 0.051, 0.050, lower),
		_ring(elbow.lerp(hand, 0.83), 0.046, 0.044, lower),
		_ring(elbow.lerp(hand, 0.98), 0.039, 0.041, lower, palm, 0.19),
	], CLOTH, 16, 0.025, Finish.UNIFORM, 0.95)
	_armband(upper, shoulder, elbow)
	_loft([
		_ring(elbow.lerp(hand, 0.86), 0.045, 0.045, lower),
		_ring(elbow.lerp(hand, 0.99), 0.040, 0.042, lower, palm, 0.20),
	], CLOTH_DARK, 16, 0.0, Finish.FABRIC, 0.95)
	_glove(palm, hand, side == "L")


## Give the knuckles and pads independent silhouettes. The pads finish on
## the opposite side of the grip, so the hand reads as closed even in profile.
func _glove(bone: String, wrist: Vector3, support: bool) -> void:
	var grip := wrist + (SUPPORT_CONTACT if support else TRIGGER_CONTACT)
	_round(bone, wrist, Vector3(0.037, 0.032, 0.037), GLOVE)
	if support:
		_round(bone, grip + Vector3(0.013, -0.022, -0.011), Vector3(0.032, 0.020, 0.041), GLOVE)
		_pouch(bone, grip + Vector3(0.035, 0.002, -0.016), Vector3(0.021, 0.050, 0.034), BOOT)
		for i in 4:
			var z := -0.020 + 0.014 * i
			_round(bone, grip + Vector3(-0.020, 0.011, z), Vector3(0.015, 0.023, 0.009), GLOVE)
			_round(bone, grip + Vector3(-0.009, 0.035, z), Vector3(0.019, 0.009, 0.009), HARDWARE)
		_round(bone, grip + Vector3(0.024, 0.024, 0.021), Vector3(0.014, 0.024, 0.012), GLOVE)
	else:
		_pouch(bone, grip + Vector3(-0.024, -0.011, -0.010), Vector3(0.026, 0.072, 0.049), GLOVE)
		_pouch(bone, grip + Vector3(-0.040, -0.007, -0.005), Vector3(0.014, 0.055, 0.032), BOOT)
		for i in 4:
			var y := 0.016 - 0.014 * i
			_round(bone, grip + Vector3(-0.011, y, 0.025), Vector3(0.023, 0.009, 0.012), GLOVE)
			_round(bone, grip + Vector3(0.013, y, 0.017), Vector3(0.009, 0.009, 0.020), GLOVE)
		_round(bone, grip + Vector3(0.014, 0.019, -0.017), Vector3(0.013, 0.011, 0.022), GLOVE)


## Both ends follow the taper of the sleeve. A small allowance keeps the
## team textile on top even at the outer bend of the shoulder.
func _armband(bone: String, shoulder: Vector3, elbow: Vector3) -> void:
	_loft([
		_ring(shoulder.lerp(elbow, 0.20), 0.085, 0.084, bone, "Torso_2", 0.12),
		_ring(shoulder.lerp(elbow, 0.32), 0.083, 0.080, bone, "Torso_2", 0.048),
		_ring(shoulder.lerp(elbow, 0.53), 0.076, 0.073, bone),
	], MARK, 16, 0.0, Finish.FABRIC, 0.95)


func _trousers(side: String) -> int:
	var upper := "UpperLeg." + side
	var lower := "LowerLeg." + side
	var foot := "Foot." + side
	var hip := _joint(upper)
	var knee := _joint(lower)
	var ankle := _joint(foot)
	var base := _vertices.size()
	_loft([
		_ring(hip.lerp(knee, 0.02), 0.107, 0.112, upper, "Hips", 0.47),
		_ring(hip.lerp(knee, 0.16), 0.106, 0.111, upper, "Hips", 0.16),
		_ring(hip.lerp(knee, 0.37), 0.098, 0.102, upper),
		_ring(hip.lerp(knee, 0.65), 0.084, 0.089, upper, lower, 0.04),
		_ring(hip.lerp(knee, 0.83), 0.080, 0.080, upper, lower, 0.23),
		_ring(knee, 0.079, 0.077, lower, upper, 0.50),
		_ring(knee.lerp(ankle, 0.20), 0.078, 0.078, lower, upper, 0.24),
		_ring(knee.lerp(ankle, 0.39), 0.074, 0.080, lower),
		_ring(knee.lerp(ankle, 0.62), 0.066, 0.071, lower),
		_ring(knee.lerp(ankle, 0.79), 0.062, 0.067, lower),
		_ring(knee.lerp(ankle, 0.91), 0.056, 0.060, lower, foot, 0.16),
	], CLOTH_DARK, TROUSER_SIDES, 0.021, Finish.UNIFORM, 0.95)
	var outer := 1.0 if side == "L" else -1.0
	# The pocket is almost flat, with its flap following the outside of the thigh.
	_pouch(upper, hip.lerp(knee, 0.40) + Vector3(outer * 0.083, 0.014, -0.026),
		Vector3(0.029, 0.130, 0.110), CLOTH_DARK)
	_pouch(upper, hip.lerp(knee, 0.27) + Vector3(outer * 0.092, 0.014, -0.028),
		Vector3(0.021, 0.036, 0.112), CLOTH)
	_boot(lower, foot, ankle)
	return base


## The outside halves of the thigh rings continue to a common waist. The
## remaining inward halves meet through a crotch panel so neither leg ends
## at a visible socket when the character runs or crouches.
func _join_trousers(left: int, right: int) -> void:
	var waist := _vertices.size()
	var hips := _skeleton.find_bone("Hips")
	var quarter := TROUSER_SIDES / 4
	for column in TROUSER_SIDES + 1:
		var fraction := float(column) / TROUSER_SIDES
		var angle := TAU * fraction
		var x := cos(angle)
		var z := -sin(angle)
		_vertex(Vector3(0.191 * x, 0.995, 0.130 * z), Vector3(x, 0.15, z).normalized(),
			CLOTH_DARK, Vector2(fraction * 2.0, -0.39), Finish.UNIFORM, hips)
	for column in TROUSER_SIDES:
		var leg := left if column < quarter or column >= 3 * quarter else right
		var a := waist + column
		var b := leg + column
		_indices.append_array([a, a + 1, b, a + 1, b + 1, b])
	_indices.append_array([waist + quarter, right + quarter, left + quarter,
		waist + 3 * quarter, left + 3 * quarter, right + 3 * quarter])
	for column in TROUSER_SIDES / 2:
		var a := left + quarter + column
		var b := right + posmod(quarter - column, TROUSER_SIDES)
		var next := right + posmod(quarter - column - 1, TROUSER_SIDES)
		_indices.append_array([a, b, a + 1, a + 1, b, next])


func _boot(lower: String, foot: String, ankle: Vector3) -> void:
	# Horizontal profiles give the sole a flat tread and keep its underside
	# on the existing grounded-feet envelope. The shaft tapers at the cuff.
	_loft([
		_ring(ankle + Vector3(0, -0.108, 0.047), 0.067, 0.107, foot),
		_ring(ankle + Vector3(0, -0.085, 0.048), 0.069, 0.111, foot),
		_ring(ankle + Vector3(0, -0.065, 0.043), 0.066, 0.101, foot),
		_ring(ankle + Vector3(0, -0.048, 0.031), 0.061, 0.083, foot),
		_ring(ankle + Vector3(0, -0.025, 0.010), 0.055, 0.069, foot),
		_ring(ankle + Vector3(0, 0.001, 0.006), 0.053, 0.061, foot, lower, 0.24),
		_ring(ankle + Vector3(0, 0.044, 0.002), 0.057, 0.061, lower, foot, 0.24),
	], BOOT, 12, 0.0, Finish.FABRIC, 0.49, Vector3.UP)
	_loft([
		_ring(ankle + Vector3(0, -0.120, 0.043), 0.001, 0.001, foot),
		_ring(ankle + Vector3(0, -0.120, 0.043), 0.065, 0.103, foot),
		_ring(ankle + Vector3(0, -0.114, 0.045), 0.071, 0.111, foot),
		_ring(ankle + Vector3(0, -0.100, 0.046), 0.072, 0.115, foot),
		_ring(ankle + Vector3(0, -0.092, 0.048), 0.070, 0.112, foot),
	], SOLE, 12, 0.0, Finish.POLYMER, 0.49, Vector3.UP)
	for row in 3:
		var lace := ankle + Vector3(0, -0.057 + row * 0.015, 0.117 - row * 0.014)
		_pouch(foot, lace, Vector3(0.043, 0.006, 0.011), WEBBING)


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
		material: int = Finish.FABRIC, exponent: float = 1.0, profile_axis: Vector3 = Vector3.ZERO) -> void:
	var base := _vertices.size()
	var length := 0.0
	for row in rings.size():
		var ring := rings[row]
		if row > 0:
			length += ring.at.distance_to(rings[row - 1].at)
		var previous := rings[maxi(row - 1, 0)]
		var next := rings[mini(row + 1, rings.size() - 1)]
		var axis := (next.at - previous.at).normalized() if profile_axis == Vector3.ZERO else profile_axis
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
