class_name TankController
extends RefCounted
## TankController drives a tank by its driver's command for one tick: the
## tracks speed it up, slow it and turn it on the spot; the hull lies on the
## terrain and stops against the map's boxes and other vehicles; the turret
## turns and the gun rises towards where the driver looks, each at its own
## rate; and the gun fires when it is loaded. It owns the tank's body on the
## vehicle layer, which stops soldiers, shots and other tanks.
##
## Like CharacterController it keeps no state of its own between ticks:
## everything a step depends on is in the Vehicle.

const MAX_SPEED := 10.0
const REVERSE_SPEED := 4.5
const ACCELERATION := 3.5
const BRAKING := 8.0
const COAST := 2.0
const TURN_RATE := deg_to_rad(40.0)
const TURRET_RATE := deg_to_rad(45.0)
const GUN_RATE := deg_to_rad(24.0)
const GUN_MIN := deg_to_rad(-8.0)
const GUN_MAX := deg_to_rad(20.0)
## The tracks do not climb ground steeper than MAX_SLOPE.
const MAX_SLOPE := deg_to_rad(30.0)
## The tracks touch the ground this far from the middle of the hull.
const TRACK_REACH := 2.7
const TRACK_GAUGE := 1.6
const _MARGIN := 0.01

var scene: MapScene
var _body: RID
var _hull: RID
var _turret: RID
var _params := PhysicsTestMotionParameters3D.new()
var _result := PhysicsTestMotionResult3D.new()
var _min_floor_y := cos(MAX_SLOPE)


## The controller makes the tank's body in space. ground is the body of the
## map's terrain, which the hull rides over instead of colliding with.
func _init(space: RID, map: MapScene, ground: RID = RID()) -> void:
	scene = map
	_hull = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(_hull, Vehicle.HULL_HALF)
	_turret = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(_turret, Vehicle.TURRET_HALF)
	_body = PhysicsServer3D.body_create()
	# Static: Jolt shows a moved static body to queries at once, a kinematic
	# one only after a step of the world, which the server never takes.
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_add_shape(_body, _hull, Transform3D(Basis.IDENTITY, Vehicle.HULL_CENTER))
	PhysicsServer3D.body_add_shape(_body, _turret, Transform3D(Basis.IDENTITY, Vehicle.TURRET_PIVOT + Vehicle.TURRET_CENTER))
	PhysicsServer3D.body_set_collision_layer(_body, Game.LAYER_VEHICLE)
	PhysicsServer3D.body_set_collision_mask(_body, Game.LAYER_STATIC | Game.LAYER_VEHICLE)
	PhysicsServer3D.body_set_space(_body, space)
	_params.margin = _MARGIN
	_params.recovery_as_collision = true
	if ground.is_valid():
		_params.exclude_bodies = [ground]


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		PhysicsServer3D.free_rid(_hull)
		PhysicsServer3D.free_rid(_turret)


## close frees the body. The controller is useless afterwards.
func close() -> void:
	if _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		PhysicsServer3D.free_rid(_hull)
		PhysicsServer3D.free_rid(_turret)
	_body = RID()


## body is the tank's body, which queries may leave out.
func body() -> RID:
	return _body


## place puts the body where the vehicle is, its turret turned.
func place(vehicle: Vehicle) -> void:
	var hull := hull_transform(scene, vehicle.position, vehicle.yaw)
	PhysicsServer3D.body_set_state(_body, PhysicsServer3D.BODY_STATE_TRANSFORM, hull)
	var turret := Transform3D(Basis(Vector3.UP, -vehicle.turret), Vehicle.TURRET_PIVOT) * Transform3D(Basis.IDENTITY, Vehicle.TURRET_CENTER)
	PhysicsServer3D.body_set_shape_transform(_body, 1, turret)


## drive runs a command of the driver for one tick, or lets the tank coast to
## a stop without one. It returns the shell the gun fired, or null.
func drive(vehicle: Vehicle, command: InputCommand) -> Shot:
	var dt := Game.TICK_DELTA
	var throttle := 0.0
	var steer := 0.0
	if command != null and vehicle.driver != 0 and not vehicle.wrecked:
		throttle = command.forward_axis()
		steer = command.right_axis()
	var target := throttle * (MAX_SPEED if throttle >= 0.0 else REVERSE_SPEED)
	var rate := COAST
	if throttle != 0.0:
		rate = ACCELERATION if target * vehicle.speed >= 0.0 and absf(target) > absf(vehicle.speed) else BRAKING
	vehicle.speed = move_toward(vehicle.speed, target, rate * dt)
	_turn(vehicle, steer * TURN_RATE * (1.0 - 0.35 * absf(vehicle.speed) / MAX_SPEED) * dt)
	_move(vehicle)
	var shot: Shot = null
	if vehicle.reload > 0:
		vehicle.reload -= 1
	if command != null and vehicle.driver != 0 and not vehicle.wrecked:
		_aim(vehicle, command)
		if command.has(InputCommand.FIRE) and vehicle.reload == 0:
			vehicle.reload = Vehicle.reload_ticks()
			vehicle.shots = (vehicle.shots + 1) % 256
			shot = Shot.new()
			shot.weapon = WeaponTuning.Kind.TANK_CANNON
			var gun := gun_transform(vehicle)
			shot.origin = gun * Vector3(0, 0, -Vehicle.MUZZLE)
			shot.direction = (gun.basis * Vector3.FORWARD).normalized()
	place(vehicle)
	return shot


## _turn turns the hull on the spot unless that would push it into
## something.
func _turn(vehicle: Vehicle, angle: float) -> void:
	if angle == 0.0:
		return
	var turned := wrapf(vehicle.yaw + angle, -PI, PI)
	_params.from = hull_transform(scene, vehicle.position, turned)
	_params.motion = Vector3.ZERO
	if not PhysicsServer3D.body_test_motion(_body, _params, _result):
		vehicle.yaw = turned


## _move moves the hull along the ground at its speed, sliding along what it
## meets and stopping at it and at ground too steep for the tracks.
func _move(vehicle: Vehicle) -> void:
	if vehicle.speed == 0.0:
		return
	var forward := Vector3(sin(vehicle.yaw), 0, -cos(vehicle.yaw))
	var motion := forward * vehicle.speed * Game.TICK_DELTA
	var from := hull_transform(scene, vehicle.position, vehicle.yaw)
	_params.from = from
	_params.motion = motion
	if PhysicsServer3D.body_test_motion(_body, _params, _result):
		var travel := _result.get_travel()
		var rest := _result.get_remainder().slide(_result.get_collision_normal())
		rest.y = 0
		motion = Vector3(travel.x, 0, travel.z)
		_params.from = Transform3D(from.basis, from.origin + motion)
		_params.motion = rest
		if PhysicsServer3D.body_test_motion(_body, _params, _result):
			rest = _result.get_travel()
		motion += Vector3(rest.x, 0, rest.z)
		vehicle.speed *= 0.5 if motion.length() > 0.001 else 0.0
	var to := vehicle.position + motion
	var up := ground_basis(scene, to, vehicle.yaw).y
	var climbing := scene.ground_at(to.x, to.z) > scene.ground_at(vehicle.position.x, vehicle.position.z)
	if up.y < _min_floor_y and climbing:
		vehicle.speed = 0.0
		return
	vehicle.position = Vector3(to.x, _support(scene, to, vehicle.yaw), to.z)


## ground_basis is how the hull lies on the ground at a point, looking along
## yaw: its Y the normal of the plane through where its tracks touch.
static func ground_basis(map: MapScene, at: Vector3, yaw: float) -> Basis:
	var forward := Vector3(sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, sin(yaw))
	var ahead := _height(map, at + forward * TRACK_REACH)
	var behind := _height(map, at - forward * TRACK_REACH)
	var left := _height(map, at - right * TRACK_GAUGE)
	var on_right := _height(map, at + right * TRACK_GAUGE)
	var along := forward * (2.0 * TRACK_REACH) + Vector3.UP * (ahead - behind)
	var across := right * (2.0 * TRACK_GAUGE) + Vector3.UP * (on_right - left)
	var up := across.cross(along).normalized()
	if up.y < 0:
		up = -up
	var back := -(along - up * along.dot(up)).normalized()
	return Basis(up.cross(back), up, back)


## hull_transform places the hull at a point of the ground, looking along yaw.
static func hull_transform(map: MapScene, at: Vector3, yaw: float) -> Transform3D:
	return Transform3D(ground_basis(map, at, yaw), Vector3(at.x, _support(map, at, yaw), at.z))


static func turret_transform(map: MapScene, vehicle: Vehicle) -> Transform3D:
	return hull_transform(map, vehicle.position, vehicle.yaw) * Transform3D(Basis(Vector3.UP, -vehicle.turret), Vehicle.TURRET_PIVOT)


func gun_transform(vehicle: Vehicle) -> Transform3D:
	return gun_of(scene, vehicle)


## gun_of is the gun's pivot, looking along the bore.
static func gun_of(map: MapScene, vehicle: Vehicle) -> Transform3D:
	return turret_transform(map, vehicle) * Transform3D(Basis(Vector3.RIGHT, vehicle.gun), Vehicle.GUN_PIVOT)


## _aim turns the turret towards the yaw the driver looks along and raises
## the gun towards the pitch, each no faster than its drive allows.
func _aim(vehicle: Vehicle, command: InputCommand) -> void:
	var dt := Game.TICK_DELTA
	var wanted := wrapf(command.yaw_radians() - vehicle.yaw, -PI, PI)
	var turn := wrapf(wanted - vehicle.turret, -PI, PI)
	vehicle.turret = wrapf(vehicle.turret + clampf(turn, -TURRET_RATE * dt, TURRET_RATE * dt), -PI, PI)
	vehicle.gun = move_toward(vehicle.gun, clampf(command.pitch_radians(), GUN_MIN, GUN_MAX), GUN_RATE * dt)


## _support is how high the hull rides at a point: on the mean of where its
## tracks touch.
static func _support(map: MapScene, at: Vector3, yaw: float) -> float:
	var forward := Vector3(sin(yaw), 0, -cos(yaw))
	var right := Vector3(cos(yaw), 0, sin(yaw))
	var sum := 0.0
	for point: Vector3 in [forward * TRACK_REACH, -forward * TRACK_REACH, right * TRACK_GAUGE, -right * TRACK_GAUGE]:
		sum += _height(map, at + point)
	return maxf(sum / 4.0, _height(map, at))


static func _height(map: MapScene, at: Vector3) -> float:
	return map.ground_at(at.x, at.z)
