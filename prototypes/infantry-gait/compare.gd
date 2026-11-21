extends SceneTree

const PATH := "res://export/motion-source/"
const SCREEN := Vector2i(864, 504)
const TARGET := [&"Hips", &"UpperLeg.L", &"LowerLeg.L", &"Foot.L", &"UpperLeg.R", &"LowerLeg.R", &"Foot.R"]
const SOURCE := [&"pelvis", &"thigh_l", &"calf_l", &"foot_l", &"thigh_r", &"calf_r", &"foot_r"]
const FPS := 30.0
const LENGTH := 5.8

var map := MapScene.named("valley")
var view := Camera3D.new()
var body: CharacterView
var rifle: Node3D
var source_skeleton: Skeleton3D
var source_player: AnimationPlayer
var source_ids := PackedInt32Array()
var target_ids := PackedInt32Array()
var rest_inverse: Array[Basis] = []
var measurements := []
var planted: Array[Vector3] = [Vector3.INF, Vector3.INF]
var contact_mode := ""


func _initialize() -> void:
	call_deferred("_compare")


func _compare() -> void:
	var origin := Node3D.new()
	root.add_child(origin)
	var landscape := MapView.new(map)
	origin.add_child(landscape)
	var world := WorldEnvironment.new()
	world.environment = preload("res://assets/sky/valley_environment.tres")
	origin.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.39, 0.89, 0)
	sun.light_color = Color(1.0, 0.91, 0.79)
	sun.light_energy = 0.88
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 45.0
	sun.shadow_enabled = true
	origin.add_child(sun)
	view.fov = 59.0
	view.near = 0.05
	origin.add_child(view)
	view.make_current()
	var asset := CharacterAsset.load_asset()
	body = asset.instantiate()
	origin.add_child(body)
	body.set_tint(Hud.TEAM_COLORS[Game.Team.BLUE])
	body.set_detail(false)
	var factory := ViewModel.new()
	rifle = factory.make_held(WeaponTuning.Kind.ASSAULT_RIFLE)
	origin.add_child(rifle)
	factory.free()

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(PATH + "UAL1_Standard.glb", state) != OK:
		quit(2)
		return
	var imported := doc.generate_scene(state) as Node3D
	imported.hide()
	origin.add_child(imported)
	source_skeleton = imported.find_child("Skeleton3D", true, false) as Skeleton3D
	source_player = imported.find_child("AnimationPlayer", true, false) as AnimationPlayer
	source_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for index in SOURCE.size():
		var from := source_skeleton.find_bone(SOURCE[index])
		var to := body.skeleton.find_bone(TARGET[index])
		assert(from >= 0 and to >= 0)
		source_ids.append(from)
		target_ids.append(to)
		rest_inverse.append(source_skeleton.get_bone_global_rest(from).basis.orthonormalized().inverse())

	var requested := OS.get_cmdline_user_args()
	var slope := "--slope" in requested
	var data_only := "--metrics" in requested
	for candidate in [false, true]:
		var label := "authored" if candidate else "existing"
		var stream: FileAccess
		if not data_only:
			stream = FileAccess.open(PATH + label + ".rgb", FileAccess.WRITE)
		measurements.clear()
		var transit := 0.0
		var phase := 0.0
		planted.assign([Vector3.INF, Vector3.INF])
		contact_mode = ""
		var yaw := -1.57 if slope else 0.0
		var previous_speed := 0.0
		var previous_phase := "idle"
		for frame in roundi(LENGTH * FPS):
			var t := float(frame) / FPS
			var speed := _speed(t)
			transit += (speed + previous_speed) * 0.5 / FPS
			var feet := Vector3(78.0 - transit, 0.0, 51.0) if slope else Vector3(0.0, 0.0, 66.0 - transit)
			feet.y = map.terrain.height_at(feet.x, feet.z)
			body.face(feet, yaw)
			var movement := _movement(speed)
			if movement != "idle":
				phase += speed / FPS / (2.50 if movement == "sprint" else 1.98) if candidate else speed / FPS / (2.86 if movement == "sprint" else 2.38)
			elif previous_phase != movement:
				phase = 0.0
			previous_speed = speed
			previous_phase = movement
			_pose(phase, speed, movement, candidate)
			rifle.transform = ViewModel.held_transform(feet + body.grip_shift(), yaw, 0.0)
			var center := feet + Vector3(0, 0.91, 0)
			var offset := Vector3(-4.1, 1.12, 3.0) if slope else Vector3(4.3, 0.85, -4.0)
			view.look_at_from_position(center + offset, center + Vector3(0, 0.0, -0.15))
			_measure(frame, movement, speed)
			if not data_only:
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				image.resize(SCREEN.x, SCREEN.y)
				image.convert(Image.FORMAT_RGB8)
				stream.store_buffer(image.get_data())
		var log := FileAccess.open(PATH + label + ("-slope" if slope else "") + ".json", FileAccess.WRITE)
		log.store_string(JSON.stringify(measurements))
		if not data_only:
			stream.close()
	origin.queue_free()
	await process_frame
	quit()


func _speed(t: float) -> float:
	if t < 0.55:
		return 0.0
	if t < 1.35:
		return lerpf(0.0, 3.8, smoothstep(0.55, 1.35, t))
	if t < 2.15:
		return lerpf(3.8, 8.0, smoothstep(1.35, 2.15, t))
	if t < 3.75:
		return 8.0
	if t < 5.0:
		return lerpf(8.0, 0.0, smoothstep(3.75, 5.0, t))
	return 0.0


func _movement(speed: float) -> String:
	return "sprint" if speed >= CharacterView.RUN_SPEED else "walk" if speed >= 0.15 else "idle"


func _pose(phase: float, speed: float, movement: String, candidate: bool) -> void:
	var base := CharacterAsset.Clip.RUNNING if movement == "sprint" else CharacterAsset.Clip.WALKING if movement == "walk" else CharacterAsset.Clip.IDLE
	var base_name: StringName = CharacterAsset.CLIPS[base]
	body.animate(1.0 / FPS, speed)
	body.player.advance(1.0 / FPS)
	# Keep the existing upper-body movement. Lower-body offsets below are
	# isolated to the candidate.
	assert(body.player.current_animation == base_name or not candidate)
	body.skeleton.force_update_all_bone_transforms()
	if not candidate:
		return
	if movement != contact_mode:
		planted.assign([Vector3.INF, Vector3.INF])
		contact_mode = movement
	if movement == "idle":
		return
	var clip := "Sprint_Loop" if movement == "sprint" else "Walk_Loop"
	source_player.play(clip, 0.0)
	var src_span := source_player.get_animation(clip).length
	source_player.seek(fposmod(phase, 1.0) * src_span, true)
	source_skeleton.force_update_all_bone_transforms()
	var weight := smoothstep(0.12, 1.5, speed)
	for i in SOURCE.size():
		var source := source_skeleton.get_bone_global_pose(source_ids[i])
		var target := body.skeleton.get_bone_global_pose(target_ids[i])
		var delta := source.basis.orthonormalized() * rest_inverse[i]
		var rest := body.skeleton.get_bone_global_rest(target_ids[i])
		var adapted := delta * rest.basis
		body.skeleton.set_bone_global_pose(target_ids[i], Transform3D(target.basis.slerp(adapted, weight), target.origin))
	# Match the lower sole on the actual terrain. Preserve the mesh and both
	# rifle arms, and only correct vertical origin for the comparison.
	body.skeleton.force_update_all_bone_transforms()
	var clearance := INF
	for side in [3,6]:
		var sole := _sole(side)
		clearance = minf(clearance, sole.y - map.terrain.height_at(sole.x, sole.z))
	var hip := body.skeleton.get_bone_pose_position(target_ids[0])
	hip.y -= clampf(clearance, -0.145, 0.145) * weight
	body.skeleton.set_bone_pose_position(target_ids[0], hip)
	body.skeleton.force_update_all_bone_transforms()
	for leg in 2:
		var stance := 0.25 if movement == "sprint" else 0.48
		var step := fposmod(phase + 0.5 * leg, 1.0)
		if step >= stance:
			planted[leg] = Vector3.INF
			continue
		var foot_index := 3 + leg * 3
		var foot := _sole(foot_index)
		if not planted[leg].is_finite():
			planted[leg] = Vector3(foot.x, map.terrain.height_at(foot.x, foot.z), foot.z)
		var correction := planted[leg] - foot
		var fade := (1.0 - smoothstep(stance - 0.06, stance, step)) * weight
		_lock_leg(foot_index, body.skeleton.global_basis.inverse() * correction * fade)


func _lock_leg(foot_index: int, offset: Vector3) -> void:
	var upper_index := target_ids[foot_index - 2]
	var lower_index := target_ids[foot_index - 1]
	var boot_index := target_ids[foot_index]
	var hip := body.skeleton.get_bone_global_pose(upper_index)
	var knee := body.skeleton.get_bone_global_pose(lower_index)
	var ankle := body.skeleton.get_bone_global_pose(boot_index)
	var upper_vector := knee.origin - hip.origin
	var lower_vector := ankle.origin - knee.origin
	var destination := ankle.origin + offset - hip.origin
	var upper_length := upper_vector.length()
	var lower_length := lower_vector.length()
	var axis := destination.normalized()
	var reach := clampf(destination.length(), 0.01, upper_length + lower_length - 0.0001)
	var along := (upper_length * upper_length - lower_length * lower_length + reach * reach) / (2.0 * reach)
	var bend := upper_vector - axis * upper_vector.dot(axis)
	if bend.length_squared() < 0.00001:
		bend = (Vector3.FORWARD - axis * Vector3.FORWARD.dot(axis))
	var target_knee := axis * along + bend.normalized() * sqrt(maxf(0.0, upper_length * upper_length - along * along))
	var upper_delta := Basis(Quaternion(upper_vector.normalized(), target_knee.normalized()))
	var lower_delta := Basis(Quaternion(lower_vector.normalized(), (axis * reach - target_knee).normalized()))
	body.skeleton.set_bone_global_pose(upper_index, Transform3D(upper_delta * hip.basis, hip.origin))
	body.skeleton.set_bone_global_pose(lower_index, Transform3D(lower_delta * knee.basis, hip.origin + target_knee))
	body.skeleton.set_bone_global_pose(boot_index, Transform3D(ankle.basis, hip.origin + axis * reach))
	body.skeleton.force_update_all_bone_transforms()



func _sole(index: int) -> Vector3:
	var world := body.skeleton.global_transform * body.skeleton.get_bone_global_pose(target_ids[index])
	var at := world * InfantryMesh.SOLE_CENTER
	var y_axis := Vector3(world.basis.x.y, world.basis.y.y, world.basis.z.y) * InfantryMesh.SOLE_RADII
	return at - Vector3.UP * y_axis.length()


func _measure(frame: int, movement: String, speed: float) -> void:
	var soles := []
	for side in [3,6]:
		var p := _sole(side)
		soles.append([p.x, p.y, p.z, p.y - map.terrain.height_at(p.x, p.z)])
	measurements.append([frame, movement, speed, soles])
