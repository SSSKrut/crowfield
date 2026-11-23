class_name RemoteSoldier
extends RefCounted
## RemoteSoldier keeps the latest states of another soldier for interpolation.
## evaluate() places it at a moment and leaves the result in position, velocity,
## yaw, pitch, alive, grounded and crouched.

const SAMPLES := 16
## Past the newest state a soldier keeps moving by its velocity for at most
## this long, then stands until a snapshot comes. Far soldiers out of sight
## are updated once or twice a second and live on this.
const MAX_EXTRAPOLATION := Game.TICK_RATE / 2
## A soldier drawn off its new path catches up with this time constant, about
## 95 % within 0.3 s; a jump longer than CATCH_UP_DISTANCE is shown at once,
## like a respawn.
const CATCH_UP_TIME := 0.1
const CATCH_UP_DISTANCE := 3.0

var count := 0
## offset is what is left of a correction: where the soldier was drawn minus
## where its states put it now.
var offset := Vector3.ZERO
## The result of the last evaluate.
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var alive := true
var grounded := false
var crouched := false

var _ticks := PackedInt64Array()
var _positions := PackedVector3Array()
var _velocities := PackedVector3Array()
var _yaws := PackedFloat32Array()
var _pitches := PackedFloat32Array()
var _flags := PackedByteArray()


func _init() -> void:
	_ticks.resize(SAMPLES)
	_positions.resize(SAMPLES)
	_velocities.resize(SAMPLES)
	_yaws.resize(SAMPLES)
	_pitches.resize(SAMPLES)
	_flags.resize(SAMPLES)


## add keeps the samples ordered by tick. A late datagram older than the
## newest sample is dropped; parts of one snapshot replace each other. A
## grounded soldier's downward velocity only keeps it on the floor, so it is
## not used for drawing: it would sink the soldier between snapshots.
func add(tick: int, soldier: Soldier) -> void:
	var at := count % SAMPLES
	if count > 0:
		var newest := (count - 1) % SAMPLES
		if tick == _ticks[newest]:
			at = newest
		elif tick < _ticks[newest]:
			return
	var moving := soldier.velocity
	if soldier.grounded:
		moving.y = 0
	_ticks[at] = tick
	_positions[at] = soldier.position
	_velocities[at] = moving
	_yaws[at] = soldier.yaw
	_pitches[at] = soldier.pitch
	_flags[at] = (SoldierState.ALIVE if soldier.alive else 0) | (SoldierState.GROUNDED if soldier.grounded else 0) \
		| (SoldierState.CROUCHED if soldier.crouched else 0)
	if at == count % SAMPLES:
		count += 1


## keep turns the change a new state made to the drawn position at
## render_tick into an offset that fades, so the soldier does not jump.
func keep(drawn: Vector3, render_tick: float) -> void:
	evaluate(render_tick)
	offset += drawn - position
	if offset.length() > CATCH_UP_DISTANCE:
		offset = Vector3.ZERO
	position = drawn


func smooth(delta: float) -> void:
	offset *= exp(-delta / CATCH_UP_TIME)


## last_alive_velocity is the velocity of the newest state in which the
## soldier was alive, for the momentum it falls with: a dead one stands still.
func last_alive_velocity() -> Vector3:
	for i in range(count - 1, maxi(-1, count - SAMPLES - 1), -1):
		if _flags[i % SAMPLES] & SoldierState.ALIVE != 0:
			return _velocities[i % SAMPLES]
	return _velocities[(count - 1) % SAMPLES]


## evaluate places the soldier at a fractional tick, with what is left of a
## correction: by cubic Hermite interpolation of position and velocity between
## the two states around it, and past the newest state by its velocity for a
## while.
func evaluate(render_tick: float) -> void:
	var oldest := maxi(0, count - SAMPLES)
	var newest := (count - 1) % SAMPLES
	if render_tick >= _ticks[newest]:
		var elapsed := minf(render_tick - _ticks[newest], MAX_EXTRAPOLATION) / Game.TICK_RATE
		_take(newest)
		position = _positions[newest] + _velocities[newest] * elapsed + offset
		return
	for i in range(count - 1, oldest, -1):
		var earlier := (i - 1) % SAMPLES
		if render_tick >= _ticks[earlier]:
			_hermite(earlier, i % SAMPLES, render_tick)
			position += offset
			return
	_take(oldest % SAMPLES)
	position += offset


func _take(sample: int) -> void:
	position = _positions[sample]
	velocity = _velocities[sample]
	yaw = _yaws[sample]
	pitch = _pitches[sample]
	alive = _flags[sample] & SoldierState.ALIVE != 0
	grounded = _flags[sample] & SoldierState.GROUNDED != 0
	crouched = _flags[sample] & SoldierState.CROUCHED != 0


func _hermite(earlier: int, later: int, render_tick: float) -> void:
	var start := float(_ticks[earlier])
	var end := float(_ticks[later])
	var span := (end - start) / Game.TICK_RATE
	var u := (render_tick - start) / (end - start)
	var u2 := u * u
	var u3 := u2 * u
	var p0 := _positions[earlier]
	var v0 := _velocities[earlier]
	var p1 := _positions[later]
	var v1 := _velocities[later]
	position = p0 * (2 * u3 - 3 * u2 + 1) + v0 * ((u3 - 2 * u2 + u) * span) \
		+ p1 * (-2 * u3 + 3 * u2) + v1 * ((u3 - u2) * span)
	velocity = v0.lerp(v1, u)
	yaw = _yaws[earlier] + Game.remainder(_yaws[later] - _yaws[earlier]) * u
	pitch = lerpf(_pitches[earlier], _pitches[later], u)
	# A soldier dies at the tick of its first dead state, where the server left
	# it, not halfway there: far soldiers come a second apart.
	alive = _flags[earlier] & SoldierState.ALIVE != 0
	grounded = _flags[earlier] & SoldierState.GROUNDED != 0
	crouched = _flags[earlier] & SoldierState.CROUCHED != 0
