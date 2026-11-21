extends Node3D
## Experiment only. The imported Idle and Run clips drive locomotion. A
## chest-relative rifle and a two-bone pose keep both wrists on the same gun.

const MODEL := preload("res://prototypes/infantry/soldier.glb")
const RIGHT_GRIP := Vector3(0.004, -0.119, 0.073)
const LEFT_GRIP := Vector3(-0.014, -0.085, -0.307)
const NAVY_PATCH := Color8(50, 112, 179)
const RED_PATCH := Color8(172, 61, 53)
const TRIM := Color8(25, 34, 31)
const PACK := Color8(86, 86, 65)
const WEBBING := Color8(113, 98, 69)
const ARMOR := Color8(98, 105, 76)
const HELMET := Color8(61, 71, 52)

var skeleton: Skeleton3D
var player: AnimationPlayer
var rifle: Node3D
var chest: int
var arms: Array[PackedInt32Array] = []


func setup(weapon_factory: ViewModel, team: int) -> void:
	var model := MODEL.instantiate() as Node3D
	add_child(model)
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	_shade_skin(model)
	player = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for clip in [&"Idle", &"Run"]:
		var animation := player.get_animation(clip).duplicate() as Animation
		animation.loop_mode = Animation.LOOP_LINEAR
		player.get_animation_library("").add_animation(String(clip) + "_loop", animation)
	chest = skeleton.find_bone("Chest")
	rifle = weapon_factory.make_held(WeaponTuning.Kind.ASSAULT_RIFLE)
	skeleton.add_child(rifle)
	var team_color := NAVY_PATCH if team == Game.Team.BLUE else RED_PATCH
	for side in ["L", "R"]:
		var upper := skeleton.find_bone("UpperArm_" + side)
		var lower := skeleton.find_bone("LowerArm_" + side)
		var hand := skeleton.find_bone("Hand_" + side)
		arms.append(PackedInt32Array([upper, lower, hand]))
		_sleeve_patch(upper, lower, team_color)
		_glove(hand, skeleton.get_bone_rest(hand).origin)
	_kit(team_color)
	pose(0.0, false)


func pose(seconds: float, running: bool) -> void:
	var clip := &"Run_loop" if running else &"Idle_loop"
	if player.current_animation != clip:
		player.play(clip)
	var duration := player.get_animation(clip).length
	player.seek(fposmod(seconds, duration), true)
	if running:
		var spine := skeleton.find_bone("Spine")
		var lean := Quaternion(Vector3.RIGHT, 0.16)
		skeleton.set_bone_pose_rotation(spine, skeleton.get_bone_pose_rotation(spine) * lean)
	skeleton.force_update_all_bone_transforms()
	var torso := skeleton.get_bone_global_pose(chest)
	var low_ready := 0.24 if running else 0.12
	var rifle_angle := Basis(Vector3.UP, PI + 0.18) * Basis(Vector3.RIGHT, -low_ready)
	rifle.transform = torso * Transform3D(rifle_angle, Vector3(-0.115, 0.005, 0.36))
	for index in arms.size():
		var left := index == 0
		var grip := LEFT_GRIP if left else RIGHT_GRIP
		_hold_arm(arms[index], rifle.transform * grip, torso.basis, left)


func _hold_arm(bones: PackedInt32Array, target: Vector3, chest_basis: Basis, left: bool) -> void:
	var upper := bones[0]
	var lower := bones[1]
	var hand := bones[2]
	var shoulder := skeleton.get_bone_global_pose(upper).origin
	var upper_ray := skeleton.get_bone_rest(lower).origin
	var lower_ray := skeleton.get_bone_rest(hand).origin
	var a := upper_ray.length()
	var b := lower_ray.length()
	var shoulder_to_hand := target - shoulder
	var axis := shoulder_to_hand.normalized()
	var reach := clampf(shoulder_to_hand.length(), absf(a - b) + 0.001, a + b - 0.001)
	var along := (a * a - b * b + reach * reach) / (2.0 * reach)
	var bend := chest_basis * Vector3(0.72 if left else -0.72, -1.0, -0.18)
	var outward := (bend - axis * bend.dot(axis)).normalized()
	var elbow := shoulder + axis * along + outward * sqrt(maxf(0.0, a * a - along * along))
	var wrist := shoulder + axis * reach
	var upper_rotation := Basis(Quaternion((chest_basis * upper_ray).normalized(), (elbow - shoulder).normalized())) * chest_basis
	var lower_rotation := Basis(Quaternion((chest_basis * lower_ray).normalized(), (wrist - elbow).normalized())) * chest_basis
	skeleton.set_bone_global_pose(upper, Transform3D(upper_rotation, shoulder))
	skeleton.set_bone_global_pose(lower, Transform3D(lower_rotation, elbow))
	skeleton.set_bone_global_pose(hand, Transform3D(lower_rotation, wrist))


func _sleeve_patch(upper: int, lower: int, tint: Color) -> void:
	var marker := _attachment(upper)
	var axis := skeleton.get_bone_rest(lower).origin
	var along := axis.normalized()
	var band := CylinderMesh.new()
	band.top_radius = 0.071
	band.bottom_radius = 0.071
	band.height = 0.066
	band.radial_segments = 12
	var center := axis * 0.39
	var band_node := _mesh(marker, band, center, tint)
	band_node.basis = Basis(Quaternion(Vector3.UP, along))
	var seam := CylinderMesh.new()
	seam.top_radius = 0.072
	seam.bottom_radius = 0.072
	seam.height = 0.009
	seam.radial_segments = 12
	_mesh(marker, seam, center + along * 0.028, TRIM).basis = band_node.basis
	_mesh(marker, seam, center - along * 0.028, TRIM).basis = band_node.basis


func _kit(tint: Color) -> void:
	var back := _attachment(chest)
	_box(back, Vector3(0, 0.036, 0.13), Vector3(0.265, 0.258, 0.084), ARMOR)
	_box(back, Vector3(0, 0.109, 0.178), Vector3(0.18, 0.058, 0.014), TRIM)
	_box(back, Vector3(0, 0.11, 0.188), Vector3(0.121, 0.037, 0.007), tint)
	for column in [-1.0, 0.0, 1.0]:
		_box(back, Vector3(column * 0.071, -0.029, 0.190), Vector3(0.059, 0.104, 0.036), WEBBING)
		_box(back, Vector3(column * 0.071, 0.022, 0.206), Vector3(0.061, 0.019, 0.008), PACK)
	_box(back, Vector3(0, 0.05, -0.185), Vector3(0.255, 0.302, 0.082), TRIM)
	var main := CapsuleMesh.new()
	main.radius = 0.112
	main.height = 0.345
	main.radial_segments = 12
	main.rings = 5
	var sack := _mesh(back, main, Vector3(0, 0.04, -0.222), PACK)
	sack.scale.z = 0.70
	_box(back, Vector3(0, 0.112, -0.282), Vector3(0.195, 0.063, 0.014), tint)
	_box(back, Vector3(0, 0.008, -0.287), Vector3(0.145, 0.032, 0.022), WEBBING)
	for side in [-1.0, 1.0]:
		_box(back, Vector3(side * 0.076, 0.052, -0.28), Vector3(0.023, 0.21, 0.015), TRIM)
		_box(back, Vector3(side * 0.076, 0.04, -0.295), Vector3(0.028, 0.024, 0.012), WEBBING)


	var head := _attachment(skeleton.find_bone("Head"))
	_box(head, Vector3(0, 0.103, 0.085), Vector3(0.145, 0.032, 0.026), TRIM)
	for side in [-1.0, 1.0]:
		_box(head, Vector3(side * 0.075, 0.090, 0.012), Vector3(0.034, 0.071, 0.052), HELMET)
		var leg := _attachment(skeleton.find_bone("LowerLeg_L" if side > 0 else "LowerLeg_R"))
		var pad := CapsuleMesh.new()
		pad.radius = 0.058
		pad.height = 0.141
		pad.radial_segments = 10
		pad.rings = 3
		_mesh(leg, pad, Vector3(0, -0.032, 0.056), TRIM).scale.z = 0.43


func _glove(hand: int, ray: Vector3) -> void:
	var palm := _attachment(hand)
	var direction := ray.normalized()
	var padding := CapsuleMesh.new()
	padding.height = 0.116
	padding.radius = 0.035
	padding.radial_segments = 10
	padding.rings = 3
	var shell := _mesh(palm, padding, direction * 0.043, TRIM)
	shell.basis = Basis(Quaternion(Vector3.UP, direction)).scaled_local(Vector3(1.0, 1.0, 0.72))


func _shade_skin(model: Node3D) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var surface := node as MeshInstance3D
		for index in surface.mesh.get_surface_count():
			var source := surface.mesh.surface_get_material(index) as StandardMaterial3D
			if source == null:
				continue
			if source.resource_name in ["Skin_1", "Face_Soldier"]:
				var softer := source.duplicate() as StandardMaterial3D
				softer.albedo_color *= Color(0.64, 0.57, 0.50)
				surface.set_surface_override_material(index, softer)


func _attachment(index: int) -> BoneAttachment3D:
	var attachment := BoneAttachment3D.new()
	attachment.bone_idx = index
	skeleton.add_child(attachment)
	return attachment


func _box(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_mesh(parent, mesh, at, color)


func _mesh(parent: Node3D, geometry: PrimitiveMesh, at: Vector3, color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.94
	var instance := MeshInstance3D.new()
	instance.mesh = geometry
	instance.material_override = material
	parent.add_child(instance)
	instance.position = at
	return instance
