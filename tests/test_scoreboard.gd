extends TestCase

const Harness := preload("res://tests/harness.gd")


func test_scoreboard_chunks_are_bounded_and_apply_during_streaming() -> void:
	var publisher := ScoreboardPublisher.new()
	var listener := Memory.MemoryListener.new()
	var conn := listener.dial()
	cleanup(func() -> void: listener.close())
	var player := ServerPlayer.new(0, "Scout", 1)
	player.conn = listener.accept()
	player.ready = true
	var subscribers: Array[ServerPlayer] = [player]
	for id in SoldierSet.MAX_SOLDIERS:
		publisher.add(ScoreboardUpdate.Row.new(id, "S".repeat(Protocol.MAX_NAME_BYTES), Game.Team.BLUE))
	publisher.flush(subscribers, 0)
	check(conn.receive_reliable().is_empty(), "normal play does not receive a roster before requesting it")

	publisher.request(player)
	publisher.flush(subscribers, 1)
	var expected := SoldierSet.MAX_SOLDIERS
	publisher.remove(publisher._rows[0])
	publisher.add(ScoreboardUpdate.Row.new(expected, "New participant", Game.Team.RED))
	var revised := publisher._rows[1] as ScoreboardUpdate.Row
	revised.kills = 11
	publisher.mark(revised)
	var received: Dictionary[int, ScoreboardUpdate.Row] = {}
	var completions := 0
	for tick in range(2, 70):
		publisher.flush(subscribers, tick)
		while true:
			var item := conn.receive_reliable()
			if item.is_empty():
				break
			var wire: PackedByteArray = item[1]
			check(wire.size() < Conn.MAX_DATAGRAM_SIZE, "a roster chunk fits one datagram")
			var message := Protocol.decode(wire) as ScoreboardUpdate
			if not check(message != null, "roster chunk decodes"):
				return
			check(message.rows.size() + message.removed.size() <= ScoreboardUpdate.CHUNK_SIZE, "row bound")
			completions += int(message.complete)
			_apply(message, received)
	check_equal(completions, 1, "one completion despite intervening deltas")
	check_equal(received.size(), expected, "all rows received at the maximum match size")
	check(not received.has(0) and received.has(expected), "removed and new IDs reconcile mid-stream")
	check_equal(received[1].kills, 11, "updated early row was delivered")
	check_equal(received[expected - 1].name, "S".repeat(32), "names round-trip at the length limit")

	publisher.request(player)
	revised.kills = 12
	publisher.mark(revised)
	revised.kills = 13
	publisher.mark(revised)
	publisher.flush(subscribers, 72)
	var item := conn.receive_reliable()
	if not check(not item.is_empty(), "one changed row is sent"):
		return
	var delta := Protocol.decode(item[1]) as ScoreboardUpdate
	check(not delta.complete and delta.rows.size() == 1 and delta.rows[0].kills == 13, "updates coalesce")
	check(conn.receive_reliable().is_empty(), "a repeated request does not replay the roster")


func test_authoritative_roster_retains_identity_and_resets_with_the_round() -> void:
	var harness := Harness.new(func(settings: ServerSettings) -> void:
		settings.scene = MapScene.prototype()
		settings.scene.flags = [
			MapScene.Zone.new("A", Vector3(-8, 0, 0), 2),
			MapScene.Zone.new("B", Vector3.ZERO, 2),
			MapScene.Zone.new("C", Vector3(8, 0, 0), 2),
		]
		settings.bots = 2
		settings.bot_ai = false
		settings.respawn_delay = 0.05)
	cleanup(func() -> void: harness.close())
	var server := harness.server
	var first := harness.join("Scout")
	var peer := harness.join("Scout")
	var first_id := first.welcome.player
	var peer_id := peer.welcome.player
	var blue_bot := Game.MAX_PLAYERS
	var red_bot := blue_bot + 1
	first.send(Messages.ScoreboardRequest.new())
	peer.send(Messages.ScoreboardRequest.new())
	harness.step(7)
	var first_rows := _roster(first)
	var peer_rows := _roster(peer)
	check_equal(first_rows.size(), 4, "both human and bot rows are present")
	check_equal(_signature(first_rows), _signature(peer_rows), "both views agree")
	check_equal(first_rows[first_id].name, first_rows[peer_id].name, "duplicate names have distinct IDs")
	var first_soldier := harness.player(first).soldier
	var peer_soldier := harness.player(peer).soldier
	_kill(server, first_soldier, peer_soldier)
	_kill(server, first_soldier, server.bots.bots[0].soldier)
	harness.step(7)
	_kill(server, server.bots.bots[1].soldier, first_soldier)
	var respawned := harness.player(peer).soldier
	check(respawned != peer_soldier, "death changed the soldier ID")
	var victim := server.soldiers.get_soldier(respawned)
	server.damage(victim, Game.MAX_HEALTH)
	server.damage(victim, Game.MAX_HEALTH)
	harness.step(7)
	first_rows = _roster(first)
	check_equal(_signature(first_rows), _signature(_roster(peer)), "damage deltas agree")
	check_equal(_kd(first_rows, first_id), Vector2i(1, 1), "enemy kill and bot death")
	check_equal(_kd(first_rows, peer_id), Vector2i(0, 2), "combat and unattributed deaths counted once each")
	check_equal(_kd(first_rows, blue_bot), Vector2i(0, 1), "friendly death grants no kill")
	check_equal(_kd(first_rows, red_bot), Vector2i(1, 0), "bot kill is counted")

	var original := harness.player(first).score
	first.conn.close("lost link")
	harness.step(7)
	check(not _roster(peer).has(first_id), "disconnected row is removed")
	var returned := harness.join("new typed name", first.welcome.session_token)
	check_equal(harness.player(returned).score, original, "reconnect kept its participant identity")
	returned.send(Messages.ScoreboardRequest.new())
	harness.step(7)
	check_equal(_kd(_roster(returned), first_id), Vector2i(1, 1), "returning client gets previous round totals")
	check_equal(_signature(_roster(returned)), _signature(_roster(peer)), "reconnect restores the row for peers")

	var old_soldier_id := harness.player(returned).soldier
	returned.conn.close(Protocol.QUIT_REASON)
	harness.step(7)
	var replacement := harness.join("Scout")
	replacement.send(Messages.ScoreboardRequest.new())
	var other := server.soldiers.get_soldier(harness.player(peer).soldier)
	var damage := server.damage(other, Game.MAX_HEALTH)
	server.tell_hit(old_soldier_id, original.team, WeaponTuning.Kind.GRENADE, Vector3.FORWARD, other,
		Hitboxes.Zone.NONE, damage[0], damage[1], original)
	harness.step(7)
	check_equal(_kd(_roster(replacement), first_id), Vector2i.ZERO, "late projectile cannot score for a reused slot")
	check_equal(original.kills, 2, "projectile keeps its original participant credit")

	server.flag_match.state.result = MatchState.Result.BLUE
	replacement.conn.close(Protocol.QUIT_REASON)
	peer.conn.close(Protocol.QUIT_REASON)
	harness.step(7)
	var fresh := harness.join("Scout")
	fresh.send(Messages.ScoreboardRequest.new())
	harness.step(7)
	var rows := _roster(fresh)
	check_equal(rows.size(), 3, "fresh round contains the new player and both bots")
	for id in rows:
		check_equal(_kd(rows, id), Vector2i.ZERO, "fresh round reset every row")


func _kill(server: Server, shooter_id: int, victim_id: int) -> void:
	var shooter := server.soldiers.get_soldier(shooter_id)
	var victim := server.soldiers.get_soldier(victim_id)
	var damage := server.damage(victim, Game.MAX_HEALTH)
	server.tell_hit(shooter_id, shooter.team, WeaponTuning.Kind.ASSAULT_RIFLE, Vector3.FORWARD, victim,
		Hitboxes.Zone.TORSO, damage[0], damage[1])


func _roster(client: Harness.Client) -> Dictionary[int, ScoreboardUpdate.Row]:
	var result: Dictionary[int, ScoreboardUpdate.Row] = {}
	for event in client.events:
		if event is ScoreboardUpdate:
			_apply(event, result)
	return result


func _apply(update: ScoreboardUpdate, table: Dictionary[int, ScoreboardUpdate.Row]) -> void:
	for id in update.removed:
		table.erase(id)
	for row in update.rows:
		table[row.id] = row


func _kd(table: Dictionary[int, ScoreboardUpdate.Row], id: int) -> Vector2i:
	var row: ScoreboardUpdate.Row = table.get(id)
	return Vector2i(row.kills, row.deaths) if row != null else Vector2i(-1, -1)


func _signature(table: Dictionary[int, ScoreboardUpdate.Row]) -> Dictionary:
	var result := {}
	for row in table.values():
		result[row.id] = [row.name, row.team, row.kills, row.deaths]
	return result
