class_name Server
extends RefCounted
## Server is the authoritative simulation. It owns every piece of game state;
## connections only bring messages to it, and step() runs one tick: it takes
## in what arrived, moves the soldiers, resolves the shots and sends the
## snapshots. Its physics space holds the static map and the capsules of
## humans, apart from any world a client draws.

## A soldier that falls this far below the map goes back to the spawn.
const FALL_LIMIT := -10.0
## GRID_CELL_SIZE suits the queries of bots, which keep a little over a metre
## from each other, and the tracks of shots.
const GRID_CELL_SIZE := 4.0
const HELLO_TIMEOUT := 5.0
## Reinforcement positions are on the home bank, behind the flag's capture
## area. Search the approach before considering positions farther back.
const REINFORCEMENT_OFFSETS := [Vector2(0, 15), Vector2(-5, 17), Vector2(5, 17),
	Vector2(0, 20), Vector2(-10, 20), Vector2(10, 20), Vector2(0, 25)]
const REINFORCEMENT_ENEMY_RADIUS := 16.0
const REINFORCEMENT_SIGHT_RANGE := 65.0
## Keep a group of simultaneous respawns from crowding a simulation tick.
const REINFORCEMENT_RAY_BUDGET := 96
## Messages are limited per connection before they are decoded
## (ARCHITECTURE.md, 6.8), so that one client cannot crowd the simulation:
## input datagrams to twice the tick rate, of which an honest client sends one
## a tick, and reliable messages to a few a second, of which it sends two in
## all. Excess datagrams are dropped; excess reliable messages close the
## connection.
const INPUT_RATE := 2.0 * Game.TICK_RATE
const INPUT_BURST := Game.TICK_RATE / 2.0
const CONTROL_RATE := 2.0
const CONTROL_BURST := 8.0

var settings: ServerSettings
var rules: Rules
var scene: MapScene
var space: RID
var soldiers: SoldierSet
var players: Array[ServerPlayer] = []
var sessions: Array[Session] = []
var reservations: Array[Reservation] = []
var tick := 0
var snapshot_interval := 3
var match_seed := 0
var navigation: Navigation
var bots: Bots
var vehicles: ServerVehicles
var flag_match: FlagMatch
## random places the soldiers of players in the zones of their teams.
var random := RandomNumberGenerator.new()
## projectiles are the rockets and grenades in flight.
var projectiles: Array[Projectile] = []
var grid := SoldierGrid.new(GRID_CELL_SIZE)
var history: PoseHistory
var profile := TickProfile.new()
## total_hits counts the hits since the start, past the profile.
var total_hits := 0
## dropped_inputs counts the input datagrams over the limit, dropped unread.
var dropped_inputs := 0
## clock returns the time in seconds; tests may replace it.
var clock: Callable = func() -> float: return Time.get_ticks_usec() / 1000000.0

var _listeners: Array[Listener] = []
var _collision: Array[RID] = []
var _space_state: PhysicsDirectSpaceState3D
var _ray := PhysicsRayQueryParameters3D.new()
var _reinforcement_sites: Dictionary[Vector2i, PackedVector3Array] = {}
var _reinforcement_rays := REINFORCEMENT_RAY_BUDGET
## _shots are the shots of the current tick, resolved after every soldier acted.
var _shots: Array[PendingShot] = []
var _snapshots := SnapshotSender.new()
var _next_projectile := 1
## _launchers names the owner of each projectile, for the kill feed: a
## soldier who dies before its grenade bursts is gone by then.
var _launchers := {}


## create builds the world of the map of the settings and its navigation.
## Only its static part runs on the server: dynamic props are not replicated
## yet, so clients keep them as local decoration. It returns the server, or
## the error as a String.
static func create(server_settings: ServerSettings, server_rules: Rules) -> Variant:
	var error := server_settings.validate()
	if error == "":
		error = server_rules.validate()
	if error != "":
		return error
	var server := Server.new()
	server.settings = server_settings
	server.rules = server_rules
	server.scene = server_settings.scene if server_settings.scene != null else MapScene.named(server_settings.map)
	server.space = PhysicsServer3D.space_create()
	server._collision = server.scene.build_collision(server.space)
	server._space_state = PhysicsServer3D.space_get_direct_state(server.space)
	var capacity := server_settings.max_players + server_settings.bots
	server.soldiers = SoldierSet.new(capacity)
	server.history = PoseHistory.new(capacity)
	server.players.resize(Game.MAX_PLAYERS)
	server.snapshot_interval = Game.TICK_RATE / server_settings.snapshot_rate
	server.match_seed = server_settings.seed
	if server.match_seed == 0:
		server.match_seed = Crypto.new().generate_random_bytes(8).decode_s64(0)
	server.random.seed = server.match_seed ^ 7919
	server.navigation = Navigation.create(server.scene)
	server.vehicles = ServerVehicles.new(server, server._collision[0] if server.scene.terrain != null else RID())
	if server.scene.flags.size() == MatchState.FLAG_COUNT:
		server.flag_match = FlagMatch.new(server.scene.flags)
		server._build_reinforcement_sites()
	server.bots = Bots.new(server)
	server.bots.spawn_all(server_settings.bots)
	return server


## tick_time is the simulation clock used by tests that run in lockstep.
func tick_time() -> float:
	return float(tick) / Game.TICK_RATE


## close frees the world and ends every connection.
func close() -> void:
	for session in sessions:
		session.conn.close("server is shutting down")
	for listener in _listeners:
		listener.flush()
	for player in players:
		if player != null and player.controller != null:
			player.controller.close()
	if vehicles != null:
		vehicles.close()
		vehicles = null
	if space.is_valid():
		MapScene.free_collision(_collision)
		PhysicsServer3D.free_rid(space)
	space = RID()
	if navigation != null:
		navigation.close()
	# The bots and the sessions point back at the server: let go of them.
	bots = null
	projectiles.clear()
	sessions.clear()
	players.fill(null)


## add_listener accepts clients from a listener; its owner closes it.
func add_listener(listener: Listener) -> void:
	_listeners.append(listener)


## step runs one tick. The dead whose time has come return, commands for this
## tick move the soldiers and fire their weapons, the shots hit, and the
## snapshot describes the state at the end of the tick.
func step() -> void:
	var started := Time.get_ticks_usec()
	profile.start()
	_expire_reservations()
	_reset_finished_round()
	_handle_connections()
	_drop_silent_sessions()
	_respawn_dead()
	profile.lap(TickProfile.System.EVENTS)
	for player in players:
		if player != null and player.soldier != 0:
			_move_player(player)
	vehicles.update()
	profile.lap(TickProfile.System.PLAYERS)
	bots.update()
	profile.lap(TickProfile.System.BOTS)
	_resolve_shots()
	_move_projectiles()
	bots.kill()
	profile.lap(TickProfile.System.SHOTS)
	grid.rebuild(soldiers)
	if flag_match != null:
		flag_match.step(soldiers, grid)
	profile.lap(TickProfile.System.GRID)
	history.record(tick, soldiers)
	profile.lap(TickProfile.System.HISTORY)
	if tick % snapshot_interval == 0:
		_snapshots.send_all(self)
	for listener in _listeners:
		listener.flush()
	profile.lap(TickProfile.System.SNAPSHOTS)
	tick += 1
	profile.finish(started)


func player_count() -> int:
	var count := 0
	for player in players:
		if player != null:
			count += 1
	return count


func _move_player(player: ServerPlayer) -> void:
	var command := player.take_input(tick)
	if command == null:
		command = player.last.repeated(tick)
		profile.missed_commands += 1
	player.lead = PlayerState.NO_INPUT
	if player.has_input:
		player.lead = clampi(player.newest - tick, PlayerState.NO_INPUT + 1, 127)
	command.sanitize()
	player.last = command
	player.processed = true
	player.last_processed = tick
	var soldier := soldiers.get_soldier(player.soldier)
	if not soldier.alive:
		# The dead do not move or shoot; the commands still keep the clock.
		return
	if command.has(InputCommand.INTERACT):
		_get_in_or_out(player, soldier)
	var vehicle := vehicles.get_vehicle(soldier.vehicle)
	if vehicle != null:
		var shell := vehicles.drive(vehicle, soldier, command)
		if shell != null:
			_launch(soldier, shell, rules.weapons.get_tuning(shell.weapon))
		return
	var result := player.controller.run_command(rules.weapons, soldier, command, match_seed)
	if result.has(Arsenal.EVENT_FIRED):
		queue_shot(soldier, result.shot, _view_time(command))
	if soldier.position.y < FALL_LIMIT:
		player.controller.teleport(soldier, spawn_point(soldier.team, random))


## _get_in_or_out puts a soldier on foot in a tank in reach, or takes a
## driver out onto free ground beside its tank. A driver has no capsule.
func _get_in_or_out(player: ServerPlayer, soldier: Soldier) -> void:
	if soldier.vehicle == 0:
		if vehicles.enter(soldier) != null:
			player.controller.close()
			player.controller = null
		return
	var at := vehicles.exit(soldier)
	if not at.is_finite():
		return
	soldier.velocity = Vector3.ZERO
	player.controller = CharacterController.new(space, rules.movement)
	player.controller.teleport(soldier, at)


## queue_shot takes what a soldier fired this tick: bullets, to resolve with
## the others once every soldier acted, as they were at view, the moment its
## shooter saw; a projectile, which leaves at once; or a medkit, which heals.
func queue_shot(soldier: Soldier, shot: Shot, view: float) -> void:
	var tuning := rules.weapons.get_tuning(shot.weapon)
	match tuning.use:
		WeaponTuning.Use.HEAL:
			soldier.health = mini(Game.MAX_HEALTH, soldier.health + tuning.heal)
			return
		WeaponTuning.Use.PROJECTILE:
			_launch(soldier, shot, tuning)
			return
	_shots.append(PendingShot.new(soldier.id, soldier.team, shot, view))
	soldier.shots += 1
	profile.shots += 1


## spawn_point picks where a soldier of a team appears: a random point of the
## zone of the team on the navigation mesh, on the ground; the zone itself
## when it is a point.
func spawn_point(team: int, from: RandomNumberGenerator) -> Vector3:
	var zone := scene.zone_of(team)
	if zone.radius <= 0:
		return zone.center
	var offset := Vector2.from_angle(from.randf() * TAU) * sqrt(from.randf()) * zone.radius
	var point := navigation.closest(zone.center + Vector3(offset.x, 0.5, offset.y))
	var down := cast_ray(point + Vector3(0, 1.0, 0), Vector3.DOWN, 2.5, Game.LAYER_STATIC)
	if down >= 0:
		point.y += 1.0 - down
	return point


## Precompute clear positions on the navigation mesh at server startup.
## Ownership, enemy visibility and occupation are checked at the respawn tick.
func _build_reinforcement_sites() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = rules.movement.capsule_radius
	capsule.height = 2.0 * rules.movement.center_height()
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = Game.LAYER_STATIC | Game.LAYER_VEHICLE | Game.LAYER_DYNAMIC
	for team: int in [Game.Team.BLUE, Game.Team.RED]:
		var home := scene.spawn_of(team)
		for index in scene.flags.size():
			var zone := scene.flags[index]
			var crossing := navigation.closest(zone.center)
			var side := 1.0 if home.z > zone.center.z else -1.0
			var sites := PackedVector3Array()
			for offset: Vector2 in REINFORCEMENT_OFFSETS:
				var point := zone.center + side * Vector3(offset.x, 0.0, offset.y)
				point.y = scene.ground_at(point.x, point.z)
				var walkable := navigation.closest(point)
				if walkable.distance_squared_to(point) > 1.0:
					continue
				var down := cast_ray(walkable + Vector3.UP * 0.6, Vector3.DOWN, 1.6, Game.LAYER_STATIC)
				if down < 0.0:
					continue
				walkable.y += 0.6 - down
				query.transform = Transform3D(Basis.IDENTITY, walkable + Vector3.UP * (rules.movement.center_height() + 0.04))
				if not _space_state.intersect_shape(query, 1).is_empty():
					continue
				var route := navigation.path(walkable, crossing)
				if not route.is_empty() and route[-1].distance_squared_to(crossing) <= 1.0:
					sites.append(walkable)
			_reinforcement_sites[Vector2i(team, index)] = sites


## Returns a safe site by a held crossing, optionally limited to the fight
## the soldier was part of. All callers share the tick's ray budget.
func reinforcement_point(team: int, from: Vector3, max_distance: float = INF, lane := -1) -> Vector3:
	if _reinforcement_sites.is_empty() or not flag_match.started or flag_match.state.result != MatchState.Result.ACTIVE:
		return Vector3.INF
	var best := Vector3.INF
	var best_distance := max_distance * max_distance
	for order in scene.flags.size():
		# Mirrored priority breaks equal-distance ties consistently for both sides.
		var index := order if team == Game.Team.BLUE else scene.flags.size() - order - 1
		if lane >= 0 and index != lane:
			continue
		var flag := flag_match.state.flags[index]
		if flag.owner != team or flag.contested or flag.challenger != Game.Team.NONE:
			continue
		var distance := from.distance_squared_to(scene.flags[index].center)
		if distance >= best_distance:
			continue
		for site in _reinforcement_sites[Vector2i(team, index)]:
			if _reinforcement_is_safe(team, site):
				best = site
				best_distance = distance
				break
	return best


func _reinforcement_is_safe(team: int, point: Vector3) -> bool:
	var eye := Vector3.UP * rules.movement.eye_height
	var occupancy := maxf(1.5, rules.movement.capsule_radius * 2.0)
	for slot in soldiers.slots():
		var soldier := soldiers.at(slot)
		if soldier == null or not soldier.alive:
			continue
		var distance := Game.horizontal_length(point - soldier.position)
		if soldier.team == team:
			if distance < occupancy and absf(point.y - soldier.position.y) < 2.0 * rules.movement.center_height():
				return false
			continue
		if distance < REINFORCEMENT_ENEMY_RADIUS:
			return false
		if distance > REINFORCEMENT_SIGHT_RANGE:
			continue
		var from := soldier.position + Vector3.UP * rules.movement.view_height(soldier.crouched)
		for target in [point + eye, point + eye * 0.65]:
			if _reinforcement_rays <= 0:
				return false
			_reinforcement_rays -= 1
			var sight: Vector3 = target - from
			var cover := cast_ray(from, sight.normalized(), sight.length(), Game.LAYER_STATIC | Game.LAYER_VEHICLE)
			if cover < 0.0:
				return false
	return true


## Fresh joins keep their base start. After a death, reinforce the nearest
## friendly crossing with a safe position, or use that same base start.
func _spawn(player: ServerPlayer, death_position: Vector3 = Vector3.INF) -> bool:
	if player.team == Game.Team.NONE:
		player.team = _smaller_team()
	var at := Vector3.INF if not death_position.is_finite() else reinforcement_point(player.team, death_position)
	if not at.is_finite():
		at = spawn_point(player.team, random)
	var soldier := Soldier.new()
	soldier.team = player.team
	soldier.controller = Game.Controller.PLAYER
	soldier.player = player.id
	soldier.alive = true
	soldier.position = at
	soldier.health = Game.MAX_HEALTH
	soldier.arsenal = Arsenal.create(Arsenal.default_loadout(), rules.weapons)
	var id := soldiers.add(soldier)
	if id == 0:
		return false
	player.soldier = id
	player.controller = CharacterController.new(space, rules.movement)
	player.controller.teleport(soldier, at)
	return true


func _smaller_team() -> int:
	var blue := 0
	var red := 0
	for slot in soldiers.slots():
		var soldier := soldiers.at(slot)
		if soldier == null:
			continue
		if soldier.team == Game.Team.BLUE:
			blue += 1
		elif soldier.team == Game.Team.RED:
			red += 1
	return Game.Team.RED if red < blue else Game.Team.BLUE


# Connections.


func _handle_connections() -> void:
	var now: float = clock.call()
	for listener in _listeners:
		listener.poll()
		while true:
			var conn := listener.accept()
			if conn == null:
				break
			sessions.append(Session.new(conn, now))
	for session: Session in sessions.duplicate():
		_read_session(session, now)


func _read_session(session: Session, now: float) -> void:
	var conn := session.conn
	conn.poll()
	while sessions.has(session):
		var message := conn.receive_reliable()
		if message.is_empty():
			break
		if not session.control_limit.allow(now):
			_drop(session, "too many messages")
			return
		var data: PackedByteArray = message[1]
		var type := Protocol.peek_type(data)
		if type not in [Protocol.Type.HELLO, Protocol.Type.READY, Protocol.Type.RESPAWN, Protocol.Type.CERTIFICATE_REQUEST]:
			_drop(session, "bad message: unexpected %s message" % Protocol.type_name(type))
			return
		var decoded: Variant = Protocol.decode(data)
		if decoded is String:
			_drop(session, "bad message: %s" % decoded)
			return
		match type:
			Protocol.Type.HELLO:
				_hello(session, decoded)
			Protocol.Type.READY:
				_ready(session)
			Protocol.Type.RESPAWN:
				_respawn(session)
			Protocol.Type.CERTIFICATE_REQUEST:
				_certificate(session)
	if not sessions.has(session):
		return
	# Datagrams that do not decode are ignored: they are unreliable anyway.
	# Datagrams over the limit are dropped unread.
	while true:
		var data := conn.receive_unreliable()
		if data.is_empty():
			break
		if not session.input_limit.allow(now):
			dropped_inputs += 1
			continue
		var packet := InputPacket.new()
		if Protocol.decode_into(packet, data) != "":
			continue
		_input(session, packet, now)
	if not conn.is_open():
		_leave(session, conn.close_reason, conn.closed_by_peer)


func _input(session: Session, packet: InputPacket, now: float) -> void:
	var player := session.player
	if player == null:
		return
	player.last_input = now
	player.acknowledge(packet)
	for command in packet.commands:
		player.put_input(command, tick)
	# Late commands count too: they tell how late the client is.
	var count := packet.commands.size()
	if count > 0 and packet.commands[count - 1].tick - tick < ServerPlayer.INPUT_WINDOW:
		player.newest = packet.commands[count - 1].tick
		player.has_input = true


func _hello(session: Session, hello: Messages.Hello) -> void:
	if session.player != null:
		_drop(session, "hello sent twice")
		return
	if hello.protocol_version != Protocol.VERSION:
		_reject(session, Messages.Reject.Reason.VERSION,
			"the server speaks protocol %d, the client %d" % [Protocol.VERSION, hello.protocol_version])
		return
	var player := _returning(hello)
	if player == null:
		var id := _free_player()
		if id < 0:
			_reject(session, Messages.Reject.Reason.FULL, "the server is full")
			return
		player = ServerPlayer.new(id, hello.name, soldiers.slots())
	player.conn = session.conn
	player.last_input = clock.call()
	var welcome := Messages.Welcome.new()
	welcome.player = player.id
	welcome.session_token = player.token
	welcome.tick_rate = Game.TICK_RATE
	welcome.snapshot_rate = settings.snapshot_rate
	welcome.server_tick = tick
	welcome.map = scene.name
	welcome.map_hash = scene.hash_value()
	welcome.tuning_hash = rules.hash_value()
	welcome.match_seed = match_seed
	if session.conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(welcome)) != OK:
		_drop(session, "welcome not delivered")
		return
	players[player.id] = player
	session.player = player
	if player.team != Game.Team.NONE:
		print("player %d \"%s\" returned" % [player.id, player.name])
	else:
		print("player %d \"%s\" joined" % [player.id, player.name])


## _returning gives a player who comes back with the token of a lost
## connection its place, name and team again. A connection of that player that
## is still open is closed first: two would make a phantom.
func _returning(hello: Messages.Hello) -> ServerPlayer:
	if hello.token.is_empty():
		return null
	for session: Session in sessions.duplicate():
		if session.player != null and session.player.token == hello.token:
			_drop(session, "replaced by a new connection")
			break
	for i in reservations.size():
		var reservation := reservations[i]
		if reservation.token == hello.token:
			reservations.remove_at(i)
			var player := ServerPlayer.new(reservation.id, reservation.name, soldiers.slots())
			player.token = reservation.token
			player.team = reservation.team
			player.kills = reservation.kills
			return player
	return null


## _free_player finds a place that is neither taken nor kept for a return.
func _free_player() -> int:
	for id in settings.max_players:
		if players[id] == null and not _reserved(id):
			return id
	return -1


func _reserved(id: int) -> bool:
	for reservation in reservations:
		if reservation.id == id:
			return true
	return false


func _ready(session: Session) -> void:
	var player := session.player
	if player == null or player.ready:
		return
	player.ready = true
	if not _spawn(player):
		print("player %d could not spawn" % player.id)
		_drop(session, "could not spawn")
	elif flag_match != null:
		flag_match.started = true


## _respawn puts a living soldier back at its spawn with full health and
## magazines; the dead wait for their time. It is a debug aid of solo play:
## elsewhere anyone could heal and refill at will, so it is refused.
func _respawn(session: Session) -> void:
	var player := session.player
	if player == null or player.soldier == 0 or not settings.allow_respawn:
		return
	var soldier := soldiers.get_soldier(player.soldier)
	if not soldier.alive:
		return
	if soldier.vehicle != 0:
		return
	soldier.health = Game.MAX_HEALTH
	soldier.arsenal = Arsenal.create(Arsenal.default_loadout(), rules.weapons)
	player.controller.teleport(soldier, scene.spawn_of(soldier.team))


## _certificate answers a client that asks for the certificate of the
## server before it trusts it; the answer is all such a connection gets.
func _certificate(session: Session) -> void:
	if session.player != null or certificate_pem == "":
		_drop(session, "no certificate to show")
		return
	var answer := Messages.Certificate.new()
	answer.pem = certificate_pem
	session.conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(answer))
	_drop(session, "certificate sent")


## certificate_pem is the certificate clients reach this server with, for
## those that ask before they trust it.
var certificate_pem := ""


func _leave(session: Session, reason: String, by_peer: bool) -> void:
	sessions.erase(session)
	session.conn.close("connection ended")
	var player := session.player
	if player == null:
		return
	if player.soldier != 0:
		vehicles.release(soldiers.get_soldier(player.soldier))
		# Every other player's view of the slot notices the soldier is gone.
		soldiers.remove(player.soldier)
	if player.controller != null:
		player.controller.close()
		player.controller = null
	players[player.id] = null
	var quit := by_peer and reason == Protocol.QUIT_REASON
	if not quit:
		# The connection was lost, not ended: the player may come back with
		# its token. The soldier is gone meanwhile, so no one waits for it.
		var reservation := Reservation.new()
		reservation.id = player.id
		reservation.token = player.token
		reservation.name = player.name
		reservation.team = player.team
		reservation.kills = player.kills
		reservation.until = clock.call() + settings.reconnect_window
		reservations.append(reservation)
	print("player %d \"%s\" left: %s" % [player.id, player.name, reason])
	_reset_finished_round()


## _reject tells the client why before closing. The reason also travels as the
## close reason, in case the message is lost.
func _reject(session: Session, reason: int, message: String) -> void:
	var reject := Messages.Reject.new()
	reject.reason = reason
	reject.message = message
	session.conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(reject))
	_drop(session, message)


func _drop(session: Session, reason: String) -> void:
	session.conn.close(reason)
	_leave(session, reason, false)


## _drop_silent_sessions closes connections that send nothing: no hello in
## time, or no input for the input timeout, which a frozen client or a broken
## link cause before the transport notices. It also forgets players who did
## not return.
func _drop_silent_sessions() -> void:
	var now: float = clock.call()
	for session: Session in sessions.duplicate():
		var player := session.player
		if player == null and now - session.accepted > HELLO_TIMEOUT:
			_drop(session, "no hello in time")
		elif player != null and now - player.last_input > settings.input_timeout:
			_drop(session, "no input in time")


func _expire_reservations() -> void:
	if reservations.is_empty():
		return
	var now: float = clock.call()
	for reservation: Reservation in reservations.duplicate():
		if now > reservation.until:
			print("player %d \"%s\" did not return" % [reservation.id, reservation.name])
			reservations.erase(reservation)


## Retain the result for connected players and those who can reconnect.
## A fresh round waits for the next player to spawn, like the first one did.
func _reset_finished_round() -> void:
	if flag_match == null or flag_match.state.result == MatchState.Result.ACTIVE:
		return
	if not reservations.is_empty() or player_count() != 0:
		return
	flag_match = FlagMatch.new(scene.flags)
	bots.reset_for_round()


# Combat.


## _view_time is the moment a human's shot is tested at (ARCHITECTURE.md,
## 6.9): what the player saw when it fired, no further back than the rewind
## limit, and the latest recorded tick for a player that says it saw now. The
## shooter itself is not moved back.
func _view_time(command: InputCommand) -> float:
	var latest := float(tick - 1)
	if not command.has_view_time():
		return latest
	var oldest := tick - settings.max_rewind * Game.TICK_RATE
	return clampf(command.view_time(), oldest, latest)


## _resolve_shots tests every shot of the tick against the world and the
## soldiers, applies the damage and tells the people involved. The pellets of a
## shotgun that strike one soldier add up into one wound, in the zone the best
## of them struck. A soldier killed in a tick still fires its shot of that
## tick, so two soldiers can kill each other.
func _resolve_shots() -> void:
	if flag_match != null and flag_match.state.result != MatchState.Result.ACTIVE:
		_shots.clear()
		return
	for pending in _shots:
		var shot := pending.shot
		var tuning := rules.weapons.get_tuning(shot.weapon)
		var directions := shot.pellets if not shot.pellets.is_empty() else PackedVector3Array([shot.direction])
		var wounds := {}
		for direction in directions:
			var struck := _hitscan(pending, direction)
			if struck.is_empty():
				continue
			profile.hits += 1
			total_hits += 1
			var victim := soldiers.get_soldier(struck[0])
			if victim == null or not victim.alive or (victim.team == pending.team and not settings.friendly_fire):
				continue
			var zone := Hitboxes.zone_of(struck[1])
			var amount := tuning.hit_damage(zone, struck[2])
			if not wounds.has(victim.id):
				wounds[victim.id] = [0, zone, struck[1], direction]
			var wound: Array = wounds[victim.id]
			wound[0] += amount
			if zone < wound[1]:
				wound[1] = zone
				wound[2] = struck[1]
		for id: int in wounds:
			var victim := soldiers.get_soldier(id)
			var wound: Array = wounds[id]
			victim.hit_count += 1
			victim.hit_box = wound[2]
			victim.hit_yaw = Game.yaw_of(wound[3])
			var taken := damage(victim, wound[0])
			if victim.is_bot() and not taken[1]:
				bots.hurt(victim.bot, pending.shooter)
			tell_hit(pending.shooter, pending.team, shot.weapon, wound[3], victim, wound[1], taken[0], taken[1])
	_shots.clear()


## _hitscan finds the soldier a shot along direction strikes first, as
## [soldier, hitbox, distance], or [] (ARCHITECTURE.md, 6.9): a ray through the
## static world limits its reach, the grid gives the soldiers near its track,
## with a margin for how far they can have moved since the moment of the
## shot, and their hitboxes are tested where the pose history has them at that
## moment. A soldier that did not exist then cannot be hit: the player could
## not see it. A teammate stops a shot even without friendly fire.
func _hitscan(pending: PendingShot, direction: Vector3) -> Array:
	var shot := pending.shot
	var reach := rules.weapons.get_tuning(shot.weapon).range
	var wall := cast_ray(shot.origin, direction, reach, Game.LAYER_STATIC | Game.LAYER_VEHICLE)
	if wall >= 0:
		reach = wall
	# The grid has the soldiers at the end of the last tick; since the moment
	# of the shot they moved at most at a sprint, or a fall.
	var since := (tick - pending.view) / Game.TICK_RATE
	var margin := Hitboxes.REACH + 2 * rules.movement.sprint_speed * since
	var struck := []
	var count := grid.along_ray(shot.origin, direction, reach, margin)
	var ids := grid.ids.duplicate()
	for i in count:
		var id := ids[i]
		var target := soldiers.get_soldier(id)
		# A driver sits inside the armour that stops the shot.
		if id == pending.shooter or target == null or not target.alive or target.vehicle != 0:
			continue
		var pose := history.at(id, pending.view)
		if pose.is_empty() or not pose[2]:
			continue
		var hit := Hitboxes.ray(shot.origin, direction, reach, pose[0], pose[1], pose[3])
		if not hit.is_empty():
			reach = hit[0]
			struck = [id, hit[1], hit[0]]
	return struck


## cast_ray returns how far a ray from origin along the unit direction goes
## before it meets the given layers, no farther than length, or -1. A ray that
## starts inside geometry meets it at once.
func cast_ray(origin: Vector3, direction: Vector3, length: float, mask: int) -> float:
	_ray.from = origin
	_ray.to = origin + direction * length
	_ray.collision_mask = mask
	_ray.hit_from_inside = true
	var hit := _space_state.intersect_ray(_ray)
	if hit.is_empty():
		return -1.0
	return origin.distance_to(hit["position"])


## tell_hit sends the events of a hit by a weapon along a direction: the
## shooter learns it hit, the victim where from, and everyone a death, for the
## kill feed. name is the shooter's, when it may be gone by now.
func tell_hit(by: int, team: int, weapon: int, direction: Vector3, victim: Soldier, zone: int, taken: int, killed: bool, name: String = "") -> void:
	var shooter := soldiers.get_soldier(by)
	var shooter_player := player_of(shooter)
	if shooter_player != null:
		var confirm := Messages.HitConfirm.new()
		confirm.tick = tick
		confirm.victim = victim.id
		confirm.zone = zone
		confirm.damage = mini(taken, 255)
		confirm.killed = killed
		_send_event(shooter_player, confirm)
	var victim_player := player_of(victim)
	if victim_player != null:
		var hurt := Messages.Damage.new()
		hurt.tick = tick
		hurt.attacker = by
		hurt.yaw = roundi(Game.yaw_of(direction) / TAU * 256) & 0xFF
		hurt.zone = zone
		hurt.damage = mini(taken, 255)
		_send_event(victim_player, hurt)
	if not killed:
		return
	if shooter_player != null and team != victim.team:
		shooter_player.kills = mini(shooter_player.kills + 1, MatchState.MAX_KILLS)
	var death := Messages.Death.new()
	death.tick = tick
	death.victim = victim.id
	death.killer = by
	death.victim_team = victim.team
	death.killer_team = team
	death.victim_name = name_of(victim)
	death.killer_name = name if name != "" and shooter == null else name_of(shooter)
	death.weapon = weapon
	death.zone = zone
	send_to_all(death)


func send_to_all(message: Object) -> void:
	for player in players:
		if player != null and player.ready:
			_send_event(player, message)


# Projectiles.


## _launch sends a projectile on its way and tells every player.
func _launch(soldier: Soldier, shot: Shot, tuning: WeaponTuning) -> void:
	var projectile := Projectile.launch(_next_projectile, shot, soldier, tuning, tick)
	_next_projectile = _next_projectile % 0xFFFF + 1
	projectiles.append(projectile)
	_launchers[projectile.id] = name_of(soldier)
	var launch := Messages.Launch.new()
	launch.tick = tick
	launch.projectile = projectile.id
	launch.kind = projectile.kind
	launch.owner = soldier.id
	launch.position = projectile.position
	launch.velocity = projectile.velocity
	send_to_all(launch)


## _move_projectiles moves every projectile for the tick and bursts those that
## reach their end. A rocket also bursts on the first soldier in its way, as
## soldiers are now: no lag compensation for what flies.
func _move_projectiles() -> void:
	for projectile: Projectile in projectiles.duplicate():
		var tuning := rules.weapons.get_tuning(projectile.kind)
		var from := projectile.position
		var burst := projectile.step(_space_state, _ray, tuning, tick)
		if tuning.bounce <= 0:
			var struck := _strike(projectile, from, projectile.position)
			if struck != Vector3.INF:
				projectile.position = struck
				burst = true
		if burst:
			projectiles.erase(projectile)
			_blast(projectile, tuning)


## _strike returns where a projectile moving from one point to another meets
## the hitboxes of a soldier other than its owner first, or Vector3.INF.
func _strike(projectile: Projectile, from: Vector3, to: Vector3) -> Vector3:
	var length := from.distance_to(to)
	if length < 1e-4:
		return Vector3.INF
	var direction := (to - from) / length
	var count := grid.along_ray(from, direction, length, Hitboxes.REACH)
	var ids := grid.ids.duplicate()
	var nearest := length
	for i in count:
		var target := soldiers.get_soldier(ids[i])
		if target == null or not target.alive or target.id == projectile.owner or target.vehicle != 0:
			continue
		var hit := Hitboxes.ray(from, direction, nearest, target.position, target.yaw, target.crouched)
		if not hit.is_empty():
			nearest = hit[0]
	return from + direction * nearest if nearest < length else Vector3.INF


## _blast bursts a projectile: every soldier the blast reaches, not behind
## cover, takes its share of the damage by its distance from the heart, as a
## wound in the torso; teammates are spared without friendly fire, and so is
## the owner. Every player learns where it burst.
func _blast(projectile: Projectile, tuning: WeaponTuning) -> void:
	var at := projectile.position
	var name: String = _launchers.get(projectile.id, "")
	_launchers.erase(projectile.id)
	# A blast after the end of a round only shows, like the shots then.
	var over := flag_match != null and flag_match.state.result != MatchState.Result.ACTIVE
	var count := 0 if over else grid.near(at, tuning.blast_radius + Hitboxes.REACH)
	var ids := grid.ids.duplicate()
	for i in count:
		var victim := soldiers.get_soldier(ids[i])
		if victim == null or not victim.alive or victim.vehicle != 0 or (victim.team == projectile.team and not settings.friendly_fire):
			continue
		var center := victim.position + Vector3(0, CROUCHED_BODY_HEIGHT if victim.crouched else BODY_HEIGHT, 0)
		var distance := at.distance_to(center)
		var share := tuning.blast_share(distance)
		if share <= 0 or not _exposed(at, victim):
			continue
		var direction := (center - at) / distance if distance > 1e-3 else Vector3.UP
		victim.hit_count += 1
		victim.hit_box = Hitboxes.TORSO_BOX
		victim.hit_yaw = Game.yaw_of(direction)
		var taken := damage(victim, maxi(1, roundi(tuning.damage * share)))
		profile.hits += 1
		total_hits += 1
		if victim.is_bot() and not taken[1]:
			bots.hurt(victim.bot, projectile.owner)
		tell_hit(projectile.owner, projectile.team, projectile.kind, direction, victim, Hitboxes.Zone.NONE, taken[0], taken[1], name)
	if not over:
		vehicles.blast(at, tuning, projectile.kind, projectile.owner, projectile.team, name)
	var blast := Messages.Blast.new()
	blast.tick = tick
	blast.projectile = projectile.id
	blast.kind = projectile.kind
	blast.position = at
	send_to_all(blast)


## BODY_HEIGHT is the middle of the body, where a blast is measured to, and
## CHEST_HEIGHT the point above it a blast reaches over low cover; both are
## lower for a crouching soldier.
const BODY_HEIGHT := 0.85
const CHEST_HEIGHT := 1.45
const CROUCHED_BODY_HEIGHT := 0.45
const CROUCHED_CHEST_HEIGHT := 0.7


## _exposed tells whether a blast at a point reaches the body or the chest of
## a soldier past the static world.
func _exposed(at: Vector3, victim: Soldier) -> bool:
	var heights := [CROUCHED_BODY_HEIGHT, CROUCHED_CHEST_HEIGHT] if victim.crouched else [BODY_HEIGHT, CHEST_HEIGHT]
	for height: float in heights:
		var point := victim.position + Vector3(0, height, 0)
		var distance := at.distance_to(point)
		if distance < 1e-3 or cast_ray(at, (point - at) / distance, distance, Game.LAYER_STATIC | Game.LAYER_VEHICLE) < 0:
			return true
	return false


## player_of is the player of a human soldier, or null.
func player_of(soldier: Soldier) -> ServerPlayer:
	if soldier == null or soldier.controller != Game.Controller.PLAYER:
		return null
	var player: ServerPlayer = players[soldier.player]
	if player != null and player.soldier == soldier.id:
		return player
	return null


## name_of is how the kill feed calls a soldier.
func name_of(soldier: Soldier) -> String:
	if soldier == null:
		return "?"
	if soldier.controller == Game.Controller.BOT:
		return Bots.name_of(soldier.bot)
	var player: ServerPlayer = players[soldier.player]
	if player != null:
		return player.name
	return "Player %d" % soldier.player


## _send_event sends an event on the reliable channel. A player who does not
## read its events is dropped: its queue is full.
func _send_event(player: ServerPlayer, message: Object) -> void:
	if player.conn.send_reliable(Conn.Channel.EVENTS, Protocol.encode(message)) != OK:
		print("player %d: event %s not delivered" % [player.id, Protocol.type_name(message.type())])
		player.conn.close("events not delivered")


## damage takes health from a soldier; at zero it dies. A dead soldier stays
## where it fell until it comes back as a new soldier, so that every client
## sees it die. A dead human loses its capsule and its commands are ignored.
## It returns [health taken, died].
func damage(victim: Soldier, amount: int) -> Array:
	if victim.health > amount:
		victim.health -= amount
		return [amount, false]
	var taken := victim.health
	victim.health = 0
	victim.alive = false
	victim.velocity = Vector3.ZERO
	vehicles.release(victim)
	profile.kills += 1
	var back := tick + roundi(settings.respawn_delay * Game.TICK_RATE)
	if victim.controller == Game.Controller.PLAYER:
		var player: ServerPlayer = players[victim.player]
		if player != null and player.soldier == victim.id:
			if player.controller != null:
				player.controller.close()
				player.controller = null
			player.respawn_at = back
	elif victim.controller == Game.Controller.BOT:
		bots.died(victim.bot, back)
	return [taken, true]


## _respawn_dead brings back the soldiers whose time has come: each as a new
## soldier, whom clients do not mistake for the one that died.
func _respawn_dead() -> void:
	_reinforcement_rays = REINFORCEMENT_RAY_BUDGET
	for player in players:
		if player == null or player.soldier == 0:
			continue
		var soldier := soldiers.get_soldier(player.soldier)
		if soldier.alive or tick < player.respawn_at:
			continue
		soldiers.remove(player.soldier)
		player.soldier = 0
		_spawn(player, soldier.position)
	bots.respawn_dead()


## Session is a connection as the simulation sees it. It becomes a player once
## its Hello is accepted.
class Session:
	var conn: Conn
	var accepted: float
	var player: ServerPlayer
	var control_limit := RateLimit.new(CONTROL_RATE, CONTROL_BURST)
	var input_limit := RateLimit.new(INPUT_RATE, INPUT_BURST)

	func _init(connection: Conn, now: float) -> void:
		conn = connection
		accepted = now


## Reservation keeps the place of a player whose connection was lost, for the
## reconnect window.
class Reservation:
	var id := 0
	var token := PackedByteArray()
	var name := ""
	var team := 0
	var until := 0.0
	var kills := 0


## PendingShot is a shot fired this tick, resolved once every soldier has
## acted. view is the moment, as a fractional tick, whose poses the shot is
## tested against.
class PendingShot:
	var shooter: int
	var team: int
	var shot: Shot
	var view: float

	func _init(by: int, side: int, fired: Shot, moment: float) -> void:
		shooter = by
		team = side
		shot = fired
		view = moment
