extends TestCase

const FiringRange := preload("res://tests/firing_range.gd")
const Harness := preload("res://tests/harness.gd")


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
	range.fire(Vector3(0, 1.64, -1))
	range.fire(Vector3(0, 1.64, -1))
	check_equal(range.health(target), 0, "headshots kill the target")
	if check(range.client.snapshot.match_state != null and guest.snapshot.match_state != null, "both clients receive match state"):
		check_equal(range.client.snapshot.match_state.kills, 1, "the shooter receives the kill")
		check_equal(guest.snapshot.match_state.kills, 0, "the second player does not receive credit")
	var returning := range.join("shooter", range.client.welcome.session_token)
	range.step(4)
	check_equal(returning.snapshot.match_state.kills, 1, "the counter survives reconnecting")


func test_finished_flag_match_remains_until_the_last_player_leaves() -> void:
	var harness := _valley_harness()
	var first := harness.join("first")
	var second := harness.join("second")
	var server := harness.server
	var state := server.flag_match.state
	state.result = MatchState.Result.BLUE
	state.blue_score = MatchState.SCORE_TO_WIN
	state.flags[0].owner = Game.Team.BLUE
	var old_bot := server.bots.bots[0].soldier

	first.conn.close(Protocol.QUIT_REASON)
	harness.step(4)
	check_equal(second.snapshot.match_state.result, MatchState.Result.BLUE, "the remaining player sees the result")
	second.conn.close("connection lost")
	harness.step(4)
	check_equal(server.flag_match.state.result, MatchState.Result.BLUE, "keep the result during the reconnect window")

	var returned := harness.join("second", second.welcome.session_token)
	harness.step(4)
	check_equal(returned.snapshot.match_state.result, MatchState.Result.BLUE, "the returning player sees the result")
	returned.conn.close(Protocol.QUIT_REASON)
	harness.step()
	check(server.soldiers.get_soldier(old_bot) == null, "the old bot soldier was replaced")
	_check_fresh_round(harness)


func test_finished_flag_match_resets_after_the_reconnect_window() -> void:
	var harness := _valley_harness()
	var player := harness.join("player")
	harness.server.flag_match.state.result = MatchState.Result.RED
	harness.server.flag_match.state.red_score = MatchState.SCORE_TO_WIN

	player.conn.close("connection lost")
	harness.step()
	check_equal(harness.server.flag_match.state.result, MatchState.Result.RED, "pending reconnect holds the result")
	harness.step(20)
	_check_fresh_round(harness)


func test_valley_human_deploys_at_home_then_reinforces_from_held_ground() -> void:
	var harness := _reinforcement_harness()
	var server := harness.server
	var ford := server.scene.flags[1]
	var flag := server.flag_match.state.flags[1]
	for team: int in [Game.Team.BLUE, Game.Team.RED]:
		flag.owner = team
		var client := harness.join(Game.team_name(team))
		var player := harness.player(client)
		var home := server.scene.spawn_of(team)
		var initial := server.soldiers.get_soldier(player.soldier)
		check_equal(initial.team, team, "the players join opposite teams")
		check(Game.horizontal_length(initial.position - home) < 6.0, "first deployment starts at home even with a held flag")
		var old_id := initial.id
		var returned := _return_after_death(harness, player)
		check(returned.id != old_id and returned.alive, "reinforcement creates a fresh living soldier")
		check(Game.horizontal_length(returned.position - ford.center) < 30.0, "holding the ford shortens the return")
		check(signf(returned.position.z - ford.center.z) == signf(home.z - ford.center.z), "reinforcement is on the home bank")
		check(not ford.contains_flag_position(returned.position), "reinforcements do not spawn in the capture area")
		player.controller.teleport(returned, home)


func test_valley_reinforcements_fall_back_for_challenged_flags_and_nearby_enemies() -> void:
	var harness := _reinforcement_harness()
	var server := harness.server
	var blue := harness.player(harness.join("blue"))
	var red := harness.player(harness.join("red"))
	var enemy := server.soldiers.get_soldier(red.soldier)
	var home := server.scene.spawn_of(blue.team)
	var ford := server.scene.flags[1]
	var flag := server.flag_match.state.flags[1]
	flag.owner = blue.team

	# Opponents can block a reinforcement without standing inside the flag.
	var exposed := ford.center + Vector3(0, 0, 20)
	exposed.y = server.scene.ground_at(exposed.x, exposed.z)
	red.controller.teleport(enemy, exposed)
	var returned := _return_after_death(harness, blue)
	check(Game.horizontal_length(returned.position - home) < 6.0, "nearby enemies force a home deployment")
	check(not flag.contested and flag.challenger == Game.Team.NONE, "hostile proximity is independent of capture pressure")

	# A recently challenged flag is unsafe even if the attacker just died.
	red.controller.teleport(enemy, server.scene.spawn_of(red.team))
	flag.challenger = red.team
	server.flag_match._capture_ticks[1] = Game.TICK_RATE
	returned = _return_after_death(harness, blue)
	check(Game.horizontal_length(returned.position - home) < 6.0, "an actively challenged crossing is unavailable")


func _reinforcement_harness() -> Harness:
	var harness := Harness.new(func(settings: ServerSettings) -> void:
		settings.map = "valley"
		settings.respawn_delay = 0.1)
	cleanup(func() -> void: harness.close())
	return harness


static func _return_after_death(harness: Harness, player: ServerPlayer) -> Soldier:
	var server := harness.server
	var soldier := server.soldiers.get_soldier(player.soldier)
	server.damage(soldier, Game.MAX_HEALTH)
	harness.step(Game.seconds_to_ticks(server.settings.respawn_delay) + 1)
	return server.soldiers.get_soldier(player.soldier)


func _valley_harness() -> Harness:
	var harness := Harness.new(func(settings: ServerSettings) -> void:
		settings.map = "valley"
		settings.bots = 2
		settings.reconnect_window = 0.25)
	cleanup(func() -> void: harness.close())
	return harness


func _check_fresh_round(harness: Harness) -> void:
	var round := harness.server.flag_match
	check(not round.started, "the fresh round waits for a player")
	check_equal(round.state.result, MatchState.Result.ACTIVE, "a fresh round can be played")
	check_equal(round.state.seconds, MatchState.DURATION_SECONDS, "the full round time is restored")
	check_equal(round.state.blue_score + round.state.red_score, 0, "scores are cleared")
	for flag in round.state.flags:
		check_equal(flag.owner, Game.Team.NONE, "ownership is cleared")
	var next := harness.join("next")
	harness.step(4)
	check(round.started, "the next player starts the fresh round")
	check_equal(next.snapshot.match_state.result, MatchState.Result.ACTIVE, "the next player receives the new round")


func test_valley_bot_casualties_reinforce_only_safe_local_ground() -> void:
	var settings := ServerSettings.new()
	settings.map = "valley"
	settings.bots = 2
	settings.bot_ai = false
	settings.seed = 9
	settings.respawn_delay = 0.001
	var server: Server = Server.create(settings, Rules.new())
	cleanup(func() -> void: server.close())
	server.flag_match.started = true
	var blue := server.bots.bots[0]
	var red := server.bots.bots[1]
	var ford := server.scene.flags[1]
	var flag := server.flag_match.state.flags[1]
	var home := server.scene.spawn_of(Game.Team.BLUE)
	var soldier := server.soldiers.get_soldier(blue.soldier)
	check(Game.horizontal_length(soldier.position - home) < 6.0, "initial bot deployment starts at home")
	flag.owner = Game.Team.BLUE

	var away := _return_bot_after_death(server, blue, server.scene.flags[0].center)
	check(Game.horizontal_length(away.position - home) < 6.0, "a casualty in another lane returns to base")

	var returned := _return_bot_after_death(server, blue, ford.center)
	check(Game.horizontal_length(returned.position - ford.center) < Bots.REINFORCEMENT_RANGE, "a local casualty returns near the held ford")
	check(signf(returned.position.z - ford.center.z) == signf(home.z - ford.center.z), "reinforcement stays on the home bank")
	check(not ford.contains_flag_position(returned.position), "reinforcement cannot spawn inside the capture area")

	flag.contested = true
	returned = _return_bot_after_death(server, blue, ford.center)
	check(Game.horizontal_length(returned.position - home) < 6.0, "contested ground forces the bot back to base")

	var enemy := server.soldiers.get_soldier(red.soldier)
	enemy.position = ford.center + Vector3(0, 0, 20)
	returned = _return_bot_after_death(server, blue, ford.center)
	check(Game.horizontal_length(returned.position - home) < 6.0, "an enemy near the site forces the bot back to base")


static func _return_bot_after_death(server: Server, bot: Bots.Bot, at: Vector3) -> Soldier:
	var soldier := server.soldiers.get_soldier(bot.soldier)
	soldier.position = at
	server.damage(soldier, Game.MAX_HEALTH)
	server.step()
	return server.soldiers.get_soldier(bot.soldier)


func test_valley_bots_fight_for_all_crossings_in_the_opening() -> void:
	var settings := ServerSettings.new()
	settings.map = "valley"
	settings.bots = 24
	settings.seed = 9
	var server: Server = Server.create(settings, Rules.new())
	cleanup(func() -> void: server.close())
	var first_bot := server.soldiers.at(0)
	var rally_position := first_bot.position
	for tick in Game.TICK_RATE / 2:
		server.step()
	check_equal(first_bot.position, rally_position, "the squad waits while the player is connecting")
	server.flag_match.started = true
	var approached := [false, false, false]
	var contested := false
	var captured := false
	for tick in 20 * Game.TICK_RATE:
		server.step()
		for index in server.flag_match.state.flags.size():
			var flag := server.flag_match.state.flags[index]
			approached[index] = approached[index] or flag.contested or flag.progress > 0 or flag.owner != Game.Team.NONE
			contested = contested or flag.contested
			captured = captured or flag.owner != Game.Team.NONE
		if not approached.has(false) and contested and captured:
			return
	check(not approached.has(false), "both bridges and the ford all see activity within the opening")
	check(contested, "enemy squads contest a flag within the opening")
	check(captured, "some squad secures territory within the opening")


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
