extends TestCase
## The capsule controller: walking, sprinting, jumping, climbing the stairs of
## the prototype map, and repeating itself exactly.


func _world(scene: MapScene = null) -> RID:
	var space := PhysicsServer3D.space_create()
	var made: Array[RID] = []
	if scene == null:
		var floor_scene := MapScene.new()
		floor_scene._box(Vector3(50, 0.25, 50), Vector3(0, -0.25, 0))
		made = floor_scene.build_collision(space)
	else:
		made = scene.build_collision(space)
	cleanup(func() -> void:
		MapScene.free_collision(made)
		PhysicsServer3D.free_rid(space))
	return space


func _soldier(space: RID, at: Vector3) -> Array:
	var controller := CharacterController.new(space, MovementTuning.new())
	cleanup(func() -> void: controller.close())
	var soldier := Soldier.new()
	soldier.alive = true
	controller.teleport(soldier, at)
	return [controller, soldier]


## _settle lets a soldier land after spawning and returns the next tick.
func _settle(controller: CharacterController, soldier: Soldier) -> int:
	for tick in Game.TICK_RATE / 2:
		controller.step(soldier, InputCommand.create(tick, 0, 0, 0, 0, 0))
	check(soldier.grounded, "soldier did not land after spawning: %s" % soldier.position)
	return Game.TICK_RATE / 2


func _check_idle_position(made: Array, label: String, settle: bool) -> void:
	var controller: CharacterController = made[0]
	var soldier: Soldier = made[1]
	var tick := _settle(controller, soldier) if settle else 0
	var start := soldier.position
	for i in 300:
		controller.step(soldier, InputCommand.create(tick + i, 0, 0, 0, 0, 0))
	var displacement := Game.horizontal_length(soldier.position - start)
	check_near(displacement, 0.0, 0.005, label + " horizontal displacement")
	check(soldier.grounded, label + " lost contact with the ground")


func test_idle_stays_in_place_on_a_walkable_incline() -> void:
	var scene := MapScene.new()
	scene.add_box(Vector3(10, 0.25, 10), Vector3.ZERO, Basis(Vector3.BACK, deg_to_rad(20.0)))
	_check_idle_position(_soldier(_world(scene), Vector3(0, 0.45, 0)), "20-degree incline", true)


func test_idle_stays_in_place_at_the_valley_capture() -> void:
	var capture := Vector3(-10.646575, 0.55354017, 42.690987)
	_check_idle_position(_soldier(_world(MapScene.named("valley")), capture), "Valley capture", false)


func test_walks_and_sprints() -> void:
	var made := _soldier(_world(), Vector3(0, 0.2, 0))
	var controller: CharacterController = made[0]
	var soldier: Soldier = made[1]
	var tick := _settle(controller, soldier)
	var tuning := MovementTuning.new()
	for c in [[0, tuning.walk_speed], [InputCommand.SPRINT, tuning.sprint_speed]]:
		var start := soldier.position
		for i in Game.TICK_RATE:
			controller.step(soldier, InputCommand.create(tick, 1, 0, 0, 0, c[0]))
			tick += 1
		# Yaw 0 faces -Z, so one second forward moves the soldier by its speed along -Z.
		check_near(start.z - soldier.position.z, c[1], 0.05, "distance along -Z")
		check_near(soldier.position.x, start.x, 0.01, "drift along X")
		check(soldier.grounded and absf(soldier.position.y) < 0.05, "soldier left the floor: %s" % soldier.position)


func test_jumps() -> void:
	var made := _soldier(_world(), Vector3(0, 0.2, 0))
	var controller: CharacterController = made[0]
	var soldier: Soldier = made[1]
	var tick := _settle(controller, soldier)
	var peak := 0.0
	for i in Game.TICK_RATE * 2:
		controller.step(soldier, InputCommand.create(tick, 0, 0, 0, 0, InputCommand.JUMP if i == 0 else 0))
		peak = maxf(peak, soldier.position.y)
		tick += 1
	var tuning := MovementTuning.new()
	check_near(peak, tuning.jump_speed * tuning.jump_speed / (2 * tuning.gravity), 0.1, "jump peak")
	check(soldier.grounded and absf(soldier.position.y) < 0.05, "soldier did not land: %s" % soldier.position)


func test_is_repeatable() -> void:
	var space := _world(MapScene.prototype())
	var run := func() -> Soldier:
		var made := _soldier(space, Vector3(0, 0.2, 7))
		var controller: CharacterController = made[0]
		var soldier: Soldier = made[1]
		for tick in 240:
			var buttons := InputCommand.SPRINT
			if tick % 50 == 10:
				buttons |= InputCommand.JUMP
			controller.step(soldier, InputCommand.create(tick, 1, float(tick % 7) / 7 - 0.5, tick * 0.02, 0.1, buttons))
		return soldier
	var first: Soldier = run.call()
	var second: Soldier = run.call()
	check(first.position == second.position and first.velocity == second.velocity and first.grounded == second.grounded,
		"same commands gave different soldiers: %s %s" % [first.position, second.position])


## The route of -movement: a run, the ramp with a jump, and the platform.
func test_route_reaches_the_platform() -> void:
	var made := _soldier(_world(MapScene.prototype()), Vector3(0, 0.2, 7))
	var controller: CharacterController = made[0]
	var soldier: Soldier = made[1]
	for tick in 240:
		var elapsed := tick * Game.TICK_DELTA
		var command := InputCommand.create(tick, 0, 0, 0, 0, 0)
		if elapsed < 0.6:
			command = InputCommand.create(tick, 1, 0, PI / 2, 0, InputCommand.SPRINT)
		elif elapsed < 2.2:
			var buttons := InputCommand.SPRINT
			if elapsed >= 1.1 and elapsed < 1.4:
				buttons |= InputCommand.JUMP
			command = InputCommand.create(tick, 1, 0, 0, 0, buttons)
		controller.step(soldier, command)
	check(soldier.grounded and absf(soldier.position.y - 1.5) < 0.02, "the route ends at %s, grounded %s; want on the platform at Y=1.5" % [soldier.position, soldier.grounded])


func test_climbs_the_stairs() -> void:
	var made := _soldier(_world(MapScene.prototype()), Vector3(-5, 0, 6))
	var controller: CharacterController = made[0]
	var soldier: Soldier = made[1]
	var tick := 0
	while soldier.position.z > -1.5 and tick < 300:
		controller.step(soldier, InputCommand.create(tick, 1, 0, 0, 0, 0))
		tick += 1
	check(soldier.grounded and absf(soldier.position.y - 1.5) < 0.02 and tick < 300,
		"the stairs end at %s, grounded %s; want on top at Y=1.5" % [soldier.position, soldier.grounded])
