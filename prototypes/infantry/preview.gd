extends SceneTree

const CANDIDATE := preload("res://prototypes/infantry/rigged_infantry.gd")
const OUT := "res://export/infantry-proof/"
const FRAME_WIDTH := 960
const FRAME_HEIGHT := 540
var view := Camera3D.new()
var scene := MapScene.named("valley")
var old: Array[CharacterView] = []
var new: Array[Node3D] = []
var weapons := ViewModel.new()
var old_rifles: Array[Node3D] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var landscape := MapView.new(scene)
	root.add_child(landscape)
	var world := WorldEnvironment.new()
	world.environment = preload("res://assets/sky/valley_environment.tres")
	root.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.39, 0.89, 0)
	sun.light_color = Color(1.0, 0.91, 0.79)
	sun.light_energy = 0.88
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 45.0
	sun.shadow_enabled = true
	root.add_child(sun)
	view.fov = 59.0
	view.near = 0.05
	view.far = 1000.0
	root.add_child(view)
	view.make_current()
	var asset := CharacterAsset.load_asset()
	for team in [Game.Team.BLUE, Game.Team.RED]:
		var shown := asset.instantiate()
		root.add_child(shown)
		shown.set_tint(Hud.TEAM_COLORS[team])
		shown.set_detail(false)
		old.append(shown)
		var original_weapon := weapons.make_held(WeaponTuning.Kind.ASSAULT_RIFLE)
		root.add_child(original_weapon)
		old_rifles.append(original_weapon)
		var trial := CANDIDATE.new()
		root.add_child(trial)
		trial.setup(weapons, team)
		new.append(trial)
	for index in 10:
		await RenderingServer.frame_post_draw
	for use_candidate in [false,true]:
		var label := "candidate" if use_candidate else "current"
		_place(use_candidate, 3.5, 0.24, false, 0.0, false)
		await _save(label + "-stand-3")
		_place(use_candidate, 8.0, 0.24, false, 0.0, false)
		await _save(label + "-stand-8")
		_place(use_candidate, 8.0, 0.29, true, 0.0, false)
		await _save(label + "-sprint-8")
		_place(use_candidate, 30.0, 0.29, true, 0.0, true)
		await _save(label + "-sprint-30")
		if use_candidate:
			var stream := FileAccess.open(OUT + "candidate-motion.rgb", FileAccess.WRITE)
			for frame in 60:
				var at := float(frame) / 30.0
				_place(true, 8.0, at * 1.3, true, at * 4.1, false)
				await RenderingServer.frame_post_draw
				var pixels := root.get_texture().get_image()
				pixels.resize(FRAME_WIDTH, FRAME_HEIGHT)
				pixels.convert(Image.FORMAT_RGB8)
				stream.store_buffer(pixels.get_data())
			stream.close()
	weapons.free()
	print("Saved matched Valley rig captures and 60 animated frames")
	quit()


func _place(candidate: bool, distance: float, seconds: float, running: bool, travel: float, rear: bool) -> void:
	var from := Vector3(0.0, 0.0, 65.0 - travel)
	from.y = scene.terrain.height_at(from.x, from.z) + 1.63
	view.look_at_from_position(from, from + Vector3(0.0, -0.033, -1.0))
	var spread := 0.11 * distance
	for index in 2:
		var position := Vector3(spread * (-1.0 if index == 0 else 1.0), 0.0, from.z - distance)
		position.y = scene.terrain.height_at(position.x, position.z)
		var yaw := 0.30 if rear else PI + (0.56 if index == 0 else -0.65)
		old[index].visible = not candidate
		old_rifles[index].visible = not candidate
		new[index].visible = candidate
		if candidate:
			new[index].transform = Transform3D(Basis(Vector3.UP, PI - yaw), position)
			new[index].pose(seconds + index * 0.13, running)
		else:
			var clip := CharacterAsset.Clip.RUNNING if running else CharacterAsset.Clip.IDLE
			old[index].face(position, yaw)
			old[index].animate(0.016, 6.65 if running else 0.0)
			var name: StringName = CharacterAsset.CLIPS[clip]
			old[index].player.play(name, 0.0)
			old[index].player.seek(fposmod(seconds + index * 0.13, old[index].asset.periods[clip]), true)
			old_rifles[index].transform = ViewModel.held_transform(position + old[index].grip_shift(), yaw, 0.0)


func _save(label: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(OUT + label + ".png")
