class_name VehicleState
extends RefCounted
## VehicleState is a vehicle as a snapshot carries it. It is quantized, so a
## decoded state encodes to the same bytes. Every snapshot carries every
## vehicle: a map has only a few.

const BITS := 4 + 2 + 2 + 1 + 3 * 32 + 16 + 16 + 10 + 10 + 11 + 16 + 8 + 8
const _ANGLE_STEPS := 65536
const _GUN_STEPS := 1023
const _SPEED_STEP := 1.0 / 32.0
const _SPEED_BIAS := 512
const _MAX_RELOAD := 255

var id := 0
var kind := 0
var team := 0
var wrecked := false
var position := Vector3.ZERO
## yaw and turret are in steps of a turn, gun in steps of the gun's travel and
## speed in steps of _SPEED_STEP m/s above -_SPEED_BIAS of them.
var yaw := 0
var turret := 0
var gun := 0
var speed := _SPEED_BIAS
var health := 0
var driver := 0
var shots := 0
var reload := 0


static func of(vehicle: Vehicle) -> VehicleState:
	var state := VehicleState.new()
	state.id = vehicle.id
	state.kind = vehicle.kind
	state.team = vehicle.team
	state.wrecked = vehicle.wrecked
	state.position = vehicle.position
	state.yaw = _angle(vehicle.yaw)
	state.turret = _angle(vehicle.turret)
	var travel := TankController.GUN_MAX - TankController.GUN_MIN
	state.gun = clampi(roundi((vehicle.gun - TankController.GUN_MIN) / travel * _GUN_STEPS), 0, _GUN_STEPS)
	state.speed = clampi(roundi(vehicle.speed / _SPEED_STEP) + _SPEED_BIAS, 0, 2 * _SPEED_BIAS - 1)
	state.health = clampi(vehicle.health, 0, Vehicle.MAX_HEALTH)
	state.driver = vehicle.driver
	state.shots = vehicle.shots & 0xFF
	state.reload = mini(vehicle.reload, _MAX_RELOAD)
	return state


static func _angle(radians: float) -> int:
	return posmod(roundi(radians / TAU * _ANGLE_STEPS), _ANGLE_STEPS)


## vehicle is the state as a Vehicle, for the client to draw.
func vehicle() -> Vehicle:
	var made := Vehicle.new()
	made.id = id
	made.kind = kind
	made.team = team
	made.wrecked = wrecked
	made.position = position
	made.yaw = wrapf(float(yaw) / _ANGLE_STEPS * TAU, -PI, PI)
	made.turret = wrapf(float(turret) / _ANGLE_STEPS * TAU, -PI, PI)
	made.gun = TankController.GUN_MIN + float(gun) / _GUN_STEPS * (TankController.GUN_MAX - TankController.GUN_MIN)
	made.speed = (speed - _SPEED_BIAS) * _SPEED_STEP
	made.health = health
	made.driver = driver
	made.shots = shots
	made.reload = reload
	return made


func validate() -> String:
	if id < 1 or id > Vehicle.MAX_VEHICLES:
		return "vehicle number out of range"
	if kind != Vehicle.Kind.TANK:
		return "unknown vehicle kind"
	if team < Game.Team.NONE or team > Game.Team.RED:
		return "vehicle team out of range"
	if not position.is_finite():
		return BitReader.INVALID_FLOAT
	if health > Vehicle.MAX_HEALTH or (wrecked and (health != 0 or driver != 0)):
		return "vehicle health out of range"
	if gun > _GUN_STEPS:
		return "gun elevation out of range"
	return ""


func write(w: BitWriter) -> void:
	w.write_bits(id, 4)
	w.write_bits(kind, 2)
	w.write_bits(team, Protocol.TEAM_BITS)
	w.write_bool(wrecked)
	for value in [position.x, position.y, position.z]:
		w.write_float32(value)
	w.write_bits(yaw, 16)
	w.write_bits(turret, 16)
	w.write_bits(gun, 10)
	w.write_bits(speed, 10)
	w.write_bits(health, 11)
	w.write_bits(driver, 16)
	w.write_bits(shots, 8)
	w.write_bits(reload, 8)


func read(r: BitReader) -> void:
	id = r.read_bits(4)
	kind = r.read_bits(2)
	team = r.read_bits(Protocol.TEAM_BITS)
	wrecked = r.read_bool()
	position = Vector3(r.read_float32(), r.read_float32(), r.read_float32())
	yaw = r.read_bits(16)
	turret = r.read_bits(16)
	gun = r.read_bits(10)
	speed = r.read_bits(10)
	health = r.read_bits(11)
	driver = r.read_bits(16)
	shots = r.read_bits(8)
	reload = r.read_bits(8)
	if r.error == "":
		var error := validate()
		if error != "":
			r.fail(error)
