class_name ScoreboardPublisher
extends RefCounted
## Participants retain their row through respawns. A ready client requests
## the roster once per connection. Initial chunks are paced independently
## per client, and subsequent reliable changes are coalesced by row ID.

const CHUNKS_PER_TICK := 3
const DELTA_INTERVAL := 6

var _rows: Dictionary[int, ScoreboardUpdate.Row] = {}
var _dirty: Dictionary[int, bool] = {}


func add(row: ScoreboardUpdate.Row) -> void:
	_rows[row.id] = row
	_dirty[row.id] = true


func remove(row: ScoreboardUpdate.Row) -> void:
	if row != null and _rows.get(row.id) == row:
		_rows.erase(row.id)
		_dirty[row.id] = true


func mark(row: ScoreboardUpdate.Row) -> void:
	if _rows.get(row.id) == row:
		_dirty[row.id] = true


func request(player: ServerPlayer) -> void:
	if player == null or not player.ready or player.scoreboard_subscribed:
		return
	player.scoreboard_subscribed = true
	player.scoreboard_pending = PackedInt32Array(_rows.keys())
	player.scoreboard_cursor = 0


func flush(players: Array[ServerPlayer], tick: int) -> void:
	var subscribers: Array[ServerPlayer] = []
	for player in players:
		if player != null and player.scoreboard_subscribed:
			subscribers.append(player)
	if subscribers.is_empty():
		_dirty.clear()
		return
	for player in subscribers:
		_send_initial(player)
	if _dirty.is_empty() or tick % DELTA_INTERVAL != 0:
		return
	var delta := ScoreboardUpdate.new()
	var keys := _dirty.keys()
	for index in mini(keys.size(), CHUNKS_PER_TICK * ScoreboardUpdate.CHUNK_SIZE):
		var id: int = keys[index]
		var row: ScoreboardUpdate.Row = _rows.get(id)
		if row != null:
			delta.rows.append(row)
		else:
			delta.removed.append(id)
		_dirty.erase(id)
		if delta.rows.size() + delta.removed.size() == ScoreboardUpdate.CHUNK_SIZE:
			_broadcast(subscribers, delta)
			delta = ScoreboardUpdate.new()
	if not delta.rows.is_empty() or not delta.removed.is_empty():
		_broadcast(subscribers, delta)


func _send_initial(player: ServerPlayer) -> void:
	if player.scoreboard_cursor < 0:
		return
	var count := player.scoreboard_pending.size()
	for index in CHUNKS_PER_TICK:
		var update := ScoreboardUpdate.new()
		var end := mini(count, player.scoreboard_cursor + ScoreboardUpdate.CHUNK_SIZE)
		for cursor in range(player.scoreboard_cursor, end):
			var row: ScoreboardUpdate.Row = _rows.get(player.scoreboard_pending[cursor])
			if row != null:
				update.rows.append(row)
		player.scoreboard_cursor = end
		update.complete = end == count
		_send(player, Protocol.encode(update))
		if update.complete:
			player.scoreboard_pending.clear()
			player.scoreboard_cursor = -1
			break


func _broadcast(subscribers: Array[ServerPlayer], update: ScoreboardUpdate) -> void:
	var data := Protocol.encode(update)
	for player in subscribers:
		_send(player, data)


func _send(player: ServerPlayer, data: PackedByteArray) -> void:
	if player.conn.send_reliable(Conn.Channel.EVENTS, data) != OK:
		player.conn.close("scoreboard update not delivered")
