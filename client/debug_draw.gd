class_name DebugDraw
extends MeshInstance3D
## DebugDraw draws lines over the world for the debug view (F1): the shapes of
## the map, the hitboxes of other soldiers as the server tests them, the
## server's capsule of the own soldier, the parts of ragdolls and the line of
## sight. Lines are collected during a frame and drawn at its end.

const ZONE_COLORS := [Color.WHITE, Color.RED, Color.YELLOW, Color.GREEN]

var _immediate := ImmediateMesh.new()
var _lines := PackedVector3Array()
var _colors := PackedColorArray()


func _init() -> void:
	mesh = _immediate
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func line(from: Vector3, to: Vector3, color: Color) -> void:
	_lines.append(from)
	_lines.append(to)
	_colors.append(color)


func box(transform: Transform3D, half: Vector3, color: Color) -> void:
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(transform * Vector3(half.x * (1 if i & 1 else -1), half.y * (1 if i & 2 else -1), half.z * (1 if i & 4 else -1)))
	for pair in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		line(corners[pair[0]], corners[pair[1]], color)


## capsule draws a capsule from a to b as rings and lines.
func capsule(a: Vector3, b: Vector3, radius: float, color: Color) -> void:
	var axis := b - a
	var up := axis.normalized() if axis.length() > 1e-4 else Vector3.UP
	var side := up.cross(Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT).normalized()
	var other := up.cross(side)
	const SEGMENTS := 10
	for end in [a, b]:
		for i in SEGMENTS:
			var first := TAU * i / SEGMENTS
			var second := TAU * (i + 1) / SEGMENTS
			line(end + (side * cos(first) + other * sin(first)) * radius, end + (side * cos(second) + other * sin(second)) * radius, color)
	for direction in [side, -side, other, -other]:
		line(a + direction * radius, b + direction * radius, color)
	line(a - up * radius, b + up * radius, color)


func hitboxes(position: Vector3, yaw: float) -> void:
	for i in Hitboxes.COUNT:
		capsule(Hitboxes.place(Hitboxes.A[i], position, yaw), Hitboxes.place(Hitboxes.B[i], position, yaw), Hitboxes.RADII[i], ZONE_COLORS[Hitboxes.ZONES[i]])


func grid(size: int, color: Color) -> void:
	var half := size / 2.0
	for i in size + 1:
		var at := i - half
		line(Vector3(at, 0.01, -half), Vector3(at, 0.01, half), color)
		line(Vector3(-half, 0.01, at), Vector3(half, 0.01, at), color)


## flush draws the lines of the frame and forgets them.
func flush() -> void:
	_immediate.clear_surfaces()
	if _lines.is_empty():
		return
	_immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in _lines.size():
		_immediate.surface_set_color(_colors[i / 2])
		_immediate.surface_add_vertex(_lines[i])
	_immediate.surface_end()
	_lines.resize(0)
	_colors.resize(0)
