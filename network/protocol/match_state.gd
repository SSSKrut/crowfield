class_name MatchState
extends RefCounted
## The public state of a Valley round plus the receiving player's kills.

const SCORE_TO_WIN := 120
const DURATION_SECONDS := 8 * 60
const MAX_KILLS := 65535
const FLAG_COUNT := 3

enum Result { ACTIVE, BLUE, RED, DRAW }

var blue_score := 0
var red_score := 0
var seconds := DURATION_SECONDS
var result: Result = Result.ACTIVE
var kills := 0
var flags: Array[Flag] = []


func _init() -> void:
	for index in FLAG_COUNT:
		flags.append(Flag.new())


## The snapshot shares the round's flag records during encoding. Its kills
## belong to the receiving player and are kept separately from those records.
func set_round(round_state: MatchState) -> void:
	blue_score = round_state.blue_score
	red_score = round_state.red_score
	seconds = round_state.seconds
	result = round_state.result
	flags = round_state.flags


func validate() -> String:
	if blue_score < 0 or blue_score > SCORE_TO_WIN or red_score < 0 or red_score > SCORE_TO_WIN:
		return "match score out of range"
	if seconds < 0 or seconds > DURATION_SECONDS or kills < 0 or kills > MAX_KILLS:
		return "match totals out of range"
	if result < Result.ACTIVE or result > Result.DRAW:
		return "match result out of range"
	if flags.size() != FLAG_COUNT:
		return "wrong number of flags"
	for flag in flags:
		if flag.owner < Game.Team.NONE or flag.owner > Game.Team.RED or flag.challenger < Game.Team.NONE or flag.challenger > Game.Team.RED:
			return "flag team out of range"
		if flag.progress < 0 or flag.progress > 100:
			return "flag progress out of range"
	return ""


func bits() -> int:
	return 2 * 7 + 9 + 2 + 16 + FLAG_COUNT * Flag.BITS


func write(writer: BitWriter) -> void:
	writer.write_bits(blue_score, 7)
	writer.write_bits(red_score, 7)
	writer.write_bits(seconds, 9)
	writer.write_bits(result, 2)
	writer.write_bits(kills, 16)
	for flag in flags:
		writer.write_bits(flag.owner, Protocol.TEAM_BITS)
		writer.write_bits(flag.challenger, Protocol.TEAM_BITS)
		writer.write_bits(flag.progress, 7)
		writer.write_bits(int(flag.contested), 1)


func read(reader: BitReader) -> void:
	blue_score = reader.read_bits(7)
	red_score = reader.read_bits(7)
	seconds = reader.read_bits(9)
	result = reader.read_bits(2) as Result
	kills = reader.read_bits(16)
	for flag in flags:
		flag.owner = reader.read_bits(Protocol.TEAM_BITS)
		flag.challenger = reader.read_bits(Protocol.TEAM_BITS)
		flag.progress = reader.read_bits(7)
		flag.contested = reader.read_bool()
	var error := validate()
	if error != "":
		reader.fail(error)


class Flag:
	const BITS := 2 * Protocol.TEAM_BITS + 7 + 1

	var owner := Game.Team.NONE
	var challenger := Game.Team.NONE
	## Progress towards changing ownership, in percent.
	var progress := 0
	var contested := false
