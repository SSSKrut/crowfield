extends TestCase

const FiringRange := preload("res://tests/firing_range.gd")


func test_flag_capture_contest_and_result() -> void:
	var scene := MapScene.named("valley")
	var round := FlagMatch.new(scene.flags)
	var soldiers := SoldierSet.new(2)
	var grid := SoldierGrid.new(4.0)
	var bridge := scene.flags[0]
	var blue := _soldier(soldiers, Game.Team.BLUE, bridge.center)
	var red := _soldier(soldiers, Game.Team.RED, bridge.center - Vector3(0, 2.5, 0))
	var flag := round.state.flags[0]

	_step(round, soldiers, grid, FlagMatch.CAPTURE_TICKS)
	check_equal(flag.owner, Game.Team.NONE, "flags stay neutral while waiting for a player")
	round.started = true
	_step(round, soldiers, grid, FlagMatch.CAPTURE_TICKS / 2)
	check_equal(flag.progress, 50, "the soldier below the bridge cannot contest")
	red.position = bridge.center
	_step(round, soldiers, grid, Game.TICK_RATE)
	check(flag.contested, "both teams on the deck contest the flag")
	check_equal(flag.progress, 50, "a contest stalls capture")
	red.alive = false
	_step(round, soldiers, grid, FlagMatch.CAPTURE_TICKS / 2)
	check_equal(flag.owner, Game.Team.BLUE, "only the living Blue soldier captures")
	check_equal(round.state.blue_score, 1, "the point scores for its owner")
	red.alive = true
	_step(round, soldiers, grid, Game.TICK_RATE)
	check_equal(round.state.blue_score, 1, "a contested flag does not score")

	blue.alive = false
	_step(round, soldiers, grid, FlagMatch.CAPTURE_TICKS)
	check_equal(flag.owner, Game.Team.RED, "Red can take the point from Blue")
	round.state.red_score = MatchState.SCORE_TO_WIN - 1
	_step(round, soldiers, grid, Game.TICK_RATE)
	check_equal(round.state.result, MatchState.Result.RED, "reaching the score target ends the match")
	var remaining := round.state.seconds
	_step(round, soldiers, grid, Game.TICK_RATE)
	check_equal(round.state.seconds, remaining, "the match clock freezes at the result")


func test_flag_match_handles_tied_scores_when_time_expires() -> void:
	var round := FlagMatch.new(MapScene.named("valley").flags)
	round.started = true
	round.state.seconds = 1
	var soldiers := SoldierSet.new(1)
	var grid := SoldierGrid.new(4.0)
	_step(round, soldiers, grid, Game.TICK_RATE)
	check_equal(round.state.seconds, 0, "the timer reaches zero")
	check_equal(round.state.result, MatchState.Result.DRAW, "equal scores at time expire result in a draw")


func test_flag_match_kills_sent_to_the_shooter_only() -> void:
	var range := FiringRange.new(func(settings: ServerSettings) -> void:
		settings.scene = MapScene.prototype()
		settings.scene.flags = [
			MapScene.Zone.new("A", Vector3(-8, 0, 0), 2),
			MapScene.Zone.new("B", Vector3.ZERO, 2),
			MapScene.Zone.new("C", Vector3(8, 0, 0), 2),
		])
	cleanup(func() -> void: range.close())
	var guest := range.join("guest")
	var target := range.target(Game.Team.RED, Vector3(0, 0, -1))
	range.step(2)
	range.fire(Vector3(0, 1.5, -1))
	range.fire(Vector3(0, 1.5, -1))
	check_equal(range.health(target), 0, "headshots kill the target")
	if check(range.client.snapshot.match_state != null and guest.snapshot.match_state != null, "both clients receive match state"):
		check_equal(range.client.snapshot.match_state.kills, 1, "the shooter receives the kill")
		check_equal(guest.snapshot.match_state.kills, 0, "the second player does not receive credit")
	var returning := range.join("shooter", range.client.welcome.session_token)
	range.step(4)
	check_equal(returning.snapshot.match_state.kills, 1, "the counter survives reconnecting")


func test_valley_bots_capture_a_flag() -> void:
	var settings := ServerSettings.new()
	settings.map = "valley"
	settings.bots = 24
	settings.seed = 9
	var server: Server = Server.create(settings, Rules.new())
	cleanup(func() -> void: server.close())
	server.flag_match.started = true
	for tick in 65 * Game.TICK_RATE:
		server.step()
		if server.flag_match.state.blue_score + server.flag_match.state.red_score > 0:
			return
	fail("no team held a flag and scored in 65 s")


static func _soldier(soldiers: SoldierSet, team: int, position: Vector3) -> Soldier:
	var soldier := Soldier.new()
	soldier.alive = true
	soldier.team = team
	soldier.position = position
	soldiers.add(soldier)
	return soldier


static func _step(round: FlagMatch, soldiers: SoldierSet, grid: SoldierGrid, ticks: int) -> void:
	grid.rebuild(soldiers)
	for tick in ticks:
		round.step(soldiers, grid)
