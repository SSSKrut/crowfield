class_name ValleyScenery
extends Node3D
## Client-only detail for Valley. Cover, pathfinding and capture positions
## continue to use the original map geometry.

const ROUTE_FONT := preload("res://assets/type/BarlowCondensed-Bold.ttf")
const GRASS_SHADER := preload("res://assets/valley/grass.gdshader")
const RIDGE_SHADER := preload("res://assets/valley/skyline.gdshader")
const RIDGE_MEADOW := preload("res://assets/valley/aerial_grass_rock-diff.jpg")
const RIDGE_SHALE := preload("res://assets/valley/rocky_terrain_02-diff.jpg")
const RIDGE_SAMPLES := 240
const RIDGE_RINGS := 33
const RIDGE_NEAR := 122.0
const RIDGE_FAR := 612.0
## Ridge center, spread, and mean height in meters.
const RIDGE_BANDS := [Vector3(192.0, 34.0, 47.0), Vector3(331.0, 51.0, 77.0), Vector3(507.0, 68.0, 122.0)]
const GRASS_TILE := 18
const GRASS_BLADE_COUNT := 6

var _scene: MapScene
var _terrain: Terrain


func _init(map: MapScene, wear: PackedFloat32Array) -> void:
	name = "ValleyScenery"
	_scene = map
	_terrain = map.terrain
	_build_ridges()
	_build_woodland()
	_build_ground_cover(wear)
	_build_structure_details()
	_build_gate_signs()
	add_child(CustomsScenery.new(map))


## The overlap starts under Valley's render terrain. From there three broken
## ridges rise in front of each other. One indexed mesh keeps the work out of
## the shadow pass and leaves the authoritative terrain and bounds untouched.
func _build_ridges() -> void:
	var shape := FastNoiseLite.new()
	shape.seed = 41783
	shape.frequency = 0.009
	shape.fractal_octaves = 4
	var detail := FastNoiseLite.new()
	detail.seed = 9161
	detail.frequency = 0.031
	detail.fractal_octaves = 3
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	vertices.resize(RIDGE_RINGS * RIDGE_SAMPLES)
	colors.resize(vertices.size())
	indices.resize((RIDGE_RINGS - 1) * RIDGE_SAMPLES * 6)
	for i in RIDGE_SAMPLES:
		var direction := Vector2.from_angle(TAU * float(i) / RIDGE_SAMPLES)
		var square_scale := 1.0 / maxf(absf(direction.x), absf(direction.y))
		var edge := direction * RIDGE_NEAR * square_scale
		var edge_height := visual_height(_terrain.height_at(edge.x, edge.y), edge.x, edge.y, _scene.play_area)
		for ring in RIDGE_RINGS:
			var reach := lerpf(RIDGE_NEAR, RIDGE_FAR, float(ring) / (RIDGE_RINGS - 1))
			var square_mix := 1.0 - smoothstep(RIDGE_NEAR, 220.0, reach)
			var at := direction * (reach + RIDGE_NEAR * (square_scale - 1.0) * square_mix)
			var height := _ridge_elevation(reach, direction, at, shape, detail)
			height = lerpf(edge_height - 0.6, height, smoothstep(RIDGE_NEAR, 167.0, reach))
			var index := ring * RIDGE_SAMPLES + i
			vertices[index] = Vector3(at.x, height, at.y)
			var woods := 0.46 + 1.21 * shape.get_noise_2d(at.x + 850.0, at.y - 370.0) \
				+ 0.30 * detail.get_noise_2d(at.x + 260.0, at.y + 140.0)
			var heath := 0.50 + 0.78 * detail.get_noise_2d(at.x - 70.0, at.y + 530.0)
			colors[index] = Color(clampf(woods, 0, 1), clampf(heath, 0, 1), smoothstep(148, 558, reach))
	for ring in RIDGE_RINGS:
		for i in RIDGE_SAMPLES:
			var offset := ring * RIDGE_SAMPLES
			var side := vertices[offset + (i + 1) % RIDGE_SAMPLES] - vertices[offset + posmod(i - 1, RIDGE_SAMPLES)]
			var radial := vertices[mini(RIDGE_RINGS - 1, ring + 1) * RIDGE_SAMPLES + i] \
				- vertices[maxi(0, ring - 1) * RIDGE_SAMPLES + i]
			normals.append(side.cross(radial).normalized())
			if ring == RIDGE_RINGS - 1:
				continue
			var a := offset + i
			var b := offset + (i + 1) % RIDGE_SAMPLES
			var c := a + RIDGE_SAMPLES
			var d := b + RIDGE_SAMPLES
			var triangle := a * 6
			indices[triangle] = a
			indices[triangle + 1] = c
			indices[triangle + 2] = b
			indices[triangle + 3] = b
			indices[triangle + 4] = c
			indices[triangle + 5] = d
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = RIDGE_SHADER
	material.set_shader_parameter("meadow", RIDGE_MEADOW)
	material.set_shader_parameter("shale", RIDGE_SHALE)
	mesh.surface_set_material(0, material)
	var landscape := MeshInstance3D.new()
	landscape.name = "DistantRidges"
	landscape.mesh = mesh
	landscape.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(landscape)


static func _ridge_elevation(reach: float, direction: Vector2, at: Vector2,
		shape: FastNoiseLite, detail: FastNoiseLite) -> float:
	var height := 4.0
	for band: Vector3 in RIDGE_BANDS:
		var along := direction * band.x
		var fold := shape.get_noise_2d(along.x + band.z * 13.0, along.y - band.x * 1.7)
		var mass := shape.get_noise_2d(along.x - band.z * 2.0, along.y + band.x)
		var crest := band.x + fold * band.y * 0.72
		var side := (reach - crest) / band.y
		height += band.z * (1.0 + 0.56 * mass) * exp(-0.5 * side * side)
	height += (shape.get_noise_2d(at.x, at.y) * 9.0 + detail.get_noise_2d(at.x, at.y) * 2.6)
	return height


## Shape the corner-to-corner skyline outside the invisible collision wall.
static func visual_height(height: float, x: float, z: float, play_area: float) -> float:
	var beyond := maxf(absf(x), absf(z)) - play_area
	var influence := smoothstep(2.0, 25.0, beyond)
	var saddle := sin(x * 0.044 + z * 0.061) * 0.5 + 0.5
	var peak := sin(x * 0.058 - z * 0.046) * sin(z * 0.031 + 1.5)
	var shape := height * (0.38 + 0.39 * saddle) + 3.0 + 10.0 * peak
	return lerpf(height, shape, influence)


func _build_woodland() -> void:
	var pine_transforms: Array[Transform3D] = []
	var pine_colors: Array[Color] = []
	var leaf_transforms: Array[Transform3D] = []
	var leaf_colors: Array[Color] = []
	var random := RandomNumberGenerator.new()
	random.seed = 12019
	for tree in _scene.trees:
		var yaw := random.randf_range(0.0, TAU)
		var size := tree.size
		var position := tree.position
		position.y = visual_height(position.y, position.x, position.z, _scene.play_area)
		if tree.pine:
			var basis := Basis(Vector3.UP, yaw).scaled_local(Vector3(0.9, 1.0, 0.9) * size)
			pine_transforms.append(Transform3D(basis, position))
			pine_colors.append(Color8(44, 75, 53).lerp(Color8(70, 100, 65), random.randf()))
		else:
			var color := Color8(51, 78, 54).lerp(Color8(89, 112, 68), random.randf())
			for branch in 6:
				var angle := yaw + TAU * float(branch) / 5.0
				var reach := size * (0.0 if branch == 5 else random.randf_range(0.55, 1.15))
				var offset := Vector3(cos(angle) * reach, 2.7 * size, sin(angle) * reach)
				offset.y += (1.4 if branch == 5 else random.randf_range(-0.2, 0.55)) * size
				var dimensions := Vector3(0.94, 0.90, 0.88) * size * random.randf_range(0.8, 1.22)
				leaf_transforms.append(Transform3D(Basis(Vector3.UP, angle).scaled_local(dimensions), position + offset))
				leaf_colors.append(color.lerp(Color8(111, 127, 74), random.randf() * 0.27))
	for bush in _scene.bushes:
		var yaw := random.randf() * TAU
		var position := bush.position
		position.y = visual_height(position.y, position.x, position.z, _scene.play_area)
		for branch in 4:
			var angle := yaw + branch * 1.65
			var size := bush.size * random.randf_range(0.53, 0.83)
			var offset := Vector3(cos(angle) * size * 0.52, size * 0.50, sin(angle) * size * 0.52)
			var dimensions := Vector3(0.65, 0.58, 0.67) * size
			leaf_transforms.append(Transform3D(Basis(Vector3.UP, angle).scaled_local(dimensions), position + offset))
			leaf_colors.append(Color8(56, 76, 57).lerp(Color8(103, 116, 64), random.randf()))
	var leaf_mesh := _canopy_mesh()
	var foliage := _plant_material()
	foliage.cull_mode = BaseMaterial3D.CULL_DISABLED
	foliage.backlight_enabled = true
	foliage.backlight = Color(0.11, 0.15, 0.095)
	_instances("DeciduousCanopy", leaf_mesh, leaf_transforms, leaf_colors, foliage)
	_instances("FirCanopy", _fir_mesh(), pine_transforms, pine_colors, foliage)


static func _canopy_mesh() -> ArrayMesh:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	const SIDES := 11
	const STEPS := 6
	var points := PackedVector3Array()
	for step in range(STEPS + 1):
		var pitch := PI * float(step) / STEPS
		var radial := sin(pitch)
		for side in SIDES:
			var angle := TAU * float(side) / SIDES + step * 0.27
			var lobed := 1.0 + 0.16 * sin(3.0 * angle + pitch * 2.1) + 0.10 * cos(5.0 * angle - pitch * 3.6)
			points.append(Vector3(cos(angle) * radial * lobed, cos(pitch), sin(angle) * radial * lobed))
	for step in STEPS:
		for side in SIDES:
			var a := step * SIDES + side
			var b := step * SIDES + (side + 1) % SIDES
			if step != 0:
				_foliage_triangle(mesh, points[a], points[b], points[a + SIDES])
			if step != STEPS - 1:
				_foliage_triangle(mesh, points[b], points[b + SIDES], points[a + SIDES])
	mesh.generate_normals()
	return mesh.commit()


static func _fir_mesh() -> ArrayMesh:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	const BRANCHES := 14
	const WHORLS := 8
	for layer in WHORLS:
		var t := float(layer) / (WHORLS - 1)
		var root := 1.75 + t * 4.06
		var reach := lerpf(1.86, 0.20, t)
		for branch in BRANCHES:
			var azimuth := TAU * float(branch) / BRANCHES + layer * 0.61
			var dir := Vector3(cos(azimuth), 0.0, sin(azimuth))
			var across := Vector3(-dir.z, 0.0, dir.x)
			var length := reach * (0.91 + 0.13 * sin(azimuth * 3.0 + layer * 3.2))
			var center := Vector3(0.0, root + reach * 0.46, 0.0)
			var shoulder := Vector3(0.0, root, 0.0) + dir * length * 0.48
			var left := shoulder + across * reach * 0.24
			var right := shoulder - across * reach * 0.24
			var tip := Vector3(0.0, root - 0.09 + 0.18 * sin(azimuth * 5.0), 0.0) + dir * length
			var underside := shoulder - Vector3.UP * reach * 0.2
			_foliage_triangle(mesh, center, left, tip)
			_foliage_triangle(mesh, center, tip, right)
			_foliage_triangle(mesh, left, underside, tip)
			_foliage_triangle(mesh, tip, underside, right)
	mesh.generate_normals()
	return mesh.commit()


static func _foliage_triangle(mesh: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for point in [a, b, c]:
		var grain := sin(point.x * 9.1 + point.y * 5.2 + point.z * 12.5)
		var shade := 0.88 + 0.075 * grain
		mesh.set_color(Color(shade, shade, shade))
		mesh.add_vertex(point)


func _build_ground_cover(wear: PackedFloat32Array) -> void:
	var material := ShaderMaterial.new()
	material.shader = GRASS_SHADER
	var blade_mesh := _grass_mesh()
	var occupied := _building_footprints()
	var random := RandomNumberGenerator.new()
	random.seed = 5330
	var half := _terrain.half_size()
	for tile_z in range(-108, 108, GRASS_TILE):
		for tile_x in range(-108, 108, GRASS_TILE):
			var transforms: Array[Transform3D] = []
			var colors: Array[Color] = []
			for j in 175:
				var x := float(tile_x) + random.randf() * GRASS_TILE
				var z := float(tile_z) + random.randf() * GRASS_TILE
				var lookup := Vector2i(roundi(x + half), roundi(z + half))
				var h := _terrain.height_at(x, z)
				var clearing := 0.33 + 0.24 * sin(x * 0.23 + z * 0.17) * sin(z * 0.21)
				if h < -1.47 or wear[lookup.y * _terrain.samples + lookup.x] > 0.37 or occupied[lookup.y * _terrain.samples + lookup.x] or random.randf() < clearing:
					continue
				var river := h < -0.72
				var size := random.randf_range(0.56, 1.28) * (1.20 if river else 1.0)
				var at := Vector3(x, visual_height(h, x, z, _scene.play_area) - 0.018, z)
				transforms.append(Transform3D(Basis(Vector3.UP, random.randf() * TAU).scaled_local(Vector3.ONE * size), at))
				var color := Color8(62, 76, 46).lerp(Color8(127, 131, 78), random.randf())
				colors.append(color.lerp(Color8(70, 100, 78), 0.4) if river else color)
			var patch := _instances("GrassPatch", blade_mesh, transforms, colors, material, false)
			if patch != null:
				patch.visibility_range_end = 49.0


func _building_footprints() -> PackedByteArray:
	var result := PackedByteArray()
	var side := _terrain.samples
	var half := _terrain.half_size()
	result.resize(side * side)
	for box in _scene.boxes:
		if box.kind not in [MapScene.Kind.ROOF, MapScene.Kind.WOOD, MapScene.Kind.TRUNK, MapScene.Kind.CONCRETE, MapScene.Kind.SANDBAG, MapScene.Kind.PLASTER, MapScene.Kind.PLANKS, MapScene.Kind.METAL, MapScene.Kind.ROCK, MapScene.Kind.MASONRY,
				MapScene.Kind.SLATE, MapScene.Kind.COBBLES]:
			continue
		var at := box.transform.origin
		var reach := int(ceil(Vector2(box.half_extents.x, box.half_extents.z).length())) + 2
		var x0 := roundi(at.x + half)
		var z0 := roundi(at.z + half)
		var inv := box.transform.affine_inverse()
		for z in range(maxi(0, z0 - reach), mini(side, z0 + reach + 1)):
			for x in range(maxi(0, x0 - reach), mini(side, x0 + reach + 1)):
				var p := inv * Vector3(x - half, at.y, z - half)
				if absf(p.x) < box.half_extents.x + 0.32 and absf(p.z) < box.half_extents.z + 0.32:
					result[z * side + x] = 1
	return result


static func _grass_mesh() -> ArrayMesh:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	for blade in GRASS_BLADE_COUNT:
		var angle := float(blade) * 2.399963
		var radial := Vector3(cos(angle), 0.0, sin(angle))
		var cross := Vector3(-radial.z, 0.0, radial.x)
		var height := 0.12 + 0.15 * (float(blade % 4) / 3.0)
		var foot := radial * (0.034 + float(blade) * 0.018)
		var shoulder := foot + Vector3.UP * height * 0.63 + radial * 0.055
		var tip := foot + Vector3.UP * height + radial * (0.06 + height * 0.21)
		var left := foot + cross * 0.014
		var right := foot - cross * 0.014
		var left_top := shoulder + cross * 0.008
		var right_top := shoulder - cross * 0.008
		for point in [left, left_top, right, left_top, right_top, right, left_top, tip, right_top]:
			mesh.set_normal(Vector3.UP)
			mesh.add_vertex(point)
	return mesh.commit()


func _build_structure_details() -> void:
	var trims: Array[Transform3D] = []
	var colors: Array[Color] = []
	var gables := SurfaceTool.new()
	gables.begin(Mesh.PRIMITIVE_TRIANGLES)
	for box in _scene.boxes:
		var width := box.half_extents.x * 2.0
		var height := box.half_extents.y * 2.0
		var depth := box.half_extents.z * 2.0
		match box.kind:
			MapScene.Kind.ROOF:
				if height > 0.25:
					# The higher village roofs are out of reach from street level.
					_gabled_roof(gables, trims, colors, box, width, height, depth)
				else:
					var panels := ceili(width / 0.54)
					for i in range(1, panels):
						var x := width * (float(i) / panels - 0.5)
						_trim(trims, colors, box, Vector3(x, height / 2.0 + 0.012, 0.0),
							Vector3(0.027, 0.025, depth - 0.08), Color8(102, 105, 93))
				for side: float in [-1.0, 1.0]:
					_trim(trims, colors, box, Vector3(0.0, -height * 0.26, side * depth / 2.0),
						Vector3(width, 0.075, 0.052), Color8(64, 66, 58))
			MapScene.Kind.WOOD, MapScene.Kind.METAL:
				if width < 0.72 or depth < 0.72 or height < 0.50:
					continue
				var finish := Color8(112, 96, 72) if box.kind == MapScene.Kind.WOOD else Color8(91, 100, 83)
				var fastener := Color8(177, 151, 107) if box.kind == MapScene.Kind.WOOD else Color8(168, 156, 108)
				for side: float in [-1.0, 1.0]:
					for x_sign: float in [-1.0, 1.0]:
						_trim(trims, colors, box, Vector3(x_sign * (width / 2.0 - 0.073), 0.0, side * depth / 2.0),
							Vector3(0.10, height - 0.045, 0.035), finish)
					for y_sign: float in [-1.0, 1.0]:
						_trim(trims, colors, box, Vector3(0.0, y_sign * (height / 2.0 - 0.075), side * depth / 2.0),
							Vector3(width - 0.24, 0.085, 0.034), finish)
					_trim(trims, colors, box, Vector3(0.0, height * 0.22, side * (depth / 2.0 + 0.014)),
						Vector3(width * 0.22, 0.046, 0.025), fastener)
					_trim(trims, colors, box, Vector3(side * (width / 2.0 - 0.15), height / 2.0 + 0.014, 0.0),
						Vector3(0.11, 0.036, depth), finish)
			MapScene.Kind.PLASTER:
				_dress_plaster(box, trims, colors)
			MapScene.Kind.CONCRETE, MapScene.Kind.MASONRY:
				if box.kind == MapScene.Kind.MASONRY:
					_dress_plaster(box, trims, colors)
				# A ledge sits on the full-length, narrow bridge parapets.
				if depth > 18.0 and width < 0.55 and height < 1.15:
					_trim(trims, colors, box, Vector3(0.0, height / 2.0 - 0.038, 0.0),
						Vector3(width + 0.075, 0.08, depth + 0.04), Color8(114, 119, 104))

	_instances("ArchitecturalTrim", BoxMesh.new(), trims, colors, _plant_material())
	gables.generate_normals()
	var roof := _plant_material()
	roof.cull_mode = BaseMaterial3D.CULL_DISABLED
	gables.set_material(roof)
	var roofs := MeshInstance3D.new()
	roofs.name = "VillageRoofProfiles"
	roofs.mesh = gables.commit()
	add_child(roofs)


static func _gabled_roof(mesh: SurfaceTool, trims: Array[Transform3D], colors: Array[Color],
		box: MapScene.Box, width: float, height: float, depth: float) -> void:
	var half_width := width / 2.0 - 0.022
	var half_depth := depth / 2.0 - 0.026
	var base := height / 2.0 - 0.015
	var rise := minf(0.71, depth * 0.13)
	var ridge_left := Vector3(-half_width, base + rise, 0.0)
	var ridge_right := Vector3(half_width, base + rise, 0.0)
	var tint := sin(absf(box.transform.origin.x) * 2.2 + absf(box.transform.origin.z) * 0.71) * 0.5 + 0.5
	var slate := Color8(102, 114, 111).lerp(Color8(123, 102, 81), tint * 0.72)
	var pitch := atan2(rise, half_depth)
	var slope := Vector2(rise, half_depth).length()
	var panels := ceili(width / 0.60)
	for side: float in [-1.0, 1.0]:
		var left := Vector3(-half_width, base, side * half_depth)
		var right := Vector3(half_width, base, side * half_depth)
		_roof_triangle(mesh, box, left, ridge_left, right, slate, side < 0.0)
		_roof_triangle(mesh, box, ridge_left, ridge_right, right, slate, side < 0.0)
		for i in range(1, panels):
			var x := width * (float(i) / panels - 0.5)
			var position := Vector3(x, base + rise * 0.5 + 0.018, side * half_depth * 0.5)
			var basis := Basis(Vector3.RIGHT, pitch * side).scaled_local(Vector3(0.033, 0.028, slope))
			trims.append(box.transform * Transform3D(basis, position))
			colors.append(slate.lightened(0.10))
		for end: float in [-1.0, 1.0]:
			var position := Vector3(half_width * end, base + rise * 0.5, side * half_depth * 0.5)
			var basis := Basis(Vector3.RIGHT, pitch * side).scaled_local(Vector3(0.061, 0.070, slope + 0.07))
			trims.append(box.transform * Transform3D(basis, position))
			colors.append(Color8(80, 86, 76))
	_roof_triangle(mesh, box, ridge_left, Vector3(-half_width, base, -half_depth),
		Vector3(-half_width, base, half_depth), Color8(111, 116, 100), false)
	_roof_triangle(mesh, box, ridge_right, Vector3(half_width, base, -half_depth),
		Vector3(half_width, base, half_depth), Color8(111, 116, 100), true)
	_trim(trims, colors, box, Vector3(0.0, base + rise + 0.013, 0.0),
		Vector3(width, 0.047, 0.11), slate.lightened(0.08))


static func _roof_triangle(mesh: SurfaceTool, box: MapScene.Box,
		a: Vector3, b: Vector3, c: Vector3, color: Color, reverse: bool) -> void:
	mesh.set_color(color)
	mesh.add_vertex(box.transform * a)
	mesh.add_vertex(box.transform * (c if reverse else b))
	mesh.add_vertex(box.transform * (b if reverse else c))



static func _dress_plaster(box: MapScene.Box, trims: Array[Transform3D], colors: Array[Color]) -> void:
	var half := box.half_extents
	if half.z > 0.19:
		return
	var at := box.transform.origin
	var bottom := at.y - half.y
	var window_sill := bottom < ValleyMap.VILLAGE_LEVEL - 0.18 and half.y > 0.6 and half.y < 0.7 and half.x < 0.62
	var lintel := bottom > ValleyMap.VILLAGE_LEVEL + 1.8 and half.y <= 0.64
	for side: float in [-1.0, 1.0]:
		if window_sill:
			_trim(trims, colors, box, Vector3(0.0, half.y - 0.04, side * half.z),
				Vector3(half.x * 2.0 + 0.065, 0.10, 0.09), Color8(143, 143, 118))
			for end: float in [-1.0, 1.0]:
				_trim(trims, colors, box, Vector3(end * (half.x + 0.023), half.y + 0.46, side * (half.z + 0.012)),
					Vector3(0.066, 0.94, 0.069), Color8(92, 105, 87))
		elif lintel:
			_trim(trims, colors, box, Vector3(0.0, -half.y + 0.055, side * (half.z + 0.010)),
				Vector3(half.x * 2.0 + 0.07, 0.11, 0.064), Color8(93, 105, 90))
		if half.y > 1.3 or window_sill:
			_trim(trims, colors, box, Vector3(0.0, -half.y + 0.27, side * half.z),
				Vector3(half.x * 2.0 + 0.025, 0.21, 0.028), Color8(123, 125, 105))


static func _trim(transforms: Array[Transform3D], colors: Array[Color], box: MapScene.Box,
		at: Vector3, size: Vector3, color: Color) -> void:
	transforms.append(box.transform * Transform3D(Basis().scaled_local(size), at))
	colors.append(color)


## Read these at the gate, at the scale of the actual boards.
func _build_gate_signs() -> void:
	for side: float in [-1.0, 1.0]:
		var turn := 0.0 if side > 0.0 else PI
		for lane: float in [-1.0, 1.0]:
			var label := Label3D.new()
			label.text = "‹  CUSTOMS" if lane < 0.0 else "PINE RIDGE  ›"
			label.font = ROUTE_FONT
			label.font_size = 35
			label.pixel_size = 0.008
			label.outline_size = 3
			label.modulate = Color8(241, 220, 171)
			label.outline_modulate = Color8(45, 41, 33)
			label.visibility_range_end = 31.0
			var marking := Vector3(lane * ValleyMap.ROUTE_POST_X,
				ValleyMap.BASE_LEVEL + ValleyMap.ROUTE_BOARD_Y + 0.01, ValleyMap.ROUTE_POST_Z + 0.135)
			label.position = ValleyMap.BASE * side + marking.rotated(Vector3.UP, turn)
			label.rotation.y = turn
			add_child(label)


static func _plant_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.9
	return material


func _instances(label: String, mesh: Mesh, transforms: Array[Transform3D], colors: Array[Color],
		material: Material, shadows: bool = true) -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
		multimesh.set_instance_color(i, colors[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = label
	instance.multimesh = multimesh
	instance.material_override = material
	if not shadows:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance
