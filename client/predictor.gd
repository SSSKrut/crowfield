class_name Predictor
extends RefCounted
## Predictor moves the player's own soldier and works its weapons as soon as a
## command is made, with the code of the server, and corrects them when a
## snapshot disagrees (ARCHITECTURE.md, 6.5).

## HISTORY covers two seconds, more than any round trip the game is played
## with. A confirmation older than that cannot be replayed and is snapped to.
const HISTORY := 2 * Game.TICK_RATE
## The server runs the same code, so its state matches the prediction exactly
## unless a command came late; these limits only absorb rounding.
const ACCEPTED_POSITION_ERROR := 1e-4
const ACCEPTED_VELOCITY_ERROR := 1e-3
## A correction longer than this is a teleport, like a respawn: it is shown at
## once and the capsule finds its ground anew.
const TELEPORT_DISTANCE := 2.0
## The drawn soldier catches up with a correction with this time constant,
## about 95 % within 150 ms.
const SMOOTHING_TIME := 0.05

var controller: CharacterController
var weapons: WeaponSet
## match_seed is the seed of the match, which the spread of shots comes from.
var match_seed := 0
var soldier := Soldier.new()
var started := false
var last := 0
## corrections counts the corrections, weapon_corrections those of them where
## only the weapons disagreed.
var corrections := 0
var weapon_corrections := 0
var last_error := 0.0

var _ticks: Array[PredictedTick] = []
var _previous := Vector3.ZERO
var _offset := Vector3.ZERO


## The client predicts in a space with the static map; it never pushes props,
## which are its own decoration.
func _init(space: RID, rules: Rules) -> void:
	controller = CharacterController.new(space, rules.movement, Game.LAYER_STATIC | Game.LAYER_VEHICLE)
	weapons = rules.weapons
	_ticks.resize(HISTORY)
	for i in HISTORY:
		_ticks[i] = PredictedTick.new()


func close() -> void:
	controller.close()


## join starts a new session with the match seed it got: the next confirmed
## state starts the prediction again. The ticks of the last session are
## forgotten: the new one may reuse their numbers, and the server never saw
## their commands.
func join(seed: int) -> void:
	started = false
	_offset = Vector3.ZERO
	match_seed = seed
	for predicted in _ticks:
		predicted.tick = -1
		predicted.stepped = false


## predict records the command of a tick and, once the soldier exists, applies
## it. Ticks skipped by a clock jump get the repeated command the server uses.
## It returns what the weapons did at the tick of the command, for the effects.
func predict(command: InputCommand) -> WeaponStep:
	if started and command.tick <= last:
		# The clock jumped back; start again from the next confirmed state.
		started = false
	if started:
		var previous := _ticks[last % HISTORY].command
		var at := last + 1
		while at != command.tick and command.tick - at < HISTORY:
			_previous = soldier.position
			_record(previous.repeated(at), true)
			at += 1
		_previous = soldier.position
	return _record(command, started)


func _record(command: InputCommand, step: bool) -> WeaponStep:
	var slot := _ticks[command.tick % HISTORY]
	slot.tick = command.tick
	slot.command = command
	slot.stepped = false
	last = command.tick
	if not step:
		return WeaponStep.new()
	return _step(slot)


func _step(slot: PredictedTick) -> WeaponStep:
	var result := controller.run_command(weapons, soldier, slot.command, match_seed)
	slot.soldier = soldier.copy()
	slot.stepped = true
	return result


## reconcile compares the server's state of a tick with the prediction for
## that tick. On a mismatch it restores the server's state and replays the
## newer commands; the drawn soldier keeps its place and catches up smoothly.
func reconcile(server: PlayerState) -> void:
	if not server.processed or server.soldier == 0:
		return
	if server.health == 0:
		# The dead are not predicted: the soldier lies where the server says,
		# and a new one starts the prediction again.
		started = false
		_offset = Vector3.ZERO
		soldier = Soldier.new()
		soldier.id = server.soldier
		soldier.position = server.position
		soldier.arsenal = server.arsenal
		return
	# Health is the server's alone; the prediction needs it for a medkit.
	soldier.health = server.health
	var at := server.last_processed_tick
	var slot := _ticks[at % HISTORY]
	var known := started and slot.tick == at and slot.stepped
	var moved := not known or not _near(slot.soldier.position, server.position, ACCEPTED_POSITION_ERROR) \
		or not _near(slot.soldier.velocity, server.velocity, ACCEPTED_VELOCITY_ERROR)
	if not moved and slot.soldier.arsenal.agrees(server.arsenal):
		return
	var before := soldier.position
	var confirmed := Soldier.new()
	confirmed.id = server.soldier
	confirmed.alive = true
	confirmed.position = server.position
	confirmed.velocity = server.velocity
	confirmed.health = server.health
	confirmed.arsenal = server.arsenal.copy()
	if known and slot.soldier.position.distance_to(server.position) < TELEPORT_DISTANCE:
		# The ground the prediction had at that tick holds for the server's
		# position, which is at most a step away.
		confirmed.grounded = slot.soldier.grounded
		confirmed.yaw = slot.soldier.yaw
		confirmed.pitch = slot.soldier.pitch
	else:
		controller.place(confirmed)
	if known:
		corrections += 1
		last_error = slot.soldier.position.distance_to(server.position)
		if not moved:
			weapon_corrections += 1
	soldier = confirmed
	var previous := InputCommand.new()
	if slot.tick == at:
		previous = slot.command
	if at > last:
		# The server is ahead of the newest recorded tick.
		last = at
	var replay := at + 1
	while replay <= last:
		var next := _ticks[replay % HISTORY]
		if next.tick != replay:
			next.tick = replay
			next.command = previous.repeated(replay)
		_step(next)
		previous = next.command
		replay += 1
	var shift := soldier.position - before
	if not started or before.distance_to(soldier.position) > TELEPORT_DISTANCE:
		_offset = Vector3.ZERO
		_previous = soldier.position
	else:
		_previous += shift
		_offset -= shift
	started = true


## drawn is where to show the soldier between two ticks: alpha is the share
## of the next tick already elapsed. It includes what is left of a correction.
func drawn(alpha: float) -> Vector3:
	return _previous.lerp(soldier.position, alpha) + _offset


func smooth(delta: float) -> void:
	_offset *= exp(-delta / SMOOTHING_TIME)


static func _near(first: Vector3, second: Vector3, limit: float) -> bool:
	var d := first - second
	return absf(d.x) <= limit and absf(d.y) <= limit and absf(d.z) <= limit


## PredictedTick is a command and the soldier it predicted.
class PredictedTick:
	var tick := -1
	var command := InputCommand.new()
	var soldier := Soldier.new()
	var stepped := false
