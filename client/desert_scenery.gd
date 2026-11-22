class_name DesertScenery
extends Node3D
## Client-only art of the desert: the sourced models DesertMap places, brought
## to metres and recoloured where their source palette does not suit the
## sand. Their collision is among the map's invisible boxes; nothing here
## stops a shot or a soldier.

const MODEL_ROOT := "res://assets/desert/models/"
const PLASTER_DETAIL := preload("res://assets/valley/painted_plaster_wall-diff.jpg")
## The houses come in grey with pale blue glass. The town wears washed plaster
## in a few earth tones instead, keyed by the source colour; walls take the
## tone of their house.
const WALL_SOURCE := "90939b"
const WALL_TONES := [Color8(214, 190, 150), Color8(203, 168, 122), Color8(226, 211, 180), Color8(191, 146, 108)]
const HOUSE_COLORS := {
	"c4c4c4": Color8(236, 225, 202),
	"616573": Color8(146, 118, 88),
	"bde3ff": Color8(58, 72, 80),
	"55bd9b": Color8(64, 110, 118),
}

## A pumpjack nods about the bearing on its post: the walking beam and the
## horse head swing NOD radians either way every NOD_PERIOD seconds; the
## polished rod under the head and the pitman arm under the tail of the beam
## rise and fall with them. Points are in metres of the model, from DesertMap.
const NOD := 0.09
const NOD_PERIOD := 4.6
const BEARING := Vector3(-0.68, 5.12, -0.07)
const BEAM_AXIS := Vector3(3.02, 0, -7.04)
const ROD_TOP := Vector3(3.25, 6.33, 1.36)
const ARM_TOP := Vector3(-3.37, 4.36, -0.8)

var scene: MapScene
var _scenes := {}
var _materials := {}
## _nodding are the moving parts of each pumpjack: [beam pivot, rod slider,
## arm slider, scale to the model's units, phase].
var _nodding: Array[Array] = []
var _time := 0.0


func _init(map: MapScene) -> void:
	scene = map
	name = "DesertScenery"


func _ready() -> void:
	for i in scene.models.size():
		var model := scene.models[i]
		var spec: Dictionary = DesertMap.MODELS[model.name]
		var node := _scene_of(model.name).instantiate() as Node3D
		var scale: float = spec.get("scale", 1.0) * model.size
		var basis := model.transform.basis.scaled(Vector3.ONE * scale)
		node.transform = Transform3D(basis, model.transform.origin) * Transform3D(Basis.IDENTITY, spec.get("offset", Vector3.ZERO))
		node.name = "%s%d" % [model.name.to_pascal_case(), i]
		if model.name.begins_with("house_"):
			_paint_house(node, i)
		add_child(node)
		if model.name == "pumpjack":
			_rig_pumpjack(node, scale / model.size, spec["offset"], i * 1.7)
	set_process(not _nodding.is_empty())


func _process(delta: float) -> void:
	_time += delta
	var axis := BEAM_AXIS.normalized()
	for rig in _nodding:
		var turn := Basis(axis, NOD * sin(TAU * _time / NOD_PERIOD + rig[4]))
		var units: float = rig[3]
		(rig[0] as Node3D).basis = turn
		(rig[1] as Node3D).position.y = ((turn * (ROD_TOP - BEARING)).y - (ROD_TOP - BEARING).y) / units
		(rig[2] as Node3D).position.y = ((turn * (ARM_TOP - BEARING)).y - (ARM_TOP - BEARING).y) / units


## _rig_pumpjack hangs the beam and the head of a pumpjack on a pivot at its
## bearing and the rod and the arm on sliders, all in the units of the model,
## whose parts lie unrotated under one parent.
func _rig_pumpjack(node: Node3D, units: float, offset: Vector3, phase: float) -> void:
	var parts := {}
	for part_name in ["Box010", "Box011", "Cylinder004", "Cylinder003"]:
		parts[part_name] = node.find_child(part_name, true, false) as Node3D
		if parts[part_name] == null or parts[part_name].get_parent() != parts["Box010"].get_parent():
			return
	var parent := parts["Box010"].get_parent() as Node3D
	if parent != node and not parent.transform.is_equal_approx(Transform3D.IDENTITY):
		return
	var pivot := Node3D.new()
	pivot.name = "Beam"
	pivot.position = BEARING / units - offset
	parent.add_child(pivot)
	for part_name in ["Box010", "Box011"]:
		var part: Node3D = parts[part_name]
		parent.remove_child(part)
		part.transform = Transform3D(Basis.IDENTITY, -pivot.position) * part.transform
		pivot.add_child(part)
	var sliders: Array[Node3D] = []
	for part_name in ["Cylinder004", "Cylinder003"]:
		var slider := Node3D.new()
		slider.name = part_name + "Slider"
		parent.add_child(slider)
		var part: Node3D = parts[part_name]
		parent.remove_child(part)
		slider.add_child(part)
		sliders.append(slider)
	_nodding.append([pivot, sliders[0], sliders[1], units, phase])


func _scene_of(model_name: String) -> PackedScene:
	if not _scenes.has(model_name):
		_scenes[model_name] = load(MODEL_ROOT + model_name + ".glb")
	return _scenes[model_name]


## _paint_house gives a house the town's colours: its walls one of the earth
## tones, chosen by its place in the list, under a fine plaster grain.
func _paint_house(node: Node3D, index: int) -> void:
	for found in node.find_children("*", "MeshInstance3D", true, false):
		var instance := found as MeshInstance3D
		for surface in instance.mesh.get_surface_count():
			var source := instance.mesh.surface_get_material(surface) as StandardMaterial3D
			if source == null:
				continue
			var key := source.albedo_color.to_html(false)
			var tone := -1
			var color: Color
			if key == WALL_SOURCE:
				tone = index % WALL_TONES.size()
				color = WALL_TONES[tone]
			elif HOUSE_COLORS.has(key):
				color = HOUSE_COLORS[key]
			else:
				continue
			instance.set_surface_override_material(surface, _material(key, tone, color))


func _material(key: String, tone: int, color: Color) -> StandardMaterial3D:
	var id := "%s/%d" % [key, tone]
	if not _materials.has(id):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.9
		if key != "bde3ff":
			material.albedo_texture = PLASTER_DETAIL
			material.uv1_triplanar = true
			material.uv1_world_triplanar = true
			material.uv1_scale = Vector3.ONE * 0.35
		else:
			material.roughness = 0.35
			material.metallic = 0.2
		_materials[id] = material
	return _materials[id]
