extends TestCase
## The tank: its tracks, turret and gun, getting in and out, its shells, its
## armour against bullets and rockets, running soldiers over, burning and
## coming back, and how snapshots carry it.

const FiringRange := preload("res://tests/firing_range.gd")
const RIFLE := 1
const LAUNCHER := 4

## The tank of the range waits beside where the shooter appears, looking
## north along -Z.
const TANK_AT := Vector3(3.6, 0, 8)


## _floor is a floor 60 m across with a wall across it at z = -20, and a blue
## tank beside the blue spawn.
static func _floor() -> MapScene:
	var scene := MapScene.new()
	scene.name = "test"
	scene.play_area = 28.0
	scene.set_zone(Game.Team.BLUE, Vector3(0, 0.2, 8), 0)
	scene.set_zone(Game.Team.RED, Vector3(0, 0.2, -26), 0)
	scene.add_box(Vector3(30, 0.25, 30), Vector3(0, -0.25, 0))
	scene.add_box(Vector3(12, 2.0, 0.5), Vector3(0, 2.0, -20))
	scene.objectives.append(MapScene.Zone.new("floor", Vector3.ZERO, 10))
	scene.vehicle_spawns.append(MapScene.VehicleSpawn.new(Vehicle.Kind.TANK, Game.Team.BLUE, TANK_AT, 0.0))
	return scene


func _range() -> FiringRange:
	var range := FiringRange.new(func(settings: ServerSettings) -> void: settings.scene = _floor())
	cleanup(func() -> void: range.close())
	return range


func _tank(range: FiringRange) -> Vehicle:
	return range.server.vehicles.all[0]


## _drive sends the shooter's commands for some ticks: throttle and steering,
## and the look of the turret.
static func _drive(range: FiringRange, ticks: int, forward: float, right: float, yaw: float = 0.0, pitch: float = 0.0, buttons: int = 0) -> void:
	for i in ticks:
		range.forge(InputCommand.create(0, forward, right, yaw, pitch, buttons))


static func _events(range: FiringRange, type: Variant) -> Array:
	return range.client.events.filter(func(event: Object) -> bool: return is_instance_of(event, type))


# The tank by itself.


func _controller(scene: MapScene) -> Array:
	var space := PhysicsServer3D.space_create()
	var made := scene.build_collision(space)
	var controller := TankController.new(space, scene)
	cleanup(func() -> void:
		controller.close()
		MapScene.free_collision(made)
		PhysicsServer3D.free_rid(space))
	var tank := Vehicle.new()
	tank.id = 1
	tank.driver = 1
	controller.place(tank)
	return [controller, tank]


## Full throttle takes the tank to its top speed and no further; it turns on
## the spot at its rate; and it stops at a wall without passing it.
func test_tank_drives_turns_and_stops_at_a_wall() -> void:
	var made := _controller(_floor())
	var controller: TankController = made[0]
	var tank: Vehicle = made[1]
	for tick in 3 * Game.TICK_RATE:
		controller.drive(tank, InputCommand.create(tick, 1, 0, 0, 0, 0))
	check_near(tank.speed, TankController.MAX_SPEED, 0.01, "speed after three seconds of full throttle")
	check(tank.position.z < -10, "the tank went %s, not north" % tank.position)
	for tick in 4 * Game.TICK_RATE:
		controller.drive(tank, InputCommand.create(tick, 1, 0, 0, 0, 0))
	check(tank.position.z > -20 + 0.5 + Vehicle.HULL_HALF.z - 0.1, "the tank passed into the wall to %s" % tank.position)
	check(absf(tank.speed) < 0.5, "the tank still pushes at %.1f m/s" % tank.speed)
	var stopped := Vehicle.new()
	stopped.driver = 1
	for tick in Game.TICK_RATE:
		controller.drive(stopped, InputCommand.create(tick, 0, 1, 0, 0, 0))
	check_near(stopped.yaw, TankController.TURN_RATE, 0.02, "yaw after a second of turning on the spot")
	check_near(Game.horizontal_length(stopped.position), 0.0, 0.01, "a tank turning on the spot moved")


## The turret turns towards where the driver looks no faster than its drive,
## and the gun rises no higher than it can.
func test_turret_follows_the_aim_at_its_rate() -> void:
	var made := _controller(_floor())
	var controller: TankController = made[0]
	var tank: Vehicle = made[1]
	for tick in Game.TICK_RATE:
		controller.drive(tank, InputCommand.create(tick, 0, 0, PI / 2, 1.0, 0))
	check_near(tank.turret, TankController.TURRET_RATE, 0.02, "turret after a second")
	check_near(tank.gun, TankController.GUN_MAX, 0.01, "gun raised as far as it goes")
	for tick in 2 * Game.TICK_RATE:
		controller.drive(tank, InputCommand.create(tick, 0, 0, PI / 2, -1.0, 0))
	check_near(tank.turret, PI / 2, 0.01, "turret at the aim")
	check_near(tank.gun, TankController.GUN_MIN, 0.01, "gun lowered as far as it goes")
	var gun := controller.gun_transform(tank)
	check((gun.basis * Vector3.FORWARD).dot(Vector3.RIGHT) > 0.98, "the gun points along %s, not east" % (gun.basis * Vector3.FORWARD))


# Getting in and out.


## A soldier by an empty tank gets in with the interact button, drives it,
## and gets out onto the ground beside it with a capsule again.
func test_soldier_drives_and_leaves_a_tank() -> void:
	var range := _range()
	var soldier := range.shooter_soldier()
	var tank := _tank(range)
	check_equal(tank.team, soldier.team, "the team of the range's tank")
	range.forge(InputCommand.create(0, 0, 0, 0, 0, InputCommand.INTERACT))
	if not check_equal(soldier.vehicle, tank.id, "the soldier's vehicle after pressing interact"):
		return
	check_equal(tank.driver, soldier.id, "the tank's driver")
	check(range.shooter.controller == null, "a driver keeps its capsule")
	_drive(range, 2 * Game.TICK_RATE, 1, 0)
	check(tank.position.z < TANK_AT.z - 5, "the tank stayed at %s" % tank.position)
	check(soldier.position.is_equal_approx(tank.position), "the driver at %s, its tank at %s" % [soldier.position, tank.position])
	_drive(range, Game.TICK_RATE, 0, 0)
	range.forge(InputCommand.create(0, 0, 0, 0, 0, InputCommand.INTERACT))
	check_equal(soldier.vehicle, 0, "the soldier's vehicle after getting out")
	check_equal(tank.driver, 0, "the tank's driver after getting out")
	check(range.shooter.controller != null, "a soldier on foot has no capsule")
	var beside := Game.horizontal_length(soldier.position - tank.position)
	check(beside > 2.5 and beside < 5.0, "the soldier got out %.1f m from the tank" % beside)


# The gun and the armour.


## The gun fires a shell at the infantry it is laid on; it bursts there and
## kills; and the gun reloads before it fires again.
func test_tank_gun_kills_infantry_and_reloads() -> void:
	var range := _range()
	var tank := _tank(range)
	range.forge(InputCommand.create(0, 0, 0, 0, 0, InputCommand.INTERACT))
	var enemy := range.target(Game.Team.RED, Vector3(TANK_AT.x, 0, -8))
	range.client.events.clear()
	# Lay the gun on the soldier's middle, then fire and hold the trigger.
	var gun := TankController.gun_of(range.server.scene, tank)
	var to := Vector3(TANK_AT.x, 0.9, -8) - gun.origin
	var pitch := atan2(to.y, Vector2(to.x, to.z).length())
	_drive(range, Game.TICK_RATE / 2, 0, 0, 0, pitch)
	_drive(range, Game.TICK_RATE, 0, 0, 0, pitch, InputCommand.FIRE)
	var launches := _events(range, Messages.Launch)
	check_equal(launches.size(), 1, "shells fired in a second of holding the trigger")
	if launches.size() > 0:
		check_equal(launches[0].kind, WeaponTuning.Kind.TANK_CANNON, "the kind of the shell")
	check(not range.server.soldiers.get_soldier(enemy).alive, "the infantry the gun was laid on lives with %d health" % range.health(enemy))
	check(tank.reload > 0, "the gun is loaded again at once")


## Bullets glance off a tank: it and its driver keep their health.
func test_bullets_do_not_hurt_a_tank_or_its_driver() -> void:
	var range := _range()
	var tank := _tank(range)
	var driver_id := range.target(Game.Team.RED, TANK_AT + Vector3(-3.2, 0, 0))
	var driver := range.server.soldiers.get_soldier(driver_id)
	check(range.server.vehicles.enter(driver) == tank, "the red soldier did not get into the tank")
	driver.position = tank.position
	range.forge(FiringRange.forged(0, RIFLE))
	for i in range.server.rules.weapons.rifle.equip_ticks() + 2:
		range.forge(FiringRange.forged(0, RIFLE))
	for i in 3:
		range.fire(tank.position + Vector3.UP * 1.2)
		range.step(Game.TICK_RATE / 2)
	check_equal(tank.health, Vehicle.MAX_HEALTH, "the tank's health after rifle shots")
	check_equal(driver.health, Game.MAX_HEALTH, "the driver's health after rifle shots")


## A rocket that hits a tank takes a quarter of its health; a tank with none
## burns, killing its driver; and a new one comes back where it waited.
func test_rockets_wreck_a_tank_and_it_comes_back() -> void:
	var range := _range()
	var tank := _tank(range)
	var driver_id := range.target(Game.Team.RED, TANK_AT + Vector3(-3.2, 0, 0))
	var driver := range.server.soldiers.get_soldier(driver_id)
	range.server.vehicles.enter(driver)
	var shooter := range.shooter_soldier()
	shooter.position = Vector3(TANK_AT.x, 0, 30)
	range.shooter.controller.teleport(shooter, shooter.position)
	for i in range.server.rules.weapons.rocket_launcher.equip_ticks() + 2:
		range.forge(FiringRange.forged(0, LAUNCHER))
	var angles := range.aim(tank.position + Vector3.UP * 1.1)
	var command := InputCommand.create(0, 0, 0, angles.x, angles.y, InputCommand.FIRE)
	command.weapon = LAUNCHER
	range.forge(command)
	range.step(Game.TICK_RATE)
	check_equal(tank.health, Vehicle.MAX_HEALTH - Vehicle.DAMAGE[WeaponTuning.Kind.ROCKET_LAUNCHER], "health after a rocket")
	range.client.events.clear()
	range.server.vehicles.damage(tank, tank.health, shooter.id, shooter.team, WeaponTuning.Kind.ROCKET_LAUNCHER)
	range.step(2)
	check(tank.wrecked and tank.driver == 0, "the tank does not burn: wrecked %s, driver %d" % [tank.wrecked, tank.driver])
	check(not driver.alive and driver.vehicle == 0, "the driver of the burning tank lives")
	check_equal(_events(range, Messages.Death).size(), 1, "deaths told")
	check(_events(range, Messages.Blast).size() >= 1, "no blast told for the tank")
	range.step(roundi(Vehicle.RESPAWN_TIME * Game.TICK_RATE))
	check(not tank.wrecked and tank.health == Vehicle.MAX_HEALTH, "no new tank after the wait")
	check(Game.horizontal_length(tank.position - TANK_AT) < 0.01, "the new tank waits at %s" % tank.position)


## A tank driving into an enemy soldier kills it.
func test_a_moving_tank_runs_over_infantry() -> void:
	var range := _range()
	range.forge(InputCommand.create(0, 0, 0, 0, 0, InputCommand.INTERACT))
	var enemy := range.target(Game.Team.RED, Vector3(TANK_AT.x, 0, -4))
	_drive(range, 3 * Game.TICK_RATE, 1, 0)
	check(not range.server.soldiers.get_soldier(enemy).alive, "the soldier in the way of the tank lives")
	check_equal(_events(range, Messages.Death).size(), 1, "deaths told")


# The wire.


## A snapshot carries every vehicle; a decoded one encodes to the same bytes,
## and its state is the tank's, to the steps it is sent in.
func test_snapshots_carry_vehicles() -> void:
	var tank := Vehicle.new()
	tank.id = 2
	tank.team = Game.Team.RED
	tank.position = Vector3(12.5, 3.25, -40.75)
	tank.yaw = -2.1
	tank.turret = 0.7
	tank.gun = 0.1
	tank.speed = -3.3
	tank.health = 640
	tank.driver = 0x1234
	tank.reload = 90
	tank.shots = 300
	var snapshot := Snapshot.new()
	snapshot.vehicles.append(VehicleState.of(tank))
	var bytes := Protocol.encode(snapshot)
	var decoded: Variant = Protocol.decode(bytes)
	if not check(decoded is Snapshot, "the snapshot did not decode: %s" % decoded):
		return
	check_equal(Protocol.encode(decoded), bytes, "bytes of the decoded snapshot")
	var back: Vehicle = decoded.vehicles[0].vehicle()
	check_equal(back.position, tank.position, "position")
	check_near(back.yaw, tank.yaw, 0.001, "yaw")
	check_near(back.turret, tank.turret, 0.001, "turret")
	check_near(back.gun, tank.gun, 0.001, "gun")
	check_near(back.speed, tank.speed, 0.02, "speed")
	check_equal([back.health, back.driver, back.reload, back.shots, back.team], [640, 0x1234, 90, 300 % 256, Game.Team.RED], "the rest")


## The jeep, the truck, the helicopter and the boat wait for their drivers.
## Each model is in metres, stands on the ground at its origin and has its
## moving parts as nodes of their own (tools/build-vehicles.py).
func test_vehicle_models_stand_on_the_ground_with_their_parts() -> void:
	const WHEELS := ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
	for model: Array in [["jeep", WHEELS, 4.1], ["truck", WHEELS, 5.32], ["helicopter", ["Rotor_Main"], 15.3], ["boat", ["Gun_Pivot", "Gun"], 7.14]]:
		var scene := load("res://assets/vehicles/%s.glb" % model[0]) as PackedScene
		if not check(scene != null, "no model of the %s" % model[0]):
			continue
		var node := scene.instantiate() as Node3D
		var lowest := INF
		for found in node.find_children("*", "MeshInstance3D", true, false):
			var part := found as MeshInstance3D
			var placed := part.transform
			var parent := part.get_parent() as Node3D
			while parent != node:
				placed = parent.transform * placed
				parent = parent.get_parent() as Node3D
			var bounds := placed * part.mesh.get_aabb()
			lowest = minf(lowest, bounds.position.y)
			if part.name == "Body":
				check_near(bounds.size.z, model[2], 0.05, "length of the %s" % model[0])
				check_near(bounds.get_center().x, 0.0, 0.05, "the %s off its middle" % model[0])
			if part.name.begins_with("Wheel"):
				check_near(part.position.y, bounds.size.y / 2, 0.02, "axle height of %s of the %s" % [part.name, model[0]])
		check_near(lowest, 0.0, 0.02, "the %s off the ground" % model[0])
		for part_name: String in model[1]:
			check(node.find_child(part_name, true, false) != null, "the %s has no %s" % [model[0], part_name])
		node.free()
