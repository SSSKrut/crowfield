class_name CharacterAsset
extends RefCounted
## CharacterAsset is the soldier model, loaded once and shared by every soldier
## drawn with it (ARCHITECTURE.md, 10.1): the robot of the prototype with all
## its parts merged into one mesh skinned on the GPU, so that a soldier is one
## draw call. The parts take their colours from their materials as vertex
## colours; the accent colour, the most saturated one, is painted in the team
## colour by an instance parameter of the shared material.

const MODEL_PATH := "res://assets/prototype/RobotExpressive.glb"
## MODEL_HEIGHT is the height of the soldier capsule of the default tuning,
## from the soles to the top of the head.
const MODEL_HEIGHT := 1.8
const CLIPS := ["Idle", "Walking", "Running"]
enum Clip { IDLE, WALKING, RUNNING }

const _SHADER := """
shader_type spatial;
// The accent parts of the robot, marked by a zero alpha in their vertex
// colour, take the team colour of the soldier.
instance uniform vec4 team_color : source_color = vec4(0.79, 0.58, 0.22, 1.0);
void fragment() {
	ALBEDO = mix(team_color.rgb, COLOR.rgb, COLOR.a);
	ROUGHNESS = 0.75;
}
"""

## accent is the colour the accent parts have in the model.
var accent := Color(0.79, 0.58, 0.22)
var material: ShaderMaterial
var mesh: ArrayMesh
var skin: Skin
## bones maps a bone name to its index in every soldier's skeleton.
var bones := {}
## scale and offset place the model, whose root is the imported scene, so
## that it is MODEL_HEIGHT tall with its soles at zero.
var scale := 1.0
var offset := Vector3.ZERO
## periods are the lengths of the clips in seconds.
var periods := PackedFloat32Array()
## rig is how the skeleton falls, built on first use.
var rig: RagdollRig
var _template: PackedScene


## load_asset loads the model, or returns the error as a String.
static func load_asset() -> Variant:
	var scene: PackedScene = load(MODEL_PATH)
	if scene == null:
		return "cannot load %s" % MODEL_PATH
	var asset := CharacterAsset.new()
	var error := asset._build(scene.instantiate())
	if error != "":
		return "model %s: %s" % [MODEL_PATH, error]
	return asset


func _build(root: Node3D) -> String:
	var skeleton: Skeleton3D = root.find_child("Skeleton3D", true, false)
	var player: AnimationPlayer = root.find_child("AnimationPlayer", true, false)
	if skeleton == null or player == null:
		root.free()
		return "no skeleton or animations"
	for i in skeleton.get_bone_count():
		bones[skeleton.get_bone_name(i)] = i
	# A soldier plays only the clips it needs, with only the tracks of bones:
	# the faces of the robot went with its parts.
	var library := AnimationLibrary.new()
	for clip in CLIPS:
		if not player.has_animation(clip):
			root.free()
			return "no clip %s" % clip
		var animation: Animation = player.get_animation(clip).duplicate()
		for track in range(animation.get_track_count() - 1, -1, -1):
			var path := animation.track_get_path(track)
			if not str(path).begins_with("RootNode/RobotArmature/Skeleton3D:"):
				animation.remove_track(track)
		animation.loop_mode = Animation.LOOP_LINEAR
		library.add_animation(clip, animation)
		periods.append(animation.length)
	for name in player.get_animation_library_list():
		player.remove_animation_library(name)
	player.add_animation_library("", library)
	_merge(skeleton)
	# The template keeps the imported hierarchy, which the animation tracks
	# name, with the merged mesh in place of the parts.
	for child in skeleton.get_children():
		skeleton.remove_child(child)
		child.free()
	var body := MeshInstance3D.new()
	body.name = "Body"
	body.mesh = mesh
	body.skin = skin
	body.material_override = material
	skeleton.add_child(body)
	body.owner = root
	body.skeleton = NodePath("..")
	_template = PackedScene.new()
	_template.pack(root)
	_measure(root, skeleton, player)
	root.free()
	return ""


## _merge makes one mesh of every part in the space of the skeleton at rest:
## the rigid parts under bone attachments are bound to their bone, the
## skinned hands keep their weights.
func _merge(skeleton: Skeleton3D) -> void:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var bone_indices := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	var rests: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		rests.append(skeleton.get_bone_global_rest(i))
	var saturation := -1.0
	for node in skeleton.find_children("*", "MeshInstance3D", true, false):
		var part: MeshInstance3D = node
		var attachment := part.get_parent() as BoneAttachment3D
		var to_skeleton := Transform3D()
		var bone := -1
		if attachment != null:
			bone = skeleton.find_bone(attachment.bone_name)
			to_skeleton = rests[bone] * part.transform
		for surface in part.mesh.get_surface_count():
			var arrays := part.mesh.surface_get_arrays(surface)
			var surface_material := part.mesh.surface_get_material(surface) as StandardMaterial3D
			var color := Color.WHITE if surface_material == null else surface_material.albedo_color
			var hsv := color.s * color.v
			if hsv > saturation:
				saturation = hsv
				accent = color
			var base := vertices.size()
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var surface_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var surface_bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
			var surface_weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
			var per_vertex := surface_bones.size() / maxi(1, positions.size())
			for v in positions.size():
				if bone >= 0:
					vertices.append(to_skeleton * positions[v])
					normals.append((to_skeleton.basis.inverse().transposed() * surface_normals[v]).normalized())
					bone_indices.append_array([bone, 0, 0, 0])
					weights.append_array([1.0, 0.0, 0.0, 0.0])
				else:
					# A skinned part: its rest position through its own binds,
					# then the same weights on the bones of the skeleton.
					var at := Vector3.ZERO
					var turned := Vector3.ZERO
					var kept := PackedInt32Array([0, 0, 0, 0])
					var kept_weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
					for k in mini(per_vertex, 4):
						var weight := surface_weights[v * per_vertex + k]
						var bind := surface_bones[v * per_vertex + k]
						var bone_of_bind := skeleton.find_bone(part.skin.get_bind_name(bind))
						var pose := rests[bone_of_bind] * part.skin.get_bind_pose(bind)
						at += pose * positions[v] * weight
						turned += pose.basis * surface_normals[v] * weight
						kept[k] = bone_of_bind
						kept_weights[k] = weight
					vertices.append(at)
					normals.append(turned.normalized())
					bone_indices.append_array(kept)
					weights.append_array(kept_weights)
				colors.append(color)
			var surface_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in surface_indices:
				indices.append(base + index)
	# The shader reads sRGB in Compatibility and linear colours in Forward+.
	# Mark the accent parts by a zero alpha in either renderer.
	var linear_colors := RenderingServer.get_current_rendering_method() != "gl_compatibility"
	for i in colors.size():
		var source := colors[i]
		var color := source.srgb_to_linear() if linear_colors else source
		color.a = 0.0 if source.is_equal_approx(accent) else 1.0
		colors[i] = color
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_BONES] = bone_indices
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	skin = Skin.new()
	for i in skeleton.get_bone_count():
		skin.add_named_bind(skeleton.get_bone_name(i), rests[i].affine_inverse())
	var shader := Shader.new()
	shader.code = _SHADER
	material = ShaderMaterial.new()
	material.shader = shader


## _measure finds how tall the robot stands in the first frame of the idle
## clip, by skinning the vertices on the processor once.
func _measure(root: Node3D, skeleton: Skeleton3D, player: AnimationPlayer) -> void:
	var animation := player.get_animation("Idle")
	var poses: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		poses.append(skeleton.get_bone_rest(i))
	for track in animation.get_track_count():
		var path := animation.track_get_path(track)
		var bone := skeleton.find_bone(path.get_concatenated_subnames())
		if bone < 0:
			continue
		var pose := poses[bone]
		match animation.track_get_type(track):
			Animation.TYPE_POSITION_3D:
				pose.origin = animation.position_track_interpolate(track, 0.0)
			Animation.TYPE_ROTATION_3D:
				pose.basis = Basis(animation.rotation_track_interpolate(track, 0.0)).scaled(pose.basis.get_scale())
			Animation.TYPE_SCALE_3D:
				pose.basis = Basis(pose.basis.get_rotation_quaternion()).scaled(animation.scale_track_interpolate(track, 0.0))
		poses[bone] = pose
	var globals: Array[Transform3D] = []
	for i in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(i)
		globals.append(poses[i] if parent < 0 else globals[parent] * poses[i])
	# The chain of local transforms from the skeleton up to the root: the model
	# is not in a scene tree here.
	var to_root := Transform3D()
	var node: Node = skeleton
	while node != root:
		to_root = (node as Node3D).transform * to_root
		node = node.get_parent()
	var arrays := mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bone_indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var bone_weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var low := Vector3.INF
	var high := -Vector3.INF
	for v in positions.size():
		var at := Vector3.ZERO
		for k in 4:
			var weight := bone_weights[v * 4 + k]
			if weight > 0:
				var bone := bone_indices[v * 4 + k]
				at += globals[bone] * (skin.get_bind_pose(bone) * positions[v]) * weight
		at = to_root * at
		low = low.min(at)
		high = high.max(at)
	scale = MODEL_HEIGHT / (high.y - low.y)
	offset = Vector3(0, -low.y * scale, 0)


## instantiate makes the visual of one soldier.
func instantiate() -> CharacterView:
	var view := CharacterView.new()
	view.setup(self, _template.instantiate())
	return view
