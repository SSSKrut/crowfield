class_name HeadlessClient
extends RefCounted
## HeadlessClient is a client without a window, for load tests: it plays with
## random input through the whole client path of a real one — the session
## with its clock, prediction and reconciliation, the snapshots with their
## deltas and interpolation — but draws nothing. Call tick() at the pace of
## the session's clock, tick_duration().

var session: ClientSession
var predictor: Predictor
var handshake: Handshake
var input: Wanderer
var shots := 0
var hits := 0
var kills := 0
var deaths := 0
var ticks := 0
var largest_correction := 0.0
## error tells why the client stopped.
var error := ""
var _rules: Rules
var _last := -1.0


## The client predicts in space, which holds the static map; headless clients
## may share one, as their capsules do not meet each other.
func _init(conn: Conn, name: String, rules: Rules, seed: int, space: RID) -> void:
	_rules = rules
	predictor = Predictor.new(space, rules)
	handshake = Handshake.new(conn, name, rules, MapScene.prototype().hash_value())
	input = Wanderer.new(seed, MapScene.prototype().play_area)


func close() -> void:
	if session != null:
		session.close()
	elif handshake != null:
		handshake.conn.close(Protocol.QUIT_REASON)
	predictor.close()


func joined() -> bool:
	return session != null


func tick_duration() -> float:
	return session.tick_duration() if session != null else Game.TICK_DELTA


## tick plays one tick: a command, its prediction, the snapshots that came and
## the frame work on the other soldiers. It returns false once the client has
## stopped; error tells why.
func tick() -> bool:
	if error != "":
		return false
	if session == null:
		handshake.poll()
		if handshake.failed():
			error = handshake.error
			return false
		if not handshake.done():
			return true
		session = handshake.session
		predictor.join(session.welcome.match_seed)
	var command := session.send_command(input.command(predictor))
	if command == null:
		error = "disconnected: %s" % session.failure
		return false
	var result := predictor.predict(command)
	if result.has(Arsenal.EVENT_FIRED):
		shots += 1
	if session.poll():
		predictor.reconcile(session.player)
		largest_correction = maxf(largest_correction, predictor.last_error)
	if not session.is_alive():
		error = "disconnected: %s" % session.failure
		return false
	for event in session.news:
		if event is Messages.HitConfirm:
			hits += 1
			if event.killed:
				kills += 1
		elif event is Messages.Death and event.victim == session.player.soldier:
			deaths += 1
	var now := ClientSession._now()
	if _last < 0:
		_last = now
	var delta := now - _last
	predictor.smooth(delta)
	session.clock.advance(delta)
	session.update_remotes(delta)
	_last = now
	ticks += 1
	return true


## rejoin comes back over a new connection after the old one was lost: the
## server gives the player its place and team again.
func rejoin(conn: Conn) -> void:
	var token := session.token()
	var name := session.name
	session.abandon()
	session = null
	error = ""
	handshake = Handshake.new(conn, name, _rules, MapScene.prototype().hash_value(), token)


## Wanderer is random input: it walks or runs in a direction for a few
## seconds, sometimes stands or jumps, and turns back inside the play area.
## Now and then it shoots, aims, reloads or takes another weapon.
class Wanderer:
	var random := RandomNumberGenerator.new()
	var area: float
	var elapsed := 0.0
	var until := 0.0
	var yaw := 0.0
	var forward := 0.0
	var buttons := 0
	var firing := false
	var weapon := 0
	var ticks := 0

	func _init(seed: int, play_area: float) -> void:
		random.seed = seed ^ 24301
		area = play_area

	func command(predictor: Predictor) -> InputCommand:
		elapsed += Game.TICK_DELTA
		var position := predictor.soldier.position
		var outside := predictor.started and maxf(absf(position.x), absf(position.z)) > area - 2
		if outside or elapsed >= until:
			until = elapsed + 1 + 2 * random.randf()
			yaw = random.randf() * TAU
			if outside:
				# Head back towards the middle of the map before the edge.
				yaw = atan2(-position.x, position.z)
			forward = 1.0
			buttons = 0
			var roll := random.randi_range(0, 9)
			if roll < 2:
				forward = 0.0
			elif roll < 5:
				buttons = InputCommand.SPRINT
			firing = random.randi_range(0, 2) == 0
			if firing and random.randi_range(0, 1) == 0:
				buttons |= InputCommand.AIM
			if random.randi_range(0, 4) == 0:
				weapon = random.randi_range(0, Arsenal.MAX_LOADOUT - 1)
		ticks += 1
		var pressed := buttons
		if random.randi_range(0, 119) == 0:
			pressed |= InputCommand.JUMP
		# Pulls of a quarter second fire bursts and single shots alike.
		if firing and ticks % 30 < 15:
			pressed |= InputCommand.FIRE
		if random.randi_range(0, 239) == 0:
			pressed |= InputCommand.RELOAD
		var result := InputCommand.create(0, forward, 0, yaw, 0, pressed)
		result.weapon = weapon
		return result
