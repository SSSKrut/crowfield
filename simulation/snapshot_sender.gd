class_name SnapshotSender
extends RefCounted
## SnapshotSender sends every ready player its snapshot of the tick
## (ARCHITECTURE.md, 6.6). The soldiers are quantized once, then every player's
## datagrams are built. The building makes no objects in its loops: in GDScript
## that and the number of calls is what costs.
##
## Some soldiers go into every snapshot, ahead of all others: the player's own,
## the other humans (at most 15) and those near the crosshair, since lag
## compensation is only fair when what the player shoots at was drawn by
## interpolation (6.9).
##
## The others share what is left of the budget by priority. Every snapshot, a
## soldier's priority grows by its update rate, in updates per second, times
## the snapshot interval; the highest go first, and sending one resets it.
## When the budget is short, soldiers are updated in proportion to their rates.

## DATAGRAM_OVERHEAD estimates what a snapshot datagram costs on the wire
## besides its payload: IPv4 and UDP headers (28 bytes), the ENet headers
## (about 10) and DTLS (about 29). The budget of a client counts it.
const DATAGRAM_OVERHEAD := 67
## A further datagram of a snapshot is sent only with this much room.
const MIN_DATAGRAM_ROOM := 200
## Bots within NEAR_DISTANCE get NEAR_RATE; farther ones less, down to
## FAR_RATE. In the wide cone around the line of sight they get CONE_RATE.
const NEAR_RATE := 10.0
const NEAR_DISTANCE := 20.0
const FAR_RATE := 1.0
const CONE_RATE := 40.0
const CONE_ANGLE := 10.0 * PI / 180.0
## CROSSHAIR_ANGLE is the narrow cone of soldiers sent every snapshot. In a
## crowd the wide cone holds dozens of soldiers.
const CROSSHAIR_ANGLE := 2.0 * PI / 180.0
## Both cones are widened by this much at the soldier's distance: a soldier
## counts while any part of it is near the line.
const CONE_MARGIN := 0.5

const _ALWAYS := 1 << 62

## _states are the soldiers by slot as quantized at the tick in _quantized;
## null marks an empty slot.
var _states: Array[SoldierState] = []
var _quantized := PackedInt64Array()
var _server: Server
var _ready: Array[ServerPlayer] = []
var _cone_cos := cos(CONE_ANGLE)
var _cone_sin := sin(CONE_ANGLE)
var _crosshair_cos := cos(CROSSHAIR_ANGLE)
var _crosshair_sin := sin(CROSSHAIR_ANGLE)


## send_all sends every ready player its snapshot of the tick. A soldier is
## quantized once, when a snapshot first needs it.
func send_all(server: Server) -> void:
	_server = server
	var soldiers := server.soldiers
	if _states.size() != soldiers.slots():
		_states.resize(soldiers.slots())
		_quantized.resize(soldiers.slots())
		_quantized.fill(-1)
	_ready.clear()
	for player in server.players:
		if player != null and player.ready:
			_ready.append(player)
	for index in _ready.size():
		_build(index)
	for player in _ready:
		server.profile.snapshot_bytes += player.outbox_bytes
		for data in player.outbox:
			if player.conn.send_unreliable(data) != OK:
				break
		player.outbox.clear()
	_server = null


## _state_of is the soldier in a slot quantized at this tick, or null for an
## empty slot or a soldier outside the range of the protocol.
func _state_of(slot: int) -> SoldierState:
	if _quantized[slot] != _server.tick:
		var soldier := _server.soldiers.at(slot)
		_states[slot] = null if soldier == null else SoldierState.create(soldier)
		_quantized[slot] = _server.tick
	return _states[slot]


## _build makes the datagrams of one player: the soldiers it needs most,
## within its budget. Every datagram carries the private state, so each one is
## useful alone, and the first carries the removals.
func _build(index: int) -> void:
	var server := _server
	var player := _ready[index]
	player.outbox_bytes = 0
	var private := PlayerState.new()
	private.processed = player.processed
	private.last_processed_tick = player.last_processed
	private.input_lead = player.lead
	private.soldier = player.soldier
	var own := server.soldiers.get_soldier(player.soldier)
	if own != null:
		private.position = own.position
		private.velocity = own.velocity
		private.crouched = own.crouched
		private.arsenal = own.arsenal
		private.health = own.health
		if not own.alive:
			private.respawn = clampi(player.respawn_at - server.tick, 1, 65535)
	_prioritize(server, player)
	var kept: Array[ServerPlayer.PendingRemoval] = []
	for removal in player.removals:
		if not player.removal_delivered(removal):
			kept.append(removal)
	player.removals = kept
	var per_snapshot := float(server.settings.client_bandwidth) / server.settings.snapshot_rate
	player.allowance = minf(player.allowance + per_snapshot, 2 * per_snapshot)
	var snapshot := player.snapshot
	if server.flag_match != null:
		if snapshot.match_state == null:
			snapshot.match_state = MatchState.new()
		snapshot.match_state.set_round(server.flag_match.state)
		snapshot.match_state.kills = player.kills
	var packer := player.packer
	var candidates := player.candidates
	var next := 0
	var first := true
	while first or next < candidates.size():
		var room := mini(Snapshot.BUDGET, int(player.allowance) - DATAGRAM_OVERHEAD)
		if not first and room < MIN_DATAGRAM_ROOM:
			break
		snapshot.sequence = player.datagrams & 0xFFFF
		snapshot.server_tick = server.tick
		snapshot.player = private
		snapshot.removed = PackedInt32Array()
		var removed: Array[ServerPlayer.PendingRemoval] = []
		if first:
			for removal in player.removals:
				if removed.size() == Snapshot.MAX_REMOVED:
					break
				removed.append(removal)
				snapshot.removed.append(removal.id)
		packer.reset(snapshot, maxi(0, room))
		var from := next
		while next < candidates.size():
			var slot := _slot(candidates[next])
			var state := _state_of(slot)
			if state == null:
				# Outside the range of the protocol: the soldier left the map.
				candidates.remove_at(next)
				continue
			var view := player.views[slot]
			var age := view.base_age(player)
			if not packer.add(state, view.base, age):
				break
			next += 1
		packer.finish()
		var data := Protocol.encode(snapshot)
		if data.is_empty():
			return
		for i in range(from, next):
			var slot := _slot(candidates[i])
			player.views[slot].sent(player.datagrams, _states[slot])
		for removal in removed:
			removal.sent(player.datagrams)
		player.acks[player.datagrams % ServerPlayer.ACK_WINDOW] = 0
		player.datagrams += 1
		player.allowance -= data.size() + DATAGRAM_OVERHEAD
		player.outbox_bytes += data.size() + DATAGRAM_OVERHEAD
		player.outbox.append(data)
		if next == from and not first:
			return
		first = false


## _prioritize notices soldiers that left the player's view, raises the
## priority of the others and orders them, the most urgent first. A candidate
## packs the order into one number: the soldiers sent every snapshot first,
## then the highest priority, then the lowest slot.
func _prioritize(server: Server, player: ServerPlayer) -> void:
	var interval := 1.0 / server.settings.snapshot_rate
	var all := server.soldiers._soldiers
	var viewer := server.soldiers.get_soldier(player.soldier)
	var eye := Vector3.ZERO
	var forward := Vector3.ZERO
	var center := Vector3(0, server.rules.movement.center_height(), 0)
	if viewer != null:
		eye = viewer.position + Vector3.UP * server.rules.movement.view_height(viewer.crouched)
		forward = Game.view_direction(player.last.yaw_radians(), player.last.pitch_radians())
	var candidates := player.candidates
	candidates.resize(0)
	var views := player.views
	var own := player.soldier
	const HIT_MASK := (1 << SoldierState.HIT_COUNT_BITS) - 1
	for slot in views.size():
		var view := views[slot]
		var soldier := all[slot]
		var id := 0 if soldier == null else soldier.id
		if view.id != id:
			if view.ever_sent():
				player.removals.append(ServerPlayer.PendingRemoval.new(view.id))
			view.reset(id)
		if soldier == null:
			continue
		var rate := NEAR_RATE
		var always := true
		if id != own and soldier.controller != Game.Controller.PLAYER and viewer != null:
			# The rate by the cones around the line of sight and the distance
			# (_rate), written out: this loop runs for every soldier and player.
			var to := soldier.position + center - eye
			var length := to.length()
			if length >= CONE_MARGIN:
				var cosine := forward.dot(to) / length
				var margin_sine := CONE_MARGIN / length
				var margin_cosine := sqrt(1 - margin_sine * margin_sine)
				if cosine >= _crosshair_cos * margin_cosine - _crosshair_sin * margin_sine:
					rate = CONE_RATE
				elif cosine >= _cone_cos * margin_cosine - _cone_sin * margin_sine:
					rate = CONE_RATE
					always = false
				else:
					rate = maxf(FAR_RATE, NEAR_RATE * minf(1.0, NEAR_DISTANCE / length))
					always = false
			else:
				rate = CONE_RATE
		# A death or a hit goes out at once, to everyone: a soldier seen once a
		# second would otherwise run on past where it fell.
		var last := view.states[(view.next + SoldierRecord.BASE_HISTORY - 1) % SoldierRecord.BASE_HISTORY]
		if last != null and ((last.flags & SoldierState.ALIVE != 0) != soldier.alive or last.hit_count != soldier.hit_count & HIT_MASK):
			always = true
		view.priority += rate * interval
		var key := (mini(int(view.priority * 1024), (1 << 49) - 1) << 12) | (SoldierSet.MAX_SOLDIERS - 1 - slot)
		if always:
			key |= _ALWAYS
		candidates.append(key)
	candidates.sort()
	candidates.reverse()
	player.candidates = candidates


static func _slot(candidate: int) -> int:
	return SoldierSet.MAX_SOLDIERS - 1 - (candidate & (SoldierSet.MAX_SOLDIERS - 1))


## _rate is how many updates per second a soldier whose middle is at target
## deserves from an eye looking along forward; negative for one that goes into
## every snapshot, whose rate still orders it, should it not fit.
func _rate(eye: Vector3, forward: Vector3, target: Vector3) -> float:
	var to := target - eye
	var length := to.length()
	if length < CONE_MARGIN:
		return -CONE_RATE
	# The soldier is within a cone when the angle to it, less the angle its
	# margin takes, is within the cone's: compared as cosines.
	var cosine := forward.dot(to) / length
	var margin_sine := CONE_MARGIN / length
	var margin_cosine := sqrt(1 - margin_sine * margin_sine)
	if cosine >= _crosshair_cos * margin_cosine - _crosshair_sin * margin_sine:
		return -CONE_RATE
	if cosine >= _cone_cos * margin_cosine - _cone_sin * margin_sine:
		return CONE_RATE
	return maxf(FAR_RATE, NEAR_RATE * minf(1.0, NEAR_DISTANCE / length))
