class_name CharacterController
extends RefCounted
## CharacterController moves a human-controlled soldier with a physics capsule
## through a static world: it slides along walls, walks up steps lower than
## step_height and down them without leaving the ground, and does not climb
## slopes steeper than the tuning allows.
##
## The controller keeps no state of its own between ticks: everything a step
## depends on is in the soldier, the position, velocity and whether it stands
## on the ground. So a replay that restores the soldier of a tick repeats the
## following ticks exactly, which the client's prediction relies on.

const _MAX_SLIDES := 4
const _MARGIN := 0.002
## _GROUND_PROBE is how far below the capsule the ground still counts.
const _GROUND_PROBE := 0.02
## A step is tried this far forward at least, so that walking slowly into a
## stair still climbs it.
const _MIN_STEP_FORWARD := 0.05

var tuning: MovementTuning
var _body: RID
var _shape: RID
var _params := PhysicsTestMotionParameters3D.new()
var _result := PhysicsTestMotionResult3D.new()
var _min_floor_y: float


func _init(space: RID, movement: MovementTuning, mask: int = Game.LAYER_STATIC | Game.LAYER_VEHICLE | Game.LAYER_DYNAMIC) -> void:
	tuning = movement
	_min_floor_y = cos(deg_to_rad(movement.max_slope_degrees))
	_shape = PhysicsServer3D.capsule_shape_create()
	PhysicsServer3D.shape_set_data(_shape, {"radius": movement.capsule_radius, "height": 2.0 * movement.center_height()})
	_body = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_body, PhysicsServer3D.BODY_MODE_KINEMATIC)
	PhysicsServer3D.body_add_shape(_body, _shape)
	PhysicsServer3D.body_set_collision_layer(_body, Game.LAYER_CHARACTER)
	PhysicsServer3D.body_set_collision_mask(_body, mask)
	PhysicsServer3D.body_set_space(_body, space)
	_params.margin = _MARGIN
	_params.recovery_as_collision = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		PhysicsServer3D.free_rid(_shape)


## close frees the capsule. The controller is useless afterwards.
func close() -> void:
	if _body.is_valid():
		PhysicsServer3D.free_rid(_body)
		PhysicsServer3D.free_rid(_shape)
	_body = RID()


## step moves the soldier by a command for one tick.
func step(soldier: Soldier, command: InputCommand) -> void:
	soldier.yaw = command.yaw_radians()
	soldier.pitch = command.pitch_radians()
	var speed := tuning.sprint_speed if command.has(InputCommand.SPRINT) else tuning.walk_speed
	var forward_axis := command.forward_axis()
	var right_axis := command.right_axis()
	var forward := Vector3(sin(soldier.yaw), 0, -cos(soldier.yaw))
	var right := Vector3(cos(soldier.yaw), 0, sin(soldier.yaw))
	var horizontal := forward * forward_axis + right * right_axis
	var length_squared := horizontal.x * horizontal.x + horizontal.z * horizontal.z
	if length_squared > 1:
		horizontal *= 1.0 / sqrt(length_squared)
	var velocity := soldier.velocity
	velocity.x = horizontal.x * speed
	velocity.z = horizontal.z * speed
	if soldier.grounded and velocity.y <= 0:
		velocity.y = -tuning.ground_stick_speed
		if command.has(InputCommand.JUMP):
			velocity.y = tuning.jump_speed
	else:
		velocity.y -= tuning.gravity * Game.TICK_DELTA
	_move(soldier, velocity)


## run_command runs a human soldier's command for one tick: it moves the
## soldier, then works its weapons from where the move left it. The server and
## the client's prediction both run it, so they agree on both; match_seed
## makes the spread of shots repeatable.
func run_command(weapons: WeaponSet, soldier: Soldier, command: InputCommand, match_seed: int) -> WeaponStep:
	step(soldier, command)
	var result := soldier.arsenal.step(weapons, command, speed_share(soldier), not soldier.grounded,
		Arsenal.shot_seed(match_seed, soldier.id, command.tick), soldier.health < Game.MAX_HEALTH)
	if result.has(Arsenal.EVENT_FIRED):
		result.shot.origin = soldier.position + Vector3(0, tuning.eye_height, 0)
	return result


## speed_share is the soldier's speed along the ground as a share of the
## sprint speed, for the spread of its weapon.
func speed_share(soldier: Soldier) -> float:
	return Game.horizontal_length(soldier.velocity) / tuning.sprint_speed


## teleport places the soldier at rest, for example on spawn.
func teleport(soldier: Soldier, feet: Vector3) -> void:
	soldier.position = feet
	soldier.velocity = Vector3.ZERO
	place(soldier)


## place finds whether the soldier at its position stands on the ground, when
## no earlier tick tells: after a teleport or a correction from afar.
func place(soldier: Soldier) -> void:
	var center := soldier.position + Vector3(0, tuning.center_height(), 0)
	soldier.grounded = _test(center, Vector3(0, -_GROUND_PROBE, 0)) and _is_floor(_result.get_collision_normal())


func _move(soldier: Soldier, velocity: Vector3) -> void:
	var center := soldier.position + Vector3(0, tuning.center_height(), 0)
	var was_grounded := soldier.grounded
	var grounded := false
	var moving := velocity.x != 0 or velocity.z != 0
	var motion := velocity * Game.TICK_DELTA
	for i in _MAX_SLIDES:
		if motion.length_squared() < 1e-12:
			break
		if not _test(center, motion):
			center += motion
			break
		var normal := _result.get_collision_normal()
		var rest := _result.get_remainder()
		var travel := _result.get_travel()
		if _is_floor(normal):
			if motion.y <= 0:
				grounded = true
				if not moving:
					# Both recovery and the slide can convert ground stick
					# into sideways motion. At rest, settle vertically.
					center.y += travel.y
					break
			center += travel
			motion = rest.slide(normal)
			continue
		center += travel
		if (was_grounded or grounded) and velocity.y <= 0:
			var stepped := _step_up(center, rest, normal)
			if stepped.size() > 0:
				center = stepped[0]
				motion = stepped[1]
				grounded = true
				continue
		var wall := normal
		if was_grounded and normal.y > 0:
			# A slope too steep to walk is a wall to a soldier on the ground.
			wall = Vector3(normal.x, 0, normal.z)
			wall = wall.normalized() if wall.length_squared() > 1e-8 else normal
		if normal.y < -0.5 and velocity.y > 0:
			# A ceiling stops a jump.
			velocity.y = 0
		motion = rest.slide(wall)
	# Going down a slope or a step, a soldier on the ground stays on it.
	if was_grounded and not grounded and velocity.y <= 0:
		if _test(center, Vector3(0, -tuning.step_height, 0)) and _is_floor(_result.get_collision_normal()):
			var travel := _result.get_travel()
			center += travel if moving else Vector3(0, travel.y, 0)
			grounded = true
	if not grounded and velocity.y <= 0:
		grounded = _test(center, Vector3(0, -_GROUND_PROBE, 0)) and _is_floor(_result.get_collision_normal())
	soldier.position = center - Vector3(0, tuning.center_height(), 0)
	soldier.velocity = velocity
	soldier.grounded = grounded


## _step_up tries to climb a step that blocks the motion: up by the step
## height, forward, and down onto the step. It returns the new center and the
## motion left, or [] when no walkable step is there.
func _step_up(center: Vector3, motion: Vector3, normal: Vector3) -> Array:
	var forward := Vector3(motion.x, 0, motion.z)
	var into := Vector3(normal.x, 0, normal.z)
	if into.length_squared() < 1e-8 or forward.dot(into) >= 0:
		return []
	if forward.length() < _MIN_STEP_FORWARD:
		forward = -into.normalized() * _MIN_STEP_FORWARD
	var up := Vector3(0, tuning.step_height, 0)
	if _test(center, up):
		up = _result.get_travel()
	var raised := center + up
	if _test(raised, forward):
		if _result.get_travel().length() < 1e-4:
			return []
		forward = _result.get_travel()
	var ahead := raised + forward
	if not _test(ahead, -up - Vector3(0, _GROUND_PROBE, 0)) or not _is_floor(_result.get_collision_normal()):
		return []
	var landed := ahead + _result.get_travel()
	if landed.y - center.y < 1e-3:
		return []
	var left := Vector3(motion.x, 0, motion.z) - forward
	if left.dot(forward) < 0:
		left = Vector3.ZERO
	return [landed, left]


func _test(center: Vector3, motion: Vector3) -> bool:
	_params.from = Transform3D(Basis(), center)
	_params.motion = motion
	return PhysicsServer3D.body_test_motion(_body, _params, _result)


func _is_floor(normal: Vector3) -> bool:
	return normal.y >= _min_floor_y
