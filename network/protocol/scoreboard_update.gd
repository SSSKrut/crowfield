class_name ScoreboardUpdate
extends RefCounted
## A bounded reliable roster chunk. The first complete flag ends the initial
## stream; later messages update or remove participants by stable ID.

const CHUNK_SIZE := 24
const ID_BITS := 13
const COUNT_BITS := 5
const ID_LIMIT := Game.MAX_PLAYERS + SoldierSet.MAX_SOLDIERS

var complete := false
var rows: Array[Row] = []
var removed := PackedInt32Array()


func type() -> int:
	return Protocol.Type.SCOREBOARD_UPDATE


func write(w: BitWriter) -> String:
	if rows.size() + removed.size() > CHUNK_SIZE:
		return "scoreboard chunk is too large"
	var seen := {}
	for row in rows:
		if not _valid(row.id, seen) or row.team < Game.Team.BLUE or row.team > Game.Team.RED \
				or row.kills < 0 or row.kills > MatchState.MAX_KILLS or row.deaths < 0 or row.deaths > MatchState.MAX_KILLS:
			return "invalid scoreboard row"
		var error := Protocol.check_text("scoreboard name", row.name, Protocol.MAX_NAME_BYTES)
		if error != "":
			return error
	for id in removed:
		if not _valid(id, seen):
			return "invalid scoreboard removal"
	w.write_bool(complete)
	w.write_bits(rows.size(), COUNT_BITS)
	w.write_bits(removed.size(), COUNT_BITS)
	for row in rows:
		w.write_bits(row.id, ID_BITS)
		w.write_bits(row.team, Protocol.TEAM_BITS)
		w.write_bits(row.kills, 16)
		w.write_bits(row.deaths, 16)
		w.write_string(row.name, Protocol.NAME_LENGTH_BITS)
	for id in removed:
		w.write_bits(id, ID_BITS)
	return ""


func read(r: BitReader) -> void:
	complete = r.read_bool()
	var row_count := r.read_bits(COUNT_BITS)
	var remove_count := r.read_bits(COUNT_BITS)
	rows.clear()
	removed.clear()
	if row_count + remove_count > CHUNK_SIZE:
		r.fail("scoreboard chunk is too large")
		return
	var seen := {}
	for index in row_count:
		var id := r.read_bits(ID_BITS)
		var team := r.read_bits(Protocol.TEAM_BITS)
		var kills := r.read_bits(16)
		var deaths := r.read_bits(16)
		var name := r.read_string(Protocol.NAME_LENGTH_BITS, Protocol.MAX_NAME_BYTES)
		if not _valid(id, seen) or team < Game.Team.BLUE or team > Game.Team.RED:
			r.fail("invalid scoreboard row")
		var row := Row.new(id, name, team)
		row.kills = kills
		row.deaths = deaths
		rows.append(row)
	for index in remove_count:
		var id := r.read_bits(ID_BITS)
		if not _valid(id, seen):
			r.fail("invalid scoreboard removal")
		removed.append(id)


static func _valid(id: int, seen: Dictionary) -> bool:
	if id < 0 or id >= ID_LIMIT or seen.has(id):
		return false
	seen[id] = true
	return true


## Human IDs are player slots; bot IDs start after the last human slot.
## A new human in a reused slot has a new Row object on the server.
class Row:
	var id: int
	var name: String
	var team: int
	var kills := 0
	var deaths := 0

	func _init(participant: int, display_name: String, side: int) -> void:
		id = participant
		name = display_name
		team = side

	func is_bot() -> bool:
		return id >= Game.MAX_PLAYERS
