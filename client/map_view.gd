class_name MapView
extends Node3D
## MapView draws a map: the terrain as one mesh coloured in its vertices, the
## boxes as one MultiMesh for each kind, tree crowns, bushes and water, which
## only the client has, and the balls of the prototype, which roll in the
## client's own physics. A noise texture laid over everything in world space
## breaks up the flat colours.

## The colour of each kind of box; an instance varies it a little.
const COLORS := {
	MapScene.Kind.GROUND: Color8(115, 125, 115),
	MapScene.Kind.CONCRETE: Color8(150, 150, 146),
	MapScene.Kind.PLASTER: Color8(214, 202, 178),
	MapScene.Kind.ROOF: Color8(138, 70, 52),
	MapScene.Kind.WOOD: Color8(145, 110, 72),
	MapScene.Kind.PLANKS: Color8(160, 128, 88),
	MapScene.Kind.SANDBAG: Color8(170, 154, 112),
	MapScene.Kind.ROCK: Color8(124, 120, 112),
	MapScene.Kind.METAL: Color8(84, 98, 82),
	MapScene.Kind.TRUNK: Color8(92, 70, 52),
	MapScene.Kind.HAY: Color8(212, 182, 92),
	MapScene.Kind.BLUE_CLOTH: Color8(60, 110, 220),
	MapScene.Kind.RED_CLOTH: Color8(210, 70, 60),
}
const PROTOTYPE_COLORS := {MapScene.Kind.GROUND: Color8(115, 125, 115), MapScene.Kind.WOOD: Color8(145, 130, 105)}
const GRASS := Color(0.3, 0.47, 0.17)
const LUSH := Color(0.21, 0.4, 0.14)
const DRY := Color(0.55, 0.52, 0.27)
const DIRT := Color(0.43, 0.35, 0.25)
const MUD := Color(0.36, 0.32, 0.25)
const STONE := Color(0.46, 0.45, 0.42)
const PROP_TINTS := [Color8(255, 161, 0), Color8(102, 191, 255), Color8(255, 109, 194)]

var scene: MapScene
## props are the balls of the map, for the client to put back.
var props: Array[RigidBody3D] = []
var _detail: NoiseTexture2D
## _fine is a subtler detail for the walls of buildings.
var _fine: NoiseTexture2D


func _init(map: MapScene) -> void:
	scene = map
	name = "Map"


func _ready() -> void:
	_detail = _detail_texture(Color(0.74, 0.74, 0.74), Color(1.06, 1.06, 1.06))
	_fine = _detail_texture(Color(0.88, 0.88, 0.88), Color(1.04, 1.04, 1.04))
	if scene.terrain != null:
		_build_terrain()
	_build_boxes()
	_build_plants()
	for water in scene.waters:
		_build_water(water)
	_build_props()


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


func _build_terrain() -> void:
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
			var h := terrain.heights[i]
			var dx := terrain.sample(x + 1, z) - terrain.sample(x - 1, z)
			var dz := terrain.sample(x, z + 1) - terrain.sample(x, z - 1)
			var normal := Vector3(-dx, 2.0, -dz).normalized()
			vertices[i] = Vector3(x - half, h, z - half)
			normals[i] = normal
			colors[i] = _ground_color(x - half, z - half, h, normal.y, worn[i])
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
	mesh.surface_set_material(0, _material(Color.WHITE, 0.08))
	var instance := MeshInstance3D.new()
	instance.name = "Terrain"
	instance.mesh = mesh
	add_child(instance)


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


## _ground_color mixes grass of a few shades with dry patches, then worn
## ground, mud low by the river and stone on steep slopes.
static func _ground_color(x: float, z: float, h: float, up: float, worn: float) -> Color:
	var patch := 0.5 + 0.25 * sin(x * 0.11 + z * 0.07) + 0.25 * sin(x * 0.05 - z * 0.13 + 1.7)
	var color := LUSH.lerp(GRASS, patch)
	var dry := smoothstep(0.62, 0.9, 0.5 + 0.3 * sin(x * 0.031 - z * 0.023 + 0.4) + 0.2 * cos(x * 0.077 + z * 0.091))
	color = color.lerp(DRY, dry * 0.7)
	color = color.lerp(DIRT, worn)
	color = color.lerp(MUD, smoothstep(-0.6, -1.4, h))
	color = color.lerp(STONE, smoothstep(0.78, 0.6, up) * 0.8)
	var grain := 0.97 + 0.06 * fposmod(sin(x * 12.9898 + z * 78.233) * 43758.5453, 1.0)
	return Color(color.r * grain, color.g * grain, color.b * grain)


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
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = unit
		multimesh.instance_count = boxes.size()
		for i in boxes.size():
			var box: MapScene.Box = boxes[i]
			var basis := box.transform.basis.scaled_local(box.half_extents * 2)
			multimesh.set_instance_transform(i, Transform3D(basis, box.transform.origin))
			var shade := 0.92 + 0.16 * fposmod(sin(i * 91.7 + kind * 13.1) * 4375.85, 1.0)
			multimesh.set_instance_color(i, Color(shade, shade, shade))
		var instance := MultiMeshInstance3D.new()
		instance.name = MapScene.Kind.keys()[kind].capitalize()
		instance.multimesh = multimesh
		var cloth := kind == MapScene.Kind.BLUE_CLOTH or kind == MapScene.Kind.RED_CLOTH
		instance.material_override = _material(colors.get(kind, Color.GRAY), 0.0 if cloth else 0.6, _fine)
		add_child(instance)


# Plants and water.


func _build_plants() -> void:
	var round := SphereMesh.new()
	round.radial_segments = 12
	round.rings = 7
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.radial_segments = 10
	cone.rings = 1
	var crowns: Array[Transform3D] = []
	var pines: Array[Transform3D] = []
	var crown_colors: Array[Color] = []
	var pine_colors: Array[Color] = []
	for i in scene.trees.size():
		var tree := scene.trees[i]
		var size := tree.size
		var shade := 0.85 + 0.3 * fposmod(sin(i * 37.1) * 4375.85, 1.0)
		if tree.pine:
			var height := 5.5 * size
			for layer in 2:
				var wide := (2.0 - layer * 0.6) * size
				var tall := height * (0.62 - layer * 0.16)
				var bottom := height * (0.28 + layer * 0.3)
				pines.append(Transform3D(Basis().scaled(Vector3(wide, tall, wide)), tree.position + Vector3(0, bottom + tall / 2, 0)))
				pine_colors.append(Color(0.16 * shade, 0.32 * shade, 0.15 * shade))
		else:
			var top := 3.2 * size
			crowns.append(Transform3D(Basis(Vector3.UP, i).scaled(Vector3(2.0, 1.6, 2.0) * size), tree.position + Vector3(0, top + 0.4 * size, 0)))
			crown_colors.append(Color(0.3 * shade, 0.47 * shade, 0.2 * shade))
	for i in scene.bushes.size():
		var bush := scene.bushes[i]
		var shade := 0.85 + 0.3 * fposmod(sin(i * 53.3) * 4375.85, 1.0)
		crowns.append(Transform3D(Basis(Vector3.UP, i).scaled(Vector3(1.0, 0.7, 1.1) * bush.size), bush.position + Vector3(0, 0.25 * bush.size, 0)))
		crown_colors.append(Color(0.29 * shade, 0.43 * shade, 0.19 * shade))
	_instances("Crowns", round, crowns, crown_colors)
	_instances("Pines", cone, pines, pine_colors)


func _instances(label: String, mesh: Mesh, transforms: Array[Transform3D], colors: Array[Color]) -> void:
	if transforms.is_empty():
		return
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
	instance.material_override = _material(Color.WHITE, 0.6)
	add_child(instance)


func _build_water(water: MapScene.Water) -> void:
	var plane := PlaneMesh.new()
	plane.size = water.half_extents * 2
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.17, 0.32, 0.38, 0.75)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 0.22
	material.metallic_specular = 0.45
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
