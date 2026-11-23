class_name ServerVehicles
extends RefCounted
## ServerVehicles are the vehicles of the server's map: the tanks it places,
## their bodies, drivers getting in and out, the soldiers they run over, the
## damage blasts do to them, and their respawn after destruction.
## The driver alone steers and fires a tank. Bullets spare both. Rockets and
## shells damage the tank, and its destruction kills the driver.

## A tank faster than ROADKILL_SPEED kills whoever it drives into.
const ROADKILL_SPEED := 1.5
## A projectile that bursts this near a tank hit it.
const DIRECT_HIT := 0.4
## A soldier gets out by the side, the back or the front, where there is room.
const EXITS := [Vector3(-3.0, 0, 0), Vector3(3.0, 0, 0), Vector3(0, 0, 4.3), Vector3(0, 0, -4.3),
	Vector3(-3.0, 0, 2.5), Vector3(3.0, 0, 2.5)]

var all: Array[Vehicle] = []
var _server: Server
var _controllers: Array[TankController] = []
var _spawns: Array[MapScene.VehicleSpawn] = []
var _respawn_at := PackedInt32Array()
var _room := PhysicsShapeQueryParameters3D.new()


func _init(server: Server, ground: RID) -> void:
	_server = server
	var capsule := CapsuleShape3D.new()
	capsule.radius = server.rules.movement.capsule_radius
	capsule.height = 2.0 * server.rules.movement.center_height()
	_room.shape = capsule
	_room.collision_mask = Game.LAYER_STATIC | Game.LAYER_VEHICLE
	for spawn in server.scene.vehicle_spawns:
		if all.size() == Vehicle.MAX_VEHICLES:
			break
		var vehicle := Vehicle.new()
		vehicle.id = all.size() + 1
		all.append(vehicle)
		_spawns.append(spawn)
		_controllers.append(TankController.new(server.space, server.scene, ground))
		_respawn_at.append(0)
		_reset(all.size() - 1)


## close frees the bodies.
func close() -> void:
	for controller in _controllers:
		controller.close()
	_controllers.clear()
	_server = null


func get_vehicle(id: int) -> Vehicle:
	return all[id - 1] if id >= 1 and id <= all.size() else null


## _reset puts a new tank of a spawn where it waits.
func _reset(index: int) -> void:
	var vehicle := all[index]
	var spawn := _spawns[index]
	vehicle.kind = spawn.kind
	vehicle.team = spawn.team
	vehicle.yaw = spawn.yaw
	vehicle.position = TankController.hull_transform(_server.scene, spawn.position, spawn.yaw).origin
	vehicle.speed = 0.0
	vehicle.turret = 0.0
	vehicle.gun = 0.0
	vehicle.health = Vehicle.MAX_HEALTH
	vehicle.driver = 0
	vehicle.reload = 0
	vehicle.wrecked = false
	_controllers[index].place(vehicle)


## drive runs a driver's command on the tank and keeps the driver in it. It
## returns the shell the gun fired, or null.
func drive(vehicle: Vehicle, driver: Soldier, command: InputCommand) -> Shot:
	var shot := _controllers[vehicle.id - 1].drive(vehicle, command)
	driver.position = vehicle.position
	driver.velocity = Vector3(sin(vehicle.yaw), 0, -cos(vehicle.yaw)) * vehicle.speed
	driver.yaw = command.yaw_radians()
	driver.pitch = command.pitch_radians()
	driver.grounded = true
	driver.crouched = false
	return shot


## update runs the tanks without a driver for the tick, runs over soldiers,
## and brings back the tanks whose time has come.
func update() -> void:
	for index in all.size():
		var vehicle := all[index]
		if vehicle.wrecked:
			if _server.tick >= _respawn_at[index]:
				_reset(index)
			continue
		if vehicle.driver == 0:
			_controllers[index].drive(vehicle, null)
		_run_over(vehicle)


## enter puts a soldier in the nearest empty tank within reach, if any, and
## returns it.
func enter(soldier: Soldier) -> Vehicle:
	var best: Vehicle = null
	var nearest := Vehicle.REACH
	for vehicle in all:
		if vehicle.wrecked or vehicle.driver != 0:
			continue
		var distance := _distance_to(vehicle, soldier.position + Vector3.UP * 0.9)
		if distance <= nearest:
			nearest = distance
			best = vehicle
	if best != null:
		best.driver = soldier.id
		best.team = soldier.team
		soldier.vehicle = best.id
	return best


## exit takes a soldier out of its tank onto free ground beside it and
## returns where it stands, or Vector3.INF when there is no room anywhere.
func exit(soldier: Soldier) -> Vector3:
	var vehicle := get_vehicle(soldier.vehicle)
	if vehicle == null:
		return Vector3.INF
	var hull := TankController.hull_transform(_server.scene, vehicle.position, vehicle.yaw)
	var state := PhysicsServer3D.space_get_direct_state(_server.space)
	var center := _server.rules.movement.center_height()
	for offset: Vector3 in EXITS:
		var at := hull * offset
		at.y = _server.scene.ground_at(at.x, at.z)
		var down := _server.cast_ray(at + Vector3.UP * 2.0, Vector3.DOWN, 3.0, Game.LAYER_STATIC)
		if down >= 0.0:
			at.y += 2.0 - down
		_room.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * (center + 0.05))
		if state.intersect_shape(_room, 1).is_empty():
			release(soldier)
			return at
	return Vector3.INF


## release takes a soldier out of the tank it drives, whatever became of it.
func release(soldier: Soldier) -> void:
	var vehicle := get_vehicle(soldier.vehicle)
	if vehicle != null and vehicle.driver == soldier.id:
		vehicle.driver = 0
	soldier.vehicle = 0


## blast does a blast's damage to the tanks it reaches: a direct hit by the
## projectile all of it, nearer ones a share. A team's own blasts spare its
## tanks without friendly fire.
func blast(at: Vector3, tuning: WeaponTuning, kind: int, owner: int, team: int, name: String) -> void:
	if not Vehicle.DAMAGE.has(kind):
		return
	for vehicle in all:
		if vehicle.wrecked or (vehicle.team == team and team != Game.Team.NONE and not _server.settings.friendly_fire):
			continue
		var distance := _distance_to(vehicle, at)
		if distance > tuning.blast_radius:
			continue
		var amount := Vehicle.damage_from(kind, tuning, 0.0 if distance <= DIRECT_HIT else distance)
		if amount > 0:
			damage(vehicle, amount, owner, team, kind, name)


## damage takes health from a tank; at none it burns, killing its driver.
func damage(vehicle: Vehicle, amount: int, by: int, team: int, kind: int, name: String = "") -> void:
	vehicle.health = maxi(0, vehicle.health - amount)
	if vehicle.health > 0:
		return
	vehicle.wrecked = true
	vehicle.speed = 0.0
	_respawn_at[vehicle.id - 1] = _server.tick + roundi(Vehicle.RESPAWN_TIME * Game.TICK_RATE)
	var driver := _server.soldiers.get_soldier(vehicle.driver)
	vehicle.driver = 0
	if driver != null and driver.alive:
		var taken := _server.damage(driver, Game.MAX_HEALTH)
		_server.tell_hit(by, team, kind, Vector3.UP, driver, Hitboxes.Zone.NONE, taken[0], taken[1], name)
	var blast := Messages.Blast.new()
	blast.tick = _server.tick
	blast.kind = WeaponTuning.Kind.TANK_CANNON
	blast.position = TankController.hull_transform(_server.scene, vehicle.position, vehicle.yaw) * Vehicle.HULL_CENTER
	_server.send_to_all(blast)


## _run_over kills the soldiers in the way of a moving tank: those whose
## middle is inside its hull, a little grown.
func _run_over(vehicle: Vehicle) -> void:
	if absf(vehicle.speed) < ROADKILL_SPEED:
		return
	var hull := TankController.hull_transform(_server.scene, vehicle.position, vehicle.yaw).affine_inverse()
	var count := _server.grid.near(vehicle.position, Vehicle.HULL_HALF.z + 1.0)
	var ids := _server.grid.ids.duplicate()
	for i in count:
		var victim := _server.soldiers.get_soldier(ids[i])
		if victim == null or not victim.alive or victim.vehicle != 0:
			continue
		if victim.team == vehicle.team and not _server.settings.friendly_fire:
			continue
		var local := hull * (victim.position + Vector3.UP * 0.9)
		if absf(local.x) > Vehicle.HULL_HALF.x + 0.4 or absf(local.z) > Vehicle.HULL_HALF.z + 0.4 or local.y < -0.5 or local.y > 2.6:
			continue
		var taken := _server.damage(victim, Game.MAX_HEALTH)
		var driver := _server.soldiers.get_soldier(vehicle.driver)
		_server.tell_hit(vehicle.driver, vehicle.team, WeaponTuning.Kind.TANK_CANNON,
			Vector3(sin(vehicle.yaw), 0, -cos(vehicle.yaw)), victim, Hitboxes.Zone.NONE, taken[0], taken[1],
			_server.name_of(driver) if driver != null else "")


## _distance_to is how far a point is from a tank's hull or turret.
func _distance_to(vehicle: Vehicle, at: Vector3) -> float:
	var hull := TankController.hull_transform(_server.scene, vehicle.position, vehicle.yaw)
	var local := hull.affine_inverse() * at
	var turret := Transform3D(Basis(Vector3.UP, -vehicle.turret), Vehicle.TURRET_PIVOT + Vehicle.TURRET_CENTER).affine_inverse() * local
	return minf(_box_distance(local - Vehicle.HULL_CENTER, Vehicle.HULL_HALF), _box_distance(turret, Vehicle.TURRET_HALF))


static func _box_distance(local: Vector3, half: Vector3) -> float:
	return (local - local.clamp(-half, half)).length()
