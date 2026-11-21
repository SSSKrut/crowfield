class_name MapView
extends Node3D
## MapView draws a map: the terrain as one mesh coloured in its vertices, the
## boxes as one MultiMesh for each kind, tree crowns, bushes and water, which
## only the client has, and the balls of the prototype, which roll in the
## client's own physics. Valley adds instanced scenery and weathered materials.

## The colour of each kind of box; an instance varies it a little.
const VALLEY_GROUND := preload("res://assets/valley/ground.gdshader")
const VALLEY_RIVER := preload("res://assets/valley/river.gdshader")
const MEADOW_DETAIL := preload("res://assets/valley/aerial_grass_rock-diff.jpg")
const DIRT_DETAIL := preload("res://assets/valley/dirt_aerial_02-diff.jpg")
const ROCK_DETAIL := preload("res://assets/valley/rocky_terrain_02-diff.jpg")
const PLASTER_DETAIL := preload("res://assets/valley/painted_plaster_wall-diff.jpg")
const PLANK_DETAIL := preload("res://assets/valley/wood_planks_dirt-diff.jpg")

const COLORS := {
	MapScene.Kind.GROUND: Color8(115, 125, 115),
	MapScene.Kind.CONCRETE: Color8(130, 135, 124),
	MapScene.Kind.PLASTER: Color8(219, 209, 182),
	MapScene.Kind.ROOF: Color8(110, 119, 109),
	MapScene.Kind.WOOD: Color8(156, 128, 89),
	MapScene.Kind.PLANKS: Color8(137, 119, 88),
	MapScene.Kind.SANDBAG: Color8(135, 131, 100),
	MapScene.Kind.ROCK: Color8(137, 142, 128),
	MapScene.Kind.METAL: Color8(77, 91, 78),
	MapScene.Kind.TRUNK: Color8(81, 70, 53),
	MapScene.Kind.HAY: Color8(159, 143, 83),
	MapScene.Kind.BLUE_CLOTH: Color8(60, 110, 220),
	MapScene.Kind.RED_CLOTH: Color8(210, 70, 60),
	MapScene.Kind.MASONRY: Color8(174, 183, 174),
	MapScene.Kind.SLATE: Color8(133, 147, 151),
	MapScene.Kind.COBBLES: Color8(159, 150, 127),
}
const MASONRY_DETAIL := preload("res://assets/valley/old_stone_wall-diff.jpg")
const SLATE_DETAIL := preload("res://assets/valley/roof_slates_02-diff.jpg")
const COBBLE_DETAIL := preload("res://assets/valley/cobblestone_01-diff.jpg")
const PROTOTYPE_COLORS := {MapScene.Kind.GROUND: Color8(115, 125, 115), MapScene.Kind.WOOD: Color8(145, 130, 105)}
const PROP_TINTS := [Color8(255, 161, 0), Color8(102, 191, 255), Color8(255, 109, 194)]

var scene: MapScene
## props are the balls of the map, for the client to put back.
var props: Array[RigidBody3D] = []
var _detail: NoiseTexture2D
## _fine is a subtler detail for the walls of buildings.
var _fine: NoiseTexture2D
var _flag_cloth: Array[StandardMaterial3D] = []
var _flag_labels: Array[Label3D] = []
var _flag_colors: Array[Color] = []


func _init(map: MapScene) -> void:
	scene = map
	name = "Map"


func _ready() -> void:
	_detail = _detail_texture(Color(0.74, 0.74, 0.74), Color(1.06, 1.06, 1.06))
	_fine = _detail_texture(Color(0.88, 0.88, 0.88), Color(1.04, 1.04, 1.04))
	if scene.terrain != null:
		var wear := _build_terrain()
		add_child(ValleyScenery.new(scene, wear))
	_build_boxes()
	for water in scene.waters:
		_build_water(water)
	_build_props()
	_build_flags()


## update_flags paints the world markers from the last server snapshot.
func update_flags(state: MatchState) -> void:
	if state == null:
		return
	for index in _flag_cloth.size():
		var flag := state.flags[index]
		var color := _flag_color(flag.owner, flag.contested)
		if _flag_colors[index] == color:
			continue
		_flag_colors[index] = color
		_flag_cloth[index].albedo_color = color
		_flag_labels[index].modulate = color.lightened(0.30)


static func _flag_color(team: int, contested: bool) -> Color:
	if contested:
		return Color8(242, 189, 83)
	return Hud.TEAM_COLORS.get(team, Color8(208, 208, 184))


func _build_flags() -> void:
	var pole_material := StandardMaterial3D.new()
	pole_material.albedo_color = Color8(63, 72, 68)
	pole_material.metallic = 0.3
	for zone in scene.flags:
		var root := Node3D.new()
		root.position = zone.center
		add_child(root)
		var pole_mesh := CylinderMesh.new()
		pole_mesh.height = 4.5
		pole_mesh.top_radius = 0.045
		pole_mesh.bottom_radius = 0.07
		pole_mesh.radial_segments = 8
		var pole := MeshInstance3D.new()
		pole.mesh = pole_mesh
		pole.material_override = pole_material
		pole.position.y = 2.25
		root.add_child(pole)
		var cloth_mesh := BoxMesh.new()
		cloth_mesh.size = Vector3(1.25, 0.80, 0.045)
		var cloth := MeshInstance3D.new()
		cloth.mesh = cloth_mesh
		cloth.position = Vector3(0.65, 3.95, 0.0)
		var material := StandardMaterial3D.new()
		material.roughness = 0.86
		var neutral := _flag_color(Game.Team.NONE, false)
		material.albedo_color = neutral
		cloth.material_override = material
		root.add_child(cloth)
		_flag_cloth.append(material)
		_flag_colors.append(neutral)
		var label := Label3D.new()
		label.text = zone.name
		label.position.y = 4.95
		label.font_size = 23
		label.outline_size = 7
		label.modulate = neutral.lightened(0.30)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0012
		label.visibility_range_end = 45.0
		root.add_child(label)
		_flag_labels.append(label)


## reset puts the props back where they started.
func reset() -> void:
	for i in props.size():
		props[i].transform = scene.spheres[i].transform
		props[i].linear_velocity = Vector3.ZERO
		props[i].angular_velocity = Vector3.ZERO


static func _detail_texture(dark: Color, light: Color) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.02
	noise.fractal_octaves = 4
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.noise = noise
	var ramp := Gradient.new()
	ramp.set_color(0, dark)
	ramp.set_color(1, light)
	texture.color_ramp = ramp
	return texture


func _material(color: Color, detail_scale: float, detail: Texture2D = null) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.92
	if detail_scale > 0:
		material.albedo_texture = detail if detail != null else _detail
		material.uv1_triplanar = true
		material.uv1_world_triplanar = true
		material.uv1_scale = Vector3.ONE * detail_scale
	return material


# The terrain.


func _build_terrain() -> PackedFloat32Array:
	var terrain := scene.terrain
	var count := terrain.samples
	var half := terrain.half_size()
	var worn := _worn_ground()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(count * count)
	normals.resize(count * count)
	colors.resize(count * count)
	for z in count:
		for x in count:
			var i := z * count + x
			var world_x := x - half
			var world_z := z - half
			var h := ValleyScenery.visual_height(terrain.heights[i], world_x, world_z, scene.play_area)
			var dx := ValleyScenery.visual_height(terrain.sample(x + 1, z), world_x + 1, world_z, scene.play_area) \
				- ValleyScenery.visual_height(terrain.sample(x - 1, z), world_x - 1, world_z, scene.play_area)
			var dz := ValleyScenery.visual_height(terrain.sample(x, z + 1), world_x, world_z + 1, scene.play_area) \
				- ValleyScenery.visual_height(terrain.sample(x, z - 1), world_x, world_z - 1, scene.play_area)
			var normal := Vector3(-dx, 2.0, -dz).normalized()
			vertices[i] = Vector3(x - half, h, z - half)
			normals[i] = normal
			var dry := 0.5 + 0.25 * sin((x - half) * 0.063 + (z - half) * 0.117) \
				+ 0.25 * sin((x - half) * 0.109 - (z - half) * 0.091 + 1.4)
			colors[i] = Color(worn[i], dry, smoothstep(0.15, 0.55, 1.0 - normal.y))
	var indices := PackedInt32Array()
	indices.resize((count - 1) * (count - 1) * 6)
	var at := 0
	for z in count - 1:
		for x in count - 1:
			var a := z * count + x
			# The same diagonal as the collision, clockwise seen from above.
			indices[at] = a
			indices[at + 1] = a + 1
			indices[at + 2] = a + count
			indices[at + 3] = a + 1
			indices[at + 4] = a + count + 1
			indices[at + 5] = a + count
			at += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = VALLEY_GROUND
	material.set_shader_parameter("meadow", MEADOW_DETAIL)
	material.set_shader_parameter("track", DIRT_DETAIL)
	material.set_shader_parameter("shale", ROCK_DETAIL)
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.name = "Terrain"
	instance.mesh = mesh
	add_child(instance)
	return worn


## _worn_ground is how worn the ground is at every point of the terrain, from
## zero to one: the roads, and the places soldiers gather.
func _worn_ground() -> PackedFloat32Array:
	var terrain := scene.terrain
	var count := terrain.samples
	var half := terrain.half_size()
	var worn := PackedFloat32Array()
	worn.resize(count * count)
	for road in scene.roads:
		for i in road.size() - 1:
			var a := road[i]
			var b := road[i + 1]
			var low := Vector2i(floori(minf(a.x, b.x) - 4 + half), floori(minf(a.y, b.y) - 4 + half))
			var high := Vector2i(ceili(maxf(a.x, b.x) + 4 + half), ceili(maxf(a.y, b.y) + 4 + half))
			for z in range(maxi(low.y, 0), mini(high.y, count - 1) + 1):
				for x in range(maxi(low.x, 0), mini(high.x, count - 1) + 1):
					var point := Vector2(x - half, z - half)
					var distance := Geometry2D.get_closest_point_to_segment(point, a, b).distance_to(point)
					var wear := smoothstep(3.2, 1.2, distance)
					worn[z * count + x] = maxf(worn[z * count + x], wear)
	for zone in scene.patches:
		var reach := zone.radius + 4
		for z in range(maxi(floori(zone.center.z - reach + half), 0), mini(ceili(zone.center.z + reach + half), count - 1) + 1):
			for x in range(maxi(floori(zone.center.x - reach + half), 0), mini(ceili(zone.center.x + reach + half), count - 1) + 1):
				var distance := Vector2(x - half - zone.center.x, z - half - zone.center.z).length()
				var wear := smoothstep(zone.radius + 3, zone.radius - 2, distance) * 0.85
				worn[z * count + x] = maxf(worn[z * count + x], wear)
	return worn




# The boxes.


func _build_boxes() -> void:
	var by_kind := {}
	for box in scene.boxes:
		if box.kind == MapScene.Kind.INVISIBLE:
			continue
		if not by_kind.has(box.kind):
			by_kind[box.kind] = []
		by_kind[box.kind].append(box)
	var unit := BoxMesh.new()
	var colors: Dictionary = PROTOTYPE_COLORS if scene.terrain == null else COLORS
	for kind: int in by_kind:
		var boxes: Array = by_kind[kind]
		var transforms: Array[Transform3D] = []
		var shades: Array[Color] = []
		var box_mesh: Mesh = unit
		if kind == MapScene.Kind.SANDBAG and scene.terrain != null:
			var bag := SphereMesh.new()
			bag.radial_segments = 12
			bag.rings = 4
			box_mesh = bag
			for box in boxes:
				_stack_sandbags(box, transforms, shades)
		else:
			for i in boxes.size():
				var box: MapScene.Box = boxes[i]
				var basis := box.transform.basis.scaled_local(box.half_extents * 2)
				var position := box.transform.origin
				if kind == MapScene.Kind.TRUNK and scene.terrain != null:
					var ground := scene.terrain.height_at(position.x, position.z)
					position.y += ValleyScenery.visual_height(ground, position.x, position.z, scene.play_area) - ground
				transforms.append(Transform3D(basis, position))
				shades.append(_surface_shade(i, kind))
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = box_mesh
		multimesh.instance_count = transforms.size()
		for i in transforms.size():
			multimesh.set_instance_transform(i, transforms[i])
			multimesh.set_instance_color(i, shades[i])
		var instance := MultiMeshInstance3D.new()
		instance.name = MapScene.Kind.keys()[kind].capitalize()
		instance.multimesh = multimesh
		instance.material_override = _box_material(kind, colors.get(kind, Color.GRAY))
		add_child(instance)


func _box_material(kind: int, color: Color) -> StandardMaterial3D:
	var cloth := kind == MapScene.Kind.BLUE_CLOTH or kind == MapScene.Kind.RED_CLOTH
	if cloth or scene.terrain == null:
		return _material(color, 0.0 if cloth else 0.6, _fine)
	match kind:
		MapScene.Kind.MASONRY:
			return _material(color, 0.50, MASONRY_DETAIL)
		MapScene.Kind.SLATE:
			return _material(color, 0.72, SLATE_DETAIL)
		MapScene.Kind.COBBLES:
			return _material(color, 0.60, COBBLE_DETAIL)
		MapScene.Kind.PLASTER:
			return _material(color, 0.48, PLASTER_DETAIL)
		MapScene.Kind.ROCK, MapScene.Kind.CONCRETE:
			return _material(color, 0.72, ROCK_DETAIL)
		MapScene.Kind.WOOD, MapScene.Kind.PLANKS, MapScene.Kind.TRUNK:
			return _material(color, 0.55, PLANK_DETAIL)
		MapScene.Kind.SANDBAG:
			return _material(color, 1.8, _fine)
		MapScene.Kind.METAL, MapScene.Kind.ROOF:
			var metal := _material(color, 0.66, _fine)
			metal.roughness = 0.83
			metal.metallic = 0.12
			return metal
	return _material(color, 0.6, _fine)


static func _surface_shade(index: int, kind: int) -> Color:
	var shade := 0.87 + 0.21 * fposmod(sin(index * 91.7 + kind * 13.1) * 4375.85, 1.0)
	return Color(shade, shade, shade)


## Alternate course joints within the original cover silhouette. The
## spheres overlap slightly, giving filled bags a rounded profile.
static func _stack_sandbags(box: MapScene.Box, transforms: Array[Transform3D], shades: Array[Color]) -> void:
	var half := box.half_extents
	var rows := maxi(2, roundi(half.y * 2.0 / 0.27))
	var step := 2.0 * half.y / rows
	var columns := maxi(1, ceili(half.x * 2.0 / 0.73))
	var span := 2.0 * half.x / columns
	for row in rows:
		var offset := span * 0.5 if row % 2 == 1 else 0.0
		var y := -half.y + step * (row + 0.5)
		for column in range(-1, columns):
			var left := maxf(-half.x, -half.x + span * column + offset)
			var right := minf(half.x, -half.x + span * (column + 1) + offset)
			if right - left < 0.04:
				continue
			var size := Vector3((right - left) * 1.13, step * 1.24, half.z * 2.0)
			var center := Vector3((left + right) / 2.0, y, sin(float(column) * 2.6 + row) * 0.017)
			transforms.append(box.transform * Transform3D(Basis().scaled_local(size), center))
			shades.append(_surface_shade(transforms.size(), MapScene.Kind.SANDBAG))


# River.


func _build_water(water: MapScene.Water) -> void:
	var plane := PlaneMesh.new()
	plane.size = water.half_extents * 2
	var material := ShaderMaterial.new()
	material.shader = VALLEY_RIVER
	plane.material = material
	var instance := MeshInstance3D.new()
	instance.name = "Water"
	instance.mesh = plane
	instance.position = water.center
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


# Props.


## _build_props drops the balls of the map. They are decoration of the
## client: the server does not simulate them, so the predicted soldier does not
## bump into them either.
func _build_props() -> void:
	for i in scene.spheres.size():
		var sphere := scene.spheres[i]
		var body := RigidBody3D.new()
		body.collision_layer = Game.LAYER_COSMETIC
		body.collision_mask = Game.LAYER_STATIC | Game.LAYER_COSMETIC
		body.transform = sphere.transform
		var shape := CollisionShape3D.new()
		shape.shape = SphereShape3D.new()
		shape.shape.radius = sphere.radius
		body.add_child(shape)
		var visual := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = sphere.radius
		mesh.height = 2 * sphere.radius
		var material := StandardMaterial3D.new()
		material.albedo_color = PROP_TINTS[i % PROP_TINTS.size()]
		mesh.material = material
		visual.mesh = mesh
		body.add_child(visual)
		add_child(body)
		props.append(body)
