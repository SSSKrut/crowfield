class_name FlagMatch
extends RefCounted
## The authoritative round state. A living team alone in a flag area can
## capture it. Opponents stall the capture and deny its score while contesting.

const CAPTURE_TICKS := 4 * Game.TICK_RATE

var zones: Array[MapScene.Zone]
var state := MatchState.new()
var started := false
var _elapsed := 0
var _capture_ticks := PackedInt32Array()


func _init(flag_zones: Array[MapScene.Zone]) -> void:
	zones = flag_zones
	_capture_ticks.resize(zones.size())


func step(soldiers: SoldierSet, grid: SoldierGrid) -> void:
	if not started or state.result != MatchState.Result.ACTIVE:
		return
	for index in zones.size():
		_update_flag(index, soldiers, grid)
	_elapsed += 1
	if _elapsed % Game.TICK_RATE == 0:
		_score()


func _update_flag(index: int, soldiers: SoldierSet, grid: SoldierGrid) -> void:
	var zone := zones[index]
	var presence := 0
	var count := grid.near(zone.center, zone.radius)
	for candidate in count:
		var soldier := soldiers.get_soldier(grid.ids[candidate])
		if soldier.alive and soldier.team != Game.Team.NONE and zone.contains_flag_position(soldier.position):
			presence |= 1 << soldier.team
	var flag := state.flags[index]
	flag.contested = presence == ((1 << Game.Team.BLUE) | (1 << Game.Team.RED))
	if flag.contested:
		return
	var team := Game.Team.NONE
	if presence != 0:
		team = Game.Team.BLUE if presence == (1 << Game.Team.BLUE) else Game.Team.RED
	if team == Game.Team.NONE or team == flag.owner:
		_capture_ticks[index] = maxi(0, _capture_ticks[index] - 1)
	elif team != flag.challenger:
		flag.challenger = team
		_capture_ticks[index] = 1
	else:
		_capture_ticks[index] += 1
	if _capture_ticks[index] >= CAPTURE_TICKS:
		flag.owner = flag.challenger
		_capture_ticks[index] = 0
	if _capture_ticks[index] == 0:
		flag.challenger = Game.Team.NONE
	flag.progress = 100 * _capture_ticks[index] / CAPTURE_TICKS


func _score() -> void:
	for flag in state.flags:
		if flag.contested:
			continue
		match flag.owner:
			Game.Team.BLUE:
				state.blue_score = mini(state.blue_score + 1, MatchState.SCORE_TO_WIN)
			Game.Team.RED:
				state.red_score = mini(state.red_score + 1, MatchState.SCORE_TO_WIN)
	state.seconds -= 1
	if state.seconds > 0 and maxi(state.blue_score, state.red_score) < MatchState.SCORE_TO_WIN:
		return
	if state.blue_score > state.red_score:
		state.result = MatchState.Result.BLUE
	elif state.red_score > state.blue_score:
		state.result = MatchState.Result.RED
	else:
		state.result = MatchState.Result.DRAW
