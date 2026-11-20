class_name ClientSession
extends RefCounted
## ClientSession is the client's side of a connection: it sends a command
## every tick and applies the snapshots it receives. Handshake makes one.

## COMMAND_LEAD is how many ticks ahead of the server's tick the client's
## commands should arrive, a margin for jitter.
const COMMAND_LEAD := 2
## The client keeps the lead by making its ticks longer or shorter, by at most
## MAX_DILATION and by DILATION_GAIN per tick of error in the lead, which it
## estimates from the snapshots with weight LEAD_SMOOTHING each.
const MAX_DILATION := 0.05
const DILATION_GAIN := 0.01
const LEAD_SMOOTHING := 0.1
## A lead further than MAX_LEAD_ERROR (250 ms) from the target is not worth
## correcting gently: the clock jumps.
const MAX_LEAD_ERROR := Game.TICK_RATE / 4
## A removed soldier's late records are ignored for this long.
const BURY_TICKS := 5 * Game.TICK_RATE
## A server that sends no snapshot for this long is taken for lost.
const SERVER_TIMEOUT := 5.0

var conn: Conn
var name := ""
var welcome: Messages.Welcome

var tick := 0
## judge_from is the first tick sent since the clock was last set: a missing
## command for an earlier tick says nothing about the current clock.
var judge_from := 0
## settle_until is the client tick from which snapshots can reflect commands
## sent under the current clock; earlier ones were already on their way.
var settle_until := 0
var history: Array[InputCommand] = []
## lead is the running estimate of the input lead; dilation stretches the
## client's ticks to bring it to the target.
var lead := 0.0
var has_lead := false
var lead_tick := 0
var dilation := 0.0
## late counts the snapshots that reported commands arriving late.
var late := 0
var acks := AckTracker.new()
var resyncs := 0
var received := 0

var server_tick := 0
var player := PlayerState.new()
## soldiers are the soldiers the client knows, by slot.
var soldiers := {}
var baselines := Baselines.new()
## buried are removed soldiers with the server tick of their removal: their
## records in datagrams that were on the way are ignored.
var buried := {}
var unresolved := 0
var clock: InterpolationClock
## bytes counts the snapshot datagrams received, payload only.
var bytes := 0
## news are the combat events the last poll took in, for the frame to show.
var news: Array = []
var graph := NetGraph.new()
## failure tells why the session ended, or is empty while it runs.
var failure := ""
var _heard := 0.0


func _init(connection: Conn, player_name: String, accepted: Messages.Welcome, handshake_rtt: float) -> void:
	conn = connection
	name = player_name
	welcome = accepted
	clock = InterpolationClock.new(accepted.snapshot_rate)
	_heard = _now()
	_set_clock(accepted.server_tick, handshake_rtt)


func is_alive() -> bool:
	return failure == ""


## send_command sends the command for the current client tick together with
## the previous ones, so that a lost datagram is covered by the next. It
## returns the command with its tick, for the prediction, or null when the
## session has failed.
func send_command(command: InputCommand) -> InputCommand:
	if failure != "":
		return null
	command.tick = tick
	var view := _view(command.tick)
	command.view_delta = view[0]
	command.view_frac = view[1]
	if history.size() == InputPacket.MAX_COMMANDS:
		history.pop_front()
	history.append(command)
	var packet := InputPacket.new()
	packet.has_ack = acks.has
	packet.ack_sequence = acks.latest
	packet.ack_bits = acks.bits
	packet.commands = history
	tick += 1
	var error := conn.send_unreliable(Protocol.encode(packet))
	if error != OK and not conn.is_open():
		_fail(conn.close_reason)
	return command


## _view tells the server for lag compensation which moment of its own the
## player sees while it makes the command of a tick: the interpolation time of
## the last frame drawn, as whole ticks before the command and a fraction of a
## tick after that. Zero, before the clock started, means now.
func _view(command_tick: int) -> Array:
	if not clock.started:
		return [0, 0]
	var whole := floorf(clock.render_tick)
	var back := command_tick - whole
	if back < 1:
		return [0, 0]
	return [mini(255, int(back)), mini(255, roundi((clock.render_tick - whole) * 256))]


func respawn() -> void:
	conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(Messages.Respawn.new()))


## poll applies what arrived since the last frame. It reports whether the
## player's own state changed, which calls for reconciliation.
func poll() -> bool:
	news.clear()
	conn.poll()
	var updated := false
	while true:
		var message := conn.receive_reliable()
		if message.is_empty():
			break
		if message[0] != Conn.Channel.EVENTS:
			continue
		var type := Protocol.peek_type(message[1])
		if type not in [Protocol.Type.HIT_CONFIRM, Protocol.Type.DAMAGE, Protocol.Type.DEATH]:
			continue
		var event: Variant = Protocol.decode(message[1])
		if event is Object:
			news.append(event)
	while true:
		var data := conn.receive_unreliable()
		if data.is_empty():
			break
		bytes += data.size()
		var snapshot := Snapshot.new()
		if Protocol.decode_into(snapshot, data) != "":
			continue
		_heard = _now()
		graph.datagram(data.size(), snapshot)
		updated = _apply(snapshot) or updated
	if failure == "":
		if not conn.is_open():
			_fail(conn.close_reason if conn.close_reason != "" else "connection closed")
		elif _now() - _heard > SERVER_TIMEOUT:
			_fail("the server stopped sending snapshots")
			conn.close(failure)
	return updated


## token is what the player gives to get its place back after a lost
## connection.
func token() -> PackedByteArray:
	return welcome.session_token


## _apply takes in one snapshot datagram. Its soldiers are applied even when it
## arrives late, since a soldier may be in no newer datagram; only the private
## state and the clocks need the newest. A delta whose base is missing drops
## the whole datagram, unacknowledged, so the server never builds on it; with
## the rule of BASE_HISTORY that is a bug, not a network condition.
func _apply(snapshot: Snapshot) -> bool:
	var resolved: Array[SoldierState] = []
	for record in snapshot.soldiers:
		if _is_buried(record.state.id, snapshot.server_tick):
			continue
		var state: Variant = baselines.resolve(snapshot.sequence, record)
		if state is String:
			unresolved += 1
			print("snapshot datagram %d dropped: %s" % [snapshot.sequence, state])
			return false
		resolved.append(state)
	acks.observe(snapshot.sequence)
	received += 1
	for id in snapshot.removed:
		_bury(id, snapshot.server_tick)
	for state in resolved:
		baselines.store(snapshot.sequence, state)
		_update(state, snapshot.server_tick, snapshot.player.soldier)
	for id in buried.keys():
		if snapshot.server_tick - buried[id] > BURY_TICKS:
			buried.erase(id)
	if received > 1 and snapshot.server_tick < server_tick:
		return false
	server_tick = snapshot.server_tick
	player = snapshot.player
	clock.observe(snapshot.server_tick)
	var own := local_soldier()
	if own != null:
		own.position = player.position
		own.velocity = player.velocity
	_keep_lead(snapshot.server_tick)
	return true


## _keep_lead adjusts the client's clock from the input lead the server
## reports: gently by the length of its ticks, or at once when it is far off.
## Only snapshots of ticks whose commands were sent under the current clock
## count.
func _keep_lead(at_tick: int) -> void:
	if not player.processed or player.input_lead == PlayerState.NO_INPUT or at_tick < judge_from \
			or tick < settle_until or (has_lead and at_tick == lead_tick):
		return
	var sample := float(player.input_lead)
	if sample < 0:
		late += 1
	if absf(sample - COMMAND_LEAD) > MAX_LEAD_ERROR:
		_jump(COMMAND_LEAD - player.input_lead)
		return
	if not has_lead:
		lead = sample
		has_lead = true
	lead += (sample - lead) * LEAD_SMOOTHING
	lead_tick = at_tick
	dilation = clampf((lead - COMMAND_LEAD) * DILATION_GAIN, -MAX_DILATION, MAX_DILATION)


## tick_duration is how long a client tick takes in real time now.
func tick_duration() -> float:
	return Game.TICK_DELTA * (1 + dilation)


## _update applies a soldier's state from a snapshot of the given server tick.
## A new soldier in a known slot replaces the old one, even if the removal of
## that one has not arrived yet.
func _update(state: SoldierState, at_tick: int, own: int) -> void:
	var slot := SoldierSet.slot_of(state.id)
	var known: KnownSoldier = soldiers.get(slot)
	if known != null and known.soldier.id != state.id:
		_bury(known.soldier.id, at_tick)
		known = null
	if known == null:
		known = KnownSoldier.new(at_tick)
		soldiers[slot] = known
	if at_tick >= known.tick:
		if known.updates > 0 and state.id != own:
			known.schedule(state, at_tick)
		state.apply(known.soldier)
		known.tick = at_tick
	known.updates += 1
	if state.id == own:
		return
	var soldier := Soldier.new()
	state.apply(soldier)
	var remote := known.remote
	if not clock.started or remote.count == 0:
		remote.add(at_tick, soldier)
		return
	# A state that changes where the soldier is drawn now, after a stretch of
	# extrapolation, is caught up with smoothly.
	remote.evaluate(clock.render_tick)
	var before := remote.position
	remote.add(at_tick, soldier)
	remote.keep(before, clock.render_tick)


func _bury(id: int, at_tick: int) -> void:
	if not buried.has(id) or at_tick < buried[id]:
		buried[id] = at_tick
	baselines.forget(id)
	var slot := SoldierSet.slot_of(id)
	var known: KnownSoldier = soldiers.get(slot)
	if known != null and known.soldier.id == id:
		soldiers.erase(slot)


## _is_buried reports whether a record of the given server tick belongs to a
## soldier removed since. A later record means the slot came round to the same
## generation again.
func _is_buried(id: int, at_tick: int) -> bool:
	if not buried.has(id):
		return false
	if at_tick > buried[id]:
		buried.erase(id)
		return false
	return true


## _jump moves the client's clock by the given number of ticks, when the lead
## is too far off to correct gently: after a stall, or a change of route.
func _jump(ticks: int) -> void:
	var before := tick
	tick += ticks
	var ahead := maxi(0, int(conn.stats.rtt * Game.TICK_RATE))
	judge_from = tick
	settle_until = tick + ahead + COMMAND_LEAD + 2
	history.clear()
	has_lead = false
	dilation = 0.0
	resyncs += 1
	print("clock jump: our commands were %d ticks ahead of server tick %d; client tick %d -> %d" % [
		player.input_lead, server_tick, before, tick])


## _set_clock sets the client tick from a server tick the client just learned.
## That tick is already half a round trip old and a command needs the other
## half to reach the server, so the client runs a whole round trip plus the
## lead ahead of it.
func _set_clock(at_server_tick: int, rtt: float) -> void:
	var ahead := ceili(rtt * Game.TICK_RATE)
	tick = at_server_tick + 1 + COMMAND_LEAD + ahead
	judge_from = tick
	settle_until = tick + ahead + COMMAND_LEAD + 2


## local_soldier is the player's own soldier as of the latest snapshot, or
## null before it spawned.
func local_soldier() -> Soldier:
	if player.soldier == 0:
		return null
	var known: KnownSoldier = soldiers.get(SoldierSet.slot_of(player.soldier))
	if known != null and known.soldier.id == player.soldier:
		return known.soldier
	return null


## update_remotes does a frame's work on the other soldiers without drawing
## them: smoothing and interpolating every one, as a headless client.
func update_remotes(delta: float) -> void:
	for known in soldiers.values():
		if known.soldier.id != player.soldier and known.remote.count > 0:
			known.remote.smooth(delta)
			known.remote.evaluate(clock.render_tick)


## close ends the session for good: the server frees the player's place.
func close() -> void:
	conn.close(Protocol.QUIT_REASON)
	if failure == "":
		failure = "closed"


## abandon lets go of a lost session; the player means to come back.
func abandon() -> void:
	conn.close("connection lost")
	if failure == "":
		failure = "abandoned"


func _fail(reason: String) -> void:
	if failure == "":
		failure = reason


static func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0
