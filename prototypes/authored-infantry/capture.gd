extends SceneTree

const CARBINE := WeaponTuning.Kind.ASSAULT_RIFLE
const LOCATION := Vector3(-40.8, 0, 36.5)

var camera := Camera3D.new()
var weapons := ViewModel.new()
var asset: CharacterAsset
var soldier: CharacterView
var gun: Node3D
var authored := preload("res://prototypes/authored-infantry/authored_soldier.gd").new()
var map := MapScene.named("valley")
var output := ""
var baseline := false
var broad_marks := true

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("The comparison capture requires a graphical renderer.")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Pass an output directory after --.")
		quit(1)
		return
	output = args[0]
	baseline = args.has("baseline")
	broad_marks = not args.has("narrow-marks")
	if DirAccess.make_dir_recursive_absolute(output) != OK:
		push_error("Could not create " + output)
		quit(1)
		return
	root.add_child(MapView.new(map))
	var world := WorldEnvironment.new()
	world.environment = preload("res://assets/sky/valley_environment.tres")
	root.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.56, 0.89, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 0.99
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	root.add_child(sun)
	camera.near = 0.04
	camera.far = 1000.0
	root.add_child(camera)
	camera.make_current()
	root.add_child(weapons)
	asset = CharacterAsset.load_asset()
	soldier = asset.instantiate()
	root.add_child(soldier)
	soldier.set_detail(false)
	soldier.set_foot_terrain(map.terrain)
	gun = weapons.make_held(CARBINE)
	root.add_child(gun)
	if baseline:
		authored.free()
	else:
		root.add_child(authored)
		authored.setup()
		soldier.hide()

	for _index in 6:
		await process_frame
		await RenderingServer.frame_post_draw
	if args.has("distance"):
		await _still("team-blue", false, true, 0.0, 30.0, 0.0, true, Game.Team.BLUE)
		await _still("team-red", false, true, 0.0, 30.0, 0.0, true, Game.Team.RED)
		quit()
		return
	await _still("crouched-aim", true, true, 0.0, 3.6, 0.44, false, Game.Team.BLUE)
	await _still("crouched-side", true, true, 0.0, 3.6, 1.22, false, Game.Team.BLUE)
	await _still("standing-aim", false, true, 0.0, 3.6, 0.44, false, Game.Team.BLUE)
	await _still("sprint", false, false, 6.65, 3.6, 0.94, false, Game.Team.BLUE)

	await _still("red-aim", false, true, 0.0, 3.6, 0.44, false, Game.Team.RED)

	if args.has("motion"):
		_set_tint(Game.Team.BLUE)
		var pixels_out := FileAccess.open(output.path_join("motion.rgb"), FileAccess.WRITE)
		if pixels_out == null:
			quit(1)
			return
		var phase := 0.0
		const STEP := 1.0 / 30.0
		for frame in 168:
			var time := frame * STEP
			var crouch := time >= 3.5 and time < 4.85
			var aim := time < 0.6 or time >= 3.5
			var speed := 0.0
			if time >= 0.6 and time < 1.7:
				speed = 4.25
			elif time >= 1.7 and time < 3.25:
				speed = 6.65
			elif time >= 4.0 and time < 4.85:
				speed = 1.67
			phase += speed * STEP
			var feet := _ground(LOCATION + Vector3(0.0, 0.0, phase))
			soldier.face(feet, PI)
			_camera(feet, 4.25, 0.94 - 0.25 * sin(time), crouch)
			soldier.animate(STEP, speed, crouch, aim)
			soldier.player.advance(STEP)
			gun.transform = soldier.carry(weapons, CARBINE, 0.015)
			_retarget()
			await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			if frame == 0:
				print("motion resolution ", image.get_size())
			image.convert(Image.FORMAT_RGB8)
			pixels_out.store_buffer(image.get_data())
		pixels_out.close()
	print("Captured ", output)
	quit()

func _still(label: String, crouch: bool, aim: bool, speed: float, distance: float, angle: float, rear: bool, team: int) -> void:
	var feet := _ground(Vector3(0, 0, 60) if distance >= 29.0 else LOCATION)
	soldier.face(feet, 0.22 if rear else PI)
	_set_tint(team)
	for _frame in 9:
		soldier.animate(1.0 / 30.0, speed, crouch, aim)
		soldier.player.advance(1.0 / 30.0)
		soldier.player.seek(soldier.player.current_animation_length * (0.28 if speed > 0 else 0.24), true)
		gun.transform = soldier.carry(weapons, CARBINE, 0.033)
		_retarget()
		_camera(feet, distance, angle, crouch)
		await process_frame
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image.save_webp(output.path_join(label + ".webp"), false, 0.94) != OK:
		push_error("Capture failed for " + label)
		quit(1)

func _camera(feet: Vector3, distance: float, angle: float, crouch: bool) -> void:
	var height := 1.02 if crouch else 1.45
	var offset := Vector3(sin(angle) * distance, height, cos(angle) * distance)
	camera.fov = 59.0 if distance >= 29.0 else (34.0 if crouch else 41.0)
	camera.look_at_from_position(feet + offset, feet + Vector3.UP * (0.48 if crouch else 0.91))

func _ground(point: Vector3) -> Vector3:
	return Vector3(point.x, map.terrain.height_at(point.x, point.z), point.z)

func _retarget() -> void:
	if baseline:
		return
	soldier.grounded_feet.place_boots()
	soldier.armed_pose.apply_pose()
	authored.retarget(soldier)


func _set_tint(team: int) -> void:
	var color: Color = SoldierViews.TEAM_COLORS[team]
	if baseline:
		soldier.set_tint(color)
	else:
		authored.set_tint(color, broad_marks)
