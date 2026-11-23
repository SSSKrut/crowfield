extends TestCase
## The maps: the valley is the same for both teams and for every build, its
## terrain lies where its collision is, its navigation reaches every place
## worth fighting for, and soldiers appear on the ground of their bases.


func _valley() -> MapScene:
	return MapScene.named("valley")


## Turned half a turn around its centre, the valley is the same: the
## terrain, the bases, the boxes and the places bots go.
func test_valley_is_the_same_for_both_teams() -> void:
	var scene := _valley()
	var terrain := scene.terrain
	var worst := 0.0
	for z in terrain.samples:
		for x in terrain.samples:
			worst = maxf(worst, absf(terrain.sample(x, z) - terrain.sample(terrain.samples - 1 - x, terrain.samples - 1 - z)))
	check(worst <= 0.0015, "heights differ by %.4f m between the halves" % worst)
	var blue := scene.zone_of(Game.Team.BLUE).center
	var red := scene.zone_of(Game.Team.RED).center
	check(blue.is_equal_approx(Vector3(-red.x, blue.y, -red.z)) and absf(blue.y - red.y) < 0.01, "the bases at %s and %s" % [blue, red])
	var lonely := 0
	for box in scene.boxes:
		var mirror := Vector3(-box.transform.origin.x, box.transform.origin.y, -box.transform.origin.z)
		var twin := false
		for other in scene.boxes:
			if other.transform.origin.distance_to(mirror) < 0.01 and other.half_extents.is_equal_approx(box.half_extents):
				twin = true
				break
		if not twin:
			lonely += 1
	check_equal(lonely, 0, "boxes without a twin on the other half")
	check(scene.objectives.size() >= 9, "%d places to fight for" % scene.objectives.size())


## Two builds give the same map, so a client and a server agree on it.
func test_valley_builds_the_same_every_time() -> void:
	var first := _valley()
	var second := _valley()
	check_equal(first.hash_value(), second.hash_value(), "hash of two builds")
	check(first.hash_value() != MapScene.prototype().hash_value(), "the valley and the prototype hash alike")
	check(MapScene.named("nowhere") == null, "a map no one made was built")


## The height the terrain gives is where a ray meets its collision, which bots
## stand on and players walk on, within the few millimetres to which the
## physics engine packs the heights; the steep rim beyond the play area packs
## more coarsely.
func test_terrain_height_is_where_the_collision_is() -> void:
	var scene := _valley()
	var space := PhysicsServer3D.space_create()
	var made := scene.terrain.build_collision(space)
	cleanup(func() -> void:
		MapScene.free_collision(made)
		PhysicsServer3D.free_rid(space))
	var state := PhysicsServer3D.space_get_direct_state(space)
	var random := RandomNumberGenerator.new()
	random.seed = 3
	var worst := 0.0
	for i in 500:
		var x := random.randf_range(-scene.play_area, scene.play_area)
		var z := random.randf_range(-scene.play_area, scene.play_area)
		var hit := state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 50, z), Vector3(x, -50, z)))
		if check(not hit.is_empty(), "no ground at %.1f, %.1f" % [x, z]):
			worst = maxf(worst, absf(hit["position"].y - scene.terrain.height_at(x, z)))
	check(worst < 0.005, "the terrain is %.4f m off its collision" % worst)


## From each base a path on the navigation mesh leads to every place worth
## fighting for and to the other base.
func test_navigation_reaches_every_place() -> void:
	var scene := _valley()
	var navigation := Navigation.create(scene)
	cleanup(func() -> void: navigation.close())
	for team in [Game.Team.BLUE, Game.Team.RED]:
		var from := navigation.closest(scene.zone_of(team).center)
		var places: Array[MapScene.Zone] = scene.objectives.duplicate()
		places.append(scene.zone_of(Game.Team.RED if team == Game.Team.BLUE else Game.Team.BLUE))
		for place in places:
			var to := navigation.closest(place.center)
			var path := navigation.path(from, to)
			check(path.size() >= 2 and path[path.size() - 1].distance_to(to) < 1.0,
				"from the %s base to the %s: %d corners ending at %s" % [Game.team_name(team), place.name, path.size(), path[path.size() - 1] if path.size() > 0 else null])
			check(to.distance_to(place.center) < place.radius + 2, "the %s lies off the mesh, at %s from %s" % [place.name, to, place.center])


## Both base gates let a soldier walk straight through the side of the opening.
func test_valley_base_gate_stays_open() -> void:
	var scene := _valley()
	var space := PhysicsServer3D.space_create()
	var collision := scene.build_collision(space)
	var controller := CharacterController.new(space, MovementTuning.new())
	cleanup(func() -> void:
		controller.close()
		MapScene.free_collision(collision)
		PhysicsServer3D.free_rid(space))
	for side: float in [1.0, -1.0]:
		var x := side * 2.5
		var z := side * 64.0
		var soldier := Soldier.new()
		controller.teleport(soldier, Vector3(x, scene.ground_at(x, z), z))
		var yaw := -0.0125 if side > 0.0 else PI - 0.0125
		for tick in 2 * Game.TICK_RATE:
			controller.step(soldier, InputCommand.create(tick, 1.0, 0.0, yaw, 0.0, 0))
		check(soldier.position.z * side < 56.0, "base gate at z=%.0f stopped a player at %s" % [z, soldier.position])


## Soldiers appear on the ground inside the zone of their team, not in a box.
func test_soldiers_appear_on_the_ground_of_their_base() -> void:
	var settings := ServerSettings.new()
	settings.map = "valley"
	settings.seed = 4
	var server: Server = Server.create(settings, Rules.new())
	cleanup(func() -> void: server.close())
	for team in [Game.Team.BLUE, Game.Team.RED]:
		var zone := server.scene.zone_of(team)
		for i in 40:
			var at := server.spawn_point(team, server.random)
			var flat := Vector2(at.x - zone.center.x, at.z - zone.center.z).length()
			check(flat <= zone.radius + 0.5, "a %s soldier appears %.1f m from its base" % [Game.team_name(team), flat])
			check(absf(at.x) + server.rules.movement.capsule_radius < ValleyMap.GATE_HALF_WIDTH,
				"%s deploys directly behind the gate" % Game.team_name(team))
			var down := server.cast_ray(at + Vector3(0, 0.3, 0), Vector3.DOWN, 1.0, Game.LAYER_STATIC)
			check(down >= 0.25 and down <= 0.35, "a %s soldier appears %.2f m above the ground at %s" % [Game.team_name(team), 0.3 - down, at])


## Both entries carry a walking player into the court from protected staging.
func test_valley_ford_has_two_walkable_covered_entries_per_team() -> void:
	var scene := _valley()
	var flag := scene.flags[1]
	var navigation := Navigation.create(scene)
	var space := PhysicsServer3D.space_create()
	var collision := scene.build_collision(space)
	var controller := CharacterController.new(space, MovementTuning.new())
	cleanup(func() -> void:
		controller.close()
		navigation.close()
		MapScene.free_collision(collision)
		PhysicsServer3D.free_rid(space))
	var state := PhysicsServer3D.space_get_direct_state(space)
	for side: float in [-1.0, 1.0]:
		for lane: float in [-1.0, 1.0]:
			var passage := lane * ValleyMap.FORD_PASSAGE_X
			var staging := Vector3(passage * side, ValleyMap.BANK_LEVEL, 18.0 * side)
			var soldier := Soldier.new()
			controller.teleport(soldier, staging)
			var eye := staging + Vector3.UP * 1.5
			var flag_eye := flag.center + Vector3.UP * 1.5
			check(not state.intersect_ray(PhysicsRayQueryParameters3D.create(eye, flag_eye, Game.LAYER_STATIC)).is_empty(),
				"staging at %s is exposed to the flag" % staging)
			check(not flag.contains_flag_position(staging), "staging at %s can capture the flag" % staging)
			var tick := 0
			for mark: Vector2 in [Vector2(passage, ValleyMap.FORD_GATE_Z), Vector2(passage, 7.25),
					Vector2(lane * 2.1, 7.0), Vector2(lane * 2.1, 1.0)]:
				var target := Vector3(mark.x * side, ValleyMap.FORD_DECK, mark.y * side)
				var path := navigation.path(soldier.position, target)
				var distance := 0.0
				for index in range(1, path.size()):
					distance += path[index - 1].distance_to(path[index])
				check(path.size() >= 2 and path[-1].distance_to(target) < 0.5
					and distance <= soldier.position.distance_to(target) + 1.0,
					"entry from %s to %s makes an unexpected navigation detour: %s" % [staging, target, path])
				for step in 2 * Game.TICK_RATE:
					var offset := target - soldier.position
					if Game.horizontal_length(offset) < 0.18:
						break
					controller.step(soldier, InputCommand.create(tick, 1.0, 0.0, Game.yaw_of(offset), 0.0, 0))
					tick += 1
				check(Game.horizontal_length(soldier.position - target) < 0.25,
					"entry from %s stuck at %s before %s" % [staging, soldier.position, target])
			check(flag.contains_flag_position(soldier.position), "entry from %s ended outside capture" % staging)
	check(not flag.contains_flag_position(Vector3(0, scene.ground_at(0, 0), 0)),
		"the channel below the court can capture the Ford")


func test_valley_benchmark_camera_clears_static_geometry() -> void:
	var scene := _valley()
	var space := PhysicsServer3D.space_create()
	var collision := scene.build_collision(space)
	cleanup(func() -> void:
		MapScene.free_collision(collision)
		PhysicsServer3D.free_rid(space))
	var physics := PhysicsServer3D.space_get_direct_state(space)
	var eye_height := MovementTuning.new().eye_height
	var camera_space := SphereShape3D.new()
	camera_space.radius = 0.3
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = camera_space
	query.collision_mask = Game.LAYER_STATIC
	var from := ClientApp._benchmark_valley_position(scene, eye_height, 0.0)
	var endpoint := ClientApp._benchmark_valley_position(scene, eye_height, 1.0)
	check_near(from.z, 70.0, 0.001, "camera starts behind the camp gate")
	check_near(endpoint.z, 14.0, 0.001, "camera finishes at the ford approach")
	check_near(endpoint.x, ValleyMap.FORD_PASSAGE_X, 0.001, "camera finishes in the east entrance lane")
	const SAMPLES := 240
	for sample in range(1, SAMPLES + 1):
		var to := ClientApp._benchmark_valley_position(scene, eye_height, float(sample) / SAMPLES)
		query.transform = Transform3D(Basis.IDENTITY, from)
		if not check(physics.intersect_shape(query, 1).is_empty(), "camera overlaps static geometry at %s" % from):
			return
		query.motion = to - from
		if not query.motion.is_zero_approx():
			var sweep := physics.cast_motion(query)
			if not check(not sweep.is_empty() and sweep[0] >= 0.999, "camera hits static geometry between %s and %s" % [from, to]):
				return
		from = to
