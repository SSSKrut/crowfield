class_name CustomsScenery
extends Node3D
## Dressed surfaces and low planting for the two Customs approaches.
## The visible timber and stone follow the collision boxes in ValleyMap.

const STONE := preload("res://assets/valley/old_stone_wall-diff.jpg")
const TIMBER := preload("res://assets/valley/wood_planks_dirt-diff.jpg")
const SETTS := preload("res://assets/valley/cobblestone_01-diff.jpg")
const SIGNS := preload("res://assets/valley/customs-signs.png")
const PAINT := Color8(77, 91, 76)
const DARK_PAINT := Color8(54, 67, 63)
const OAK := Color8(96, 76, 57)
const LIMESTONE := Color8(157, 145, 119)
const CAPSTONE := Color8(126, 123, 107)
const BOARD := Color8(53, 70, 63)

var _stone := SurfaceTool.new()
var _timber := SurfaceTool.new()
var _paving := SurfaceTool.new()
var _plant := SurfaceTool.new()
var _signs := SurfaceTool.new()
var _box: Array = BoxMesh.new().get_mesh_arrays()
var _scene: MapScene


func _init(scene: MapScene) -> void:
	name = "CustomsCrossing"
	_scene = scene
	for surface in [_stone, _timber, _paving, _plant, _signs]:
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side: float in [1.0, -1.0]:
		var turn := 0.0 if side > 0.0 else PI
		var village := Transform3D(Basis(Vector3.UP, turn), ValleyMap.VILLAGE * side)
		_build_village(village)
		_build_bridge(-ValleyMap.BRIDGE_X * side)
	_finish("DressedStone", _stone, _material(STONE, 1.28))
	_finish("PaintedJoinery", _timber, _material(TIMBER, 0.94))
	_finish("BridgeSetts", _paving, _material(SETTS, 0.76))
	_finish("RiverbankPlants", _plant, _material(), false)
	var signs := StandardMaterial3D.new()
	signs.albedo_texture = SIGNS
	signs.texture_repeat = false
	signs.roughness = 0.94
	_finish("PaintedSigns", _signs, signs, false)


## Keep color changes on village walls and roofs. The stone station and its
## annex share burnt tile. The opposite courtyard buildings have gray slate.
static func surface_tint(kind: int, center: Vector3) -> Color:
	var side := 1.0 if center.z >= 0.0 else -1.0
	var local := Vector3(center.x * side, center.y, center.z * side) - ValleyMap.VILLAGE
	if absf(local.x) > 16.8 or absf(local.z) > 15.8:
		return Color.WHITE
	match kind:
		MapScene.Kind.SLATE:
			if local.y < 2.1:
				return Color(0.85, 0.88, 0.83)
			if local.x < -4.5 and local.z < -3.3:
				return Color(1.0, 0.67, 0.53)
			return Color(0.68, 0.78, 0.82)
		MapScene.Kind.MASONRY:
			return Color(0.96, 0.90, 0.79)
		MapScene.Kind.PLASTER:
			return Color(1.0, 0.92, 0.76) if local.z < 0.0 else Color(0.93, 0.96, 0.85)
		MapScene.Kind.PLANKS:
			return Color(0.86, 0.91, 0.77)
	return Color.WHITE


func _build_village(origin: Transform3D) -> void:
	var level := ValleyMap.VILLAGE_LEVEL
	# This is the large station from ValleyMap. Frames stand beside the
	# openings, and the shutters stay outside the usable firing angles.
	for house in ValleyMap.CUSTOMS_HOUSES:
		_dress_house(origin, house.center, house.footprint, house.height, house.door, house.wall)
	_dress_landmark(origin)
	_dress_well(origin)

	for band in [Vector2(-15.0, 1.0), Vector2(15.0, 1.0)]:
		for offset in [-12.4, -9.3, -6.8, 6.8, 9.3, 12.4]:
			for shift in [-0.42, 0.38]:
				var position := Vector3(offset, level, band.x + band.y * shift)
				_build_plant(origin * position, 0.33 + (absf(offset) - 7.0) * 0.011, 3, offset * 0.7)
	# Low ledges on the existing courtyard walls. Their tops stop at the
	# actual cover height so the rectangular firing edges are still honest.
	for cut in [Vector3(-10.20, -1.0, 1.60), Vector3(-5.70, -1.0, 3.0),
			Vector3(5.95, -2.0, 3.30), Vector3(11.15, -2.0, 2.70)]:
		_block(_stone, origin, Vector3(cut.x, level + 1.014, cut.y),
			Vector3(cut.z, 0.085, 0.50), CAPSTONE)


func _dress_house(origin: Transform3D, center: Vector2, footprint: Vector2, height: float, door: int, wall: int) -> void:
	var level := ValleyMap.VILLAGE_LEVEL
	var half := footprint * 0.5
	var corners := [Vector2(-half.x, half.y), Vector2(half.x, half.y), Vector2(half.x, -half.y), Vector2(-half.x, -half.y)]
	for side in 4:
		var a: Vector2 = center + corners[side]
		var b: Vector2 = center + corners[(side + 1) % 4]
		var along := (b - a).normalized()
		# Looking along ValleyMap's clockwise wall order.
		var outside := -along.orthogonal()
		var span := a.distance_to(b)
		var mid := (a + b) * 0.5
		var yaw := atan2(-along.y, along.x)
		var facade := origin * Transform3D(Basis(Vector3.UP, yaw),
			Vector3(mid.x + outside.x * 0.034, level, mid.y + outside.y * 0.034))
		# Eaves and the timber uprights weather separately from the plaster.
		_block(_timber, facade, Vector3(0, height - 0.075, 0), Vector3(span - 0.03, 0.19, 0.17), OAK)
		for edge: float in [-1.0, 1.0]:
			_block(_timber, facade, Vector3(edge * (span * 0.5 - 0.065), height * 0.5, 0),
				Vector3(0.13, height - 0.18, 0.105), DARK_PAINT)
		var foundation := [Vector2(-span * 0.5, span * 0.5)]
		if side == door:
			foundation = [Vector2(-span * 0.5, -0.95), Vector2(0.95, span * 0.5)]
			_door_stones(facade)
			if wall == MapScene.Kind.MASONRY:
				_relief_arch(facade)
			_block(_stone, facade, Vector3(0, 2.29, 0), Vector3(2.18, 0.17, 0.16), LIMESTONE)
			for edge: float in [-1.0, 1.0]:
				_block(_timber, facade, Vector3(edge * 1.0, 1.115, 0),
					Vector3(0.15, 2.19, 0.12), OAK)
			if span > 6.0:
				_window(facade, -2.4)
				_window(facade, 2.4)
		elif span > 4.5:
			_window(facade, -span / 6.0)
			_window(facade, span / 6.0)
		else:
			_window(facade, 0.0)
		for section: Vector2 in foundation:
			_block(_stone, facade, Vector3((section.x + section.y) * 0.5, 0.108, 0.006),
				Vector3(section.y - section.x, 0.215, 0.095), CAPSTONE)


func _door_stones(facade: Transform3D) -> void:
	# Low, worn setts at the thresholds follow the actual ground profile.
	for row in 6:
		for column in 4:
			var x := (column - 1.5) * 0.41 + 0.075 * float(row % 2)
			var z := 0.24 + row * 0.39
			var width := 0.20 if row > 2 and column in [0, 3] else 0.216
			var relief := 0.012 + 0.009 * sin(row * 2.47 + column * 1.87)
			_paving.set_color(LIMESTONE.lerp(CAPSTONE, (sin(row + column * 2.2) + 1.0) * 0.11))
			_paving.set_normal(Vector3.UP)
			for offset: Vector2 in [Vector2(-width, 0.2), Vector2(-width, -0.2), Vector2(width, 0.2),
					Vector2(width, 0.2), Vector2(-width, -0.2), Vector2(width, -0.2)]:
				var at := facade * Vector3(x + offset.x, 0, z + offset.y)
				at.y = _scene.terrain.height_at(at.x, at.z) + relief
				_paving.add_vertex(at)


## Raised stonework on the old station entry gives it a broad arch without
## filling any part of the rectangular doorway.
func _relief_arch(facade: Transform3D) -> void:
	_stone.set_normal(facade.basis.z)
	for block in 9:
		var left := PI * (block + 0.035) / 9.0
		var right := PI * (block + 0.965) / 9.0
		_stone.set_color(LIMESTONE.lightened(0.04 * float(block % 3)))
		for setting: Vector2 in [Vector2(left, 0), Vector2(right, 1), Vector2(left, 1),
				Vector2(left, 0), Vector2(right, 0), Vector2(right, 1)]:
			var bend := Vector2.from_angle(setting.x)
			var width := lerpf(1.04, 1.28, setting.y)
			var rise := lerpf(0.48, 0.68, setting.y)
			_stone.add_vertex(facade * Vector3(bend.x * width, 2.245 + bend.y * rise, 0.092))


func _window(facade: Transform3D, x: float) -> void:
	_block(_stone, facade, Vector3(x, 0.945, 0), Vector3(1.42, 0.10, 0.19), LIMESTONE)
	_block(_timber, facade, Vector3(x, 2.055, 0), Vector3(1.34, 0.085, 0.125), OAK)
	for side: float in [-1.0, 1.0]:
		_block(_timber, facade, Vector3(x + side * 0.72, 1.50, 0),
			Vector3(0.30, 0.98, 0.085), PAINT)
		for at: float in [1.19, 1.81]:
			_block(_timber, facade, Vector3(x + side * 0.72, at, 0.063),
				Vector3(0.28, 0.049, 0.052), DARK_PAINT)


func _dress_landmark(origin: Transform3D) -> void:
	var base := ValleyMap.VILLAGE_LEVEL
	var at := ValleyMap.CUSTOMS_TOWER
	var center := Vector3(at.x, base, at.y)
	for face in 4:
		var turn := face * PI / 2.0
		var basis := Basis(Vector3.UP, turn)
		var panel := origin * Transform3D(basis, center + basis * Vector3(0.0, 0, 1.51))
		# Cut corner stones and timber above the existing solid tower.
		for edge: float in [-1.0, 1.0]:
			for course in 11:
				var width := 0.42 if course % 2 == 0 else 0.29
				_block(_stone, panel, Vector3(edge * (1.48 - width * 0.5), 0.42 + 0.405 * course, 0.015),
					Vector3(width, 0.375, 0.105), LIMESTONE)
			_block(_timber, panel, Vector3(edge * 1.28, 5.57, 0.025), Vector3(0.23, 1.09, 0.15), DARK_PAINT)
		for height in [4.94, 6.06]:
			_block(_timber, panel, Vector3(0, height, 0.03), Vector3(3.10, 0.20, 0.18), PAINT)
		for edge: float in [-1.0, 1.0]:
			var strut := panel.translated_local(Vector3(edge * 0.91, 5.54, 0.090))
			strut = strut.rotated_local(Vector3.BACK, edge * -0.44)
			_block(_timber, strut, Vector3.ZERO, Vector3(0.18, 1.03, 0.14), LIMESTONE)
		_sign(panel, Vector3(0, 4.02, 0.06), Vector2(2.56, 0.88), 0)


func _dress_well(origin: Transform3D) -> void:
	var level := ValleyMap.VILLAGE_LEVEL
	var at := ValleyMap.CUSTOMS_WELL
	var center := Vector3(at.x, 0.0, at.y)
	for side in 8:
		var angle := side * TAU / 8.0
		var basis := Basis(Vector3.UP, -angle + PI / 2.0)
		var outward := Vector3(cos(angle), 0, sin(angle))
		var rim := origin * Transform3D(basis, center + outward * 0.79)
		_block(_stone, rim, Vector3(0, level + 0.827, 0), Vector3(0.75, 0.074, 0.36), LIMESTONE)
	for side: float in [-1.0, 1.0]:
		_block(_timber, origin, center + Vector3(side * 0.69, level + 1.55, 0.0),
			Vector3(0.205, 1.39, 0.21), PAINT)


func _build_bridge(x: float) -> void:
	var center := ValleyMap.river_z(x)
	var level := ValleyMap.BRIDGE_DECK
	var origin := Transform3D(Basis.IDENTITY, Vector3(x, level, center))
	# Resurface the existing deck at walking height. Coping follows the two
	# parapets and clearly shows where the open lane begins and ends.
	_block(_paving, origin, Vector3.ZERO, Vector3(4.39, 0.010, ValleyMap.BRIDGE_HALF * 2.0 - 0.02), Color8(156, 146, 126))
	for side: float in [-1.0, 1.0]:
		for run in 22:
			var z := -10.5 + run
			var tone := Color8(131, 128, 112).lerp(LIMESTONE, 0.36 + 0.23 * sin(run * 2.5))
			_block(_stone, origin, Vector3(side * 2.0, 0.878, z),
				Vector3(0.43, 0.070, 0.974), tone)
		_block(_stone, origin, Vector3(side * 2.203, -0.23, 0), Vector3(0.048, 0.12, ValleyMap.BRIDGE_HALF * 2.0 - 0.22), CAPSTONE)
		for bank: float in [-1.0, 1.0]:
			var panel := origin * Transform3D(Basis(Vector3.UP, 0.0 if bank > 0.0 else PI),
				Vector3(side * 2.02, 0.65, bank * 11.11))
			if side == bank:
				_sign(panel, Vector3(0, 0.0, 0.005), Vector2(0.52, 0.28), 1)
	# Two bands of shallow rooted growth flank the bridge without lining the
	# approach itself. Leave the cover and the traversable lane in clear view.
	for side: float in [-1.0, 1.0]:
		for bank: float in [-1.0, 1.0]:
			for index in 12:
				var along := x + side * (3.85 + index * 0.84)
				var across := ValleyMap.river_z(along) + bank * (7.95 + sin(index * 1.97) * 0.70)
				var at := Vector3(along, _scene.terrain.height_at(along, across) - 0.025, across)
				_build_plant(at, 0.54 + sin(index * 2.71 + bank) * 0.12, 7, index * 2.39 + bank)


func _build_plant(at: Vector3, height: float, leaves: int, turn: float) -> void:
	for leaf in leaves:
		var angle := turn + float(leaf) * 2.40
		var out := Vector3(cos(angle), 0, sin(angle))
		var side := out.cross(Vector3.UP)
		var length := height * (0.68 + float(leaf % 4) * 0.10)
		var foot := at + out * (0.04 + 0.015 * leaf)
		var knee := foot + out * length * 0.20 + Vector3.UP * length * 0.56
		var tip := foot + out * length * 0.57 + Vector3.UP * length
		var width := 0.027 if leaves > 3 else 0.045
		var tan_tip := Color8(137, 130, 69).lerp(Color8(73, 102, 61), float(leaf % 3) * 0.30)
		var foot_tint := Color8(53, 75, 47)
		_leaf_triangle(foot - side * width, foot + side * width, knee - side * width, foot_tint, tan_tip)
		_leaf_triangle(foot + side * width, knee + side * width, knee - side * width, foot_tint, tan_tip)
		_leaf_triangle(knee - side * width, knee + side * width, tip, foot_tint, tan_tip)


func _leaf_triangle(a: Vector3, b: Vector3, c: Vector3, base: Color, tip: Color) -> void:
	var normal := (c - a).cross(b - a).normalized()
	for vertex in [a, b, c]:
		_plant.set_color(tip if vertex == c else base)
		_plant.set_normal(normal)
		_plant.add_vertex(vertex)


func _sign(face: Transform3D, at: Vector3, size: Vector2, row: int) -> void:
	_block(_timber, face, at, Vector3(size.x, size.y, 0.070), BOARD)
	var half := size * 0.5
	_signs.set_normal(face.basis.z)
	for corner: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
			Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
		# Sample inside the two atlas rows. The border remains baked.
		_signs.set_uv(Vector2(lerpf(0.01, 0.99, corner.x), float(row) * 0.5 + lerpf(0.006, 0.494, corner.y)))
		var offset := Vector3((corner.x * 2.0 - 1.0) * half.x,
			(1.0 - corner.y * 2.0) * half.y, 0.037)
		_signs.add_vertex(face * (at + offset))


func _block(surface: SurfaceTool, basis: Transform3D, at: Vector3, size: Vector3, color: Color) -> void:
	var vertices: PackedVector3Array = _box[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = _box[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = _box[Mesh.ARRAY_INDEX]
	surface.set_color(color)
	for index in indices:
		surface.set_normal(basis.basis * normals[index])
		surface.add_vertex(basis * (at + vertices[index] * size))


func _finish(label: String, surface: SurfaceTool, material: Material, cast_shadows := true) -> void:
	surface.index()
	surface.set_material(material)
	var instance := MeshInstance3D.new()
	instance.name = label
	instance.mesh = surface.commit()
	if not cast_shadows:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


static func _material(texture: Texture2D = null, scale := 1.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.94
	if texture == null:
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		material.albedo_texture = texture
		material.uv1_triplanar = true
		material.uv1_world_triplanar = true
		material.uv1_scale = Vector3.ONE * scale
	return material
