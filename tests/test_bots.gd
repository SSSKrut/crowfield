extends TestCase
## Bots: they shoot an enemy they see and nothing they do not, spare their
## team, answer a shot from behind, and fight a battle on the valley without
## leaving the ground or getting stuck.

const FiringRange := preload("res://tests/firing_range.gd")


## _server runs bots on a floor 30 m across, with a wall 3 m tall across the
## middle when walled.
func _server(bots: int, walled: bool) -> Server:
	var scene := MapScene.new()
	scene.name = "test"
	scene.play_area = 14.0
	scene.set_zone(Game.Team.BLUE, Vector3(0, 0, 10), 0)
	scene.set_zone(Game.Team.RED, Vector3(0, 0, -10), 0)
	scene.add_box(Vector3(15, 0.25, 15), Vector3(0, -0.25, 0))
	if walled:
		scene.add_box(Vector3(6, 1.5, 0.2), Vector3(0, 1.5, 0))
	scene.objectives.append(MapScene.Zone.new("floor", Vector3.ZERO, 10))
	var settings := ServerSettings.new()
	settings.scene = scene
	settings.bots = bots
	settings.seed = 2
	var server: Server = Server.create(settings, Rules.new())
	server.clock = server.tick_time
	cleanup(func() -> void: server.close())
	return server


func test_bot_death_attempts_are_bounded_per_tick() -> void:
	var server := _server(1, false)
	server.settings.bot_deaths = 1e30
	server.bots.kill()
	var bot := server.soldiers.get_soldier(server.bots.bots[0].soldier)
	check(not bot.alive, "the bot did not die at the configured debug rate")


static func _steps(server: Server, ticks: int) -> void:
	for i in ticks:
		server.step()


## _place stands bot i at a point looking at another, and keeps it there.
func _place(server: Server, i: int, at: Vector3, look_at: Vector3) -> Soldier:
	var bot := server.bots.bots[i]
	var soldier := server.soldiers.get_soldier(bot.soldier)
	soldier.position = at
	soldier.yaw = Game.yaw_of(look_at - at)
	bot.path = PackedVector3Array()
	bot.linger_until = server.tick + 100000
	bot.think_at = server.tick
	return soldier


## Two bots of each team that see each other across the floor shoot until one
## of them is dead.
func test_bots_shoot_an_enemy_they_see() -> void:
	var server := _server(2, false)
	var blue := _place(server, 0, Vector3(0, 0, 8), Vector3(0, 0, -8))
	var red := _place(server, 1, Vector3(0, 0, -8), Vector3(0, 0, 8))
	check(blue.team != red.team, "the two bots are on one team")
	for i in 6 * Game.TICK_RATE:
		server.step()
		if not blue.alive or not red.alive:
			server.step()
			break
	check(server.total_hits > 0, "no bot hit the other in 6 s")
	check(not blue.alive or not red.alive, "both bots live after 6 s: health %d and %d" % [blue.health, red.health])
	check_equal(server.bots.bots[0].state if blue.alive else server.bots.bots[1].state, Bots.State.ADVANCE, "the winner's state")


## A wall between two enemies hides them from each other: no shot is fired.
func test_bots_do_not_shoot_through_walls() -> void:
	var server := _server(2, true)
	var blue := _place(server, 0, Vector3(0, 0, 6), Vector3(0, 0, -6))
	var red := _place(server, 1, Vector3(0, 0, -6), Vector3(0, 0, 6))
	_steps(server, 4 * Game.TICK_RATE)
	check_equal(blue.shots + red.shots, 0, "shots fired through the wall")
	check(server.bots.bots[0].state != Bots.State.ENGAGE, "a bot engages an enemy behind a wall")


## Bots of one team in each other's view do not fire; their enemies stand
## behind the wall.
func test_bots_spare_their_team() -> void:
	var server := _server(4, true)
	var a := _place(server, 0, Vector3(-4, 0, 6), Vector3(4, 0, 6))
	var b := _place(server, 2, Vector3(4, 0, 6), Vector3(-4, 0, 6))
	check_equal(a.team, b.team, "the team of bots 0 and 2")
	_place(server, 1, Vector3(-4, 0, -6), Vector3(4, 0, -6))
	_place(server, 3, Vector3(4, 0, -6), Vector3(-4, 0, -6))
	_steps(server, 3 * Game.TICK_RATE)
	check_equal(a.shots + b.shots, 0, "shots at a teammate")
	check(a.health == Game.MAX_HEALTH and b.health == Game.MAX_HEALTH, "a teammate was hurt")


## A bot shot from behind turns to its attacker and fights it.
func test_bot_answers_a_shot_from_behind() -> void:
	var range := FiringRange.new(func(settings: ServerSettings) -> void: settings.bots = 1)
	cleanup(func() -> void: range.close())
	var shooter := range.shooter_soldier()
	var bot := range.server.bots.bots[0]
	var soldier := range.server.soldiers.get_soldier(bot.soldier)
	var enemy := Game.Team.RED if shooter.team == Game.Team.BLUE else Game.Team.BLUE
	if soldier.team != enemy:
		soldier.team = enemy
	var at := shooter.position + Vector3(0, 0, -8)
	_place(range.server, 0, at, at + Vector3(0, 0, -10))
	range.step(2)
	range.fire(at + Vector3(0, 0.85, 0))
	check(soldier.health < Game.MAX_HEALTH, "the shot in the back missed")
	range.step(Game.TICK_RATE)
	check_equal(bot.state, Bots.State.ENGAGE, "the state of the bot a second after the shot")
	check_equal(bot.target, shooter.id, "the target of the bot")
	check(absf(Game.remainder(soldier.yaw - Game.yaw_of(shooter.position - soldier.position))) < deg_to_rad(20),
		"the bot looks %.0f degrees away from its attacker" % rad_to_deg(Game.remainder(soldier.yaw - Game.yaw_of(shooter.position - soldier.position))))


## Twenty-four bots fight on the valley for half a minute: they kill each
## other, walk the map, stay on the ground within the play area and keep
## moving.
func test_bots_fight_a_battle_on_the_valley() -> void:
	var settings := ServerSettings.new()
	settings.map = "valley"
	settings.bots = 24
	settings.seed = 9
	var server: Server = Server.create(settings, Rules.new())
	cleanup(func() -> void: server.close())
	server.flag_match.started = true
	var start := {}
	var still := {}
	var worst_still := 0
	var below := 0.0
	for t in 30 * Game.TICK_RATE:
		server.step()
		for bot in server.bots.bots:
			var soldier := server.soldiers.get_soldier(bot.soldier)
			if not soldier.alive:
				continue
			if not start.has(bot.index):
				start[bot.index] = soldier.position
			below = maxf(below, server.scene.ground_at(soldier.position.x, soldier.position.z) - soldier.position.y)
			check(absf(soldier.position.x) <= server.scene.play_area and absf(soldier.position.z) <= server.scene.play_area,
				"bot %d left the play area for %s" % [bot.index, soldier.position])
			if bot.state != Bots.State.ENGAGE and server.tick >= bot.linger_until and soldier.velocity == Vector3.ZERO:
				still[bot.index] = still.get(bot.index, 0) + 1
				worst_still = maxi(worst_still, still[bot.index])
			else:
				still[bot.index] = 0
	check(server.profile.kills >= 2 and server.total_hits > 20, "%d kills and %d hits in half a minute" % [server.profile.kills, server.total_hits])
	check(below < 0.05, "a bot sank %.2f m into the ground" % below)
	check(worst_still < Game.TICK_RATE, "a bot stood %.1f s where it should walk" % (worst_still / float(Game.TICK_RATE)))
	var walked := 0
	for bot in server.bots.bots:
		var soldier := server.soldiers.get_soldier(bot.soldier)
		if start.has(bot.index) and soldier.position.distance_to(start[bot.index]) > 10:
			walked += 1
	check(walked >= 18, "only %d of 24 bots got 10 m from where they were first seen" % walked)
