extends TestCase
## Combat on the server: hits by zone, walls and teammates that stop shots,
## death and the return of dummies and players, and lag compensation.

const FiringRange := preload("res://tests/firing_range.gd")


func _range(configure: Callable = Callable()) -> FiringRange:
	var range := FiringRange.new(configure)
	cleanup(func() -> void: range.close())
	return range


## Shots at the head, the body and a leg of an enemy eight metres away take the
## damage of those zones.
func test_shots_hit_the_zone_aimed_at() -> void:
	var range := _range()
	var target := range.target(Game.Team.RED, Vector3(0, 0, -1))
	range.step(2)
	for c in [["head", Vector3(0, 1.5, -1), 50], ["body", Vector3(0, 0.85, -1), 25], ["leg", Vector3(0.26, 0.3, -1), 19]]:
		var before := range.health(target)
		range.fire(c[1])
		check_equal(before - range.health(target), c[2], "damage of a shot at the %s" % c[0])
	range.fire(Vector3(1.5, 0.85, -1))
	check_equal(range.health(target), 100 - 50 - 25 - 19, "health after a shot beside the target")


## The column between the shooter and the target stops the shot.
func test_walls_stop_shots() -> void:
	var range := _range()
	var hidden := range.target(Game.Team.RED, Vector3(0, 0, -6))
	range.step(2)
	range.fire(Vector3(0, 0.85, -6))
	check_equal(range.health(hidden), Game.MAX_HEALTH, "health behind the column")
	check_equal(range.server.profile.hits, 0, "hits through a wall")


## Without friendly fire a teammate takes no damage, and still stops the shot
## that would hit the enemy behind it; with it, the teammate is hurt.
func test_teammates_shield_but_are_spared() -> void:
	for friendly_fire in [false, true]:
		var range := _range(func(settings: ServerSettings) -> void: settings.friendly_fire = friendly_fire)
		var team := range.shooter_soldier().team
		var enemy := Game.Team.BLUE if team == Game.Team.RED else Game.Team.RED
		var friend := range.target(team, Vector3(0, 0, 2))
		var behind := range.target(enemy, Vector3(0, 0, -1))
		range.step(2)
		range.fire(Vector3(0, 0.85, -1))
		var want := Game.MAX_HEALTH - (25 if friendly_fire else 0)
		check(range.health(friend) == want and range.health(behind) == Game.MAX_HEALTH,
			"friendly fire %s: the teammate has %d health, the enemy behind it %d" % [friendly_fire, range.health(friend), range.health(behind)])


## A dead dummy stays where it fell, shots pass it, and it comes back after the
## delay as a new soldier of its team.
func test_dead_dummy_comes_back_as_a_new_soldier() -> void:
	var range := _range(func(settings: ServerSettings) -> void:
		settings.dummies = 3
		settings.respawn_delay = 0.5)
	var server := range.server
	var dead: int = server.dummies._soldiers[0]
	server.damage(server.soldiers.get_soldier(dead), 60)
	var wounded := server.soldiers.get_soldier(dead)
	check(wounded.alive and wounded.health == 40, "after 60 damage the dummy is alive %s with %d health" % [wounded.alive, wounded.health])
	server.damage(server.soldiers.get_soldier(dead), 40)
	var corpse := server.soldiers.get_soldier(dead).copy()
	if not check(not corpse.alive and corpse.health == 0 and server.profile.kills == 1, "after 100 damage the dummy is alive %s, %d kills" % [corpse.alive, server.profile.kills]):
		return
	range.step(1)
	range.fire(corpse.position + Vector3(0, 0.85, 0))
	range.step(30 - 2 - server.rules.weapons.assault_rifle.fire_interval())
	var still := server.soldiers.get_soldier(dead)
	check(still != null and still.position == corpse.position, "before the delay the dead dummy moved or went")
	check_equal(server.profile.hits, 0, "hits on the dead")
	range.step(2)
	check(server.soldiers.get_soldier(dead) == null, "the dead soldier is still there after the delay")
	var back := server.soldiers.get_soldier(server.dummies._soldiers[0])
	check(back != null and back.id != dead and back.alive and back.health == Game.MAX_HEALTH and back.team == corpse.team,
		"the dummy came back as %s" % [back])


## A dead player stops moving and shooting, has no capsule and is told when it
## returns; then it gets a new soldier at its team's spawn.
func test_dead_player_waits_and_respawns() -> void:
	var range := _range(func(settings: ServerSettings) -> void: settings.respawn_delay = 1.0)
	var server := range.server
	var player := range.shooter
	var dead := player.soldier
	server.damage(server.soldiers.get_soldier(dead), 1000)
	check(player.controller == null and not server.soldiers.get_soldier(dead).alive, "the dead player kept its capsule")
	var fell := server.soldiers.get_soldier(dead).position
	for i in Game.TICK_RATE / 2:
		player.put_input(InputCommand.create(server.tick, 1, 0, 0, 0, InputCommand.FIRE | InputCommand.SPRINT), server.tick)
		range.step(1)
	check(server.soldiers.get_soldier(dead).position == fell, "the dead moved")
	check_equal(server.profile.shots, 0, "shots of the dead")
	check(player.processed and player.last_processed == server.tick - 1, "the commands of the dead no longer keep the clock")
	var private := range.client.snapshot.player
	check(private.soldier == dead and private.health == 0 and private.respawn > 0 and private.respawn <= Game.TICK_RATE / 2 + 1,
		"the dead player is told health %d, respawn in %d ticks" % [private.health, private.respawn])
	range.step(Game.TICK_RATE / 2 + 1)
	var back := server.soldiers.get_soldier(player.soldier)
	if not check(back != null and back.id != dead and back.alive and back.health == Game.MAX_HEALTH and player.controller != null,
			"the player did not come back"):
		return
	check(back.position.distance_to(server.scene.spawn_of(back.team)) <= 0.5, "came back at %s" % back.position)


## A target walks across the line of fire. A shot made by a player who saw it
## ten ticks ago, aimed where it was then, hits; aimed where it is now, it
## misses. A player who claims to have seen it a second ago is tested at the
## rewind limit.
func test_shots_are_tested_where_the_player_saw_the_target() -> void:
	var range := _range(func(settings: ServerSettings) -> void: settings.max_rewind = 0.3)
	var server := range.server
	# The open floor between the steps and the ramp.
	var target := range.target(Game.Team.RED, Vector3(-3.5, 0, 4))
	var walk := func(ticks: int) -> void:
		for i in ticks:
			var soldier := server.soldiers.get_soldier(target)
			soldier.position.x += 5 * Game.TICK_DELTA
			soldier.velocity = Vector3(5, 0, 0)
			range.step(1)
	walk.call(Game.TICK_RATE)
	for c in [["where it was seen", 10, 10, true], ["where it is now", 10, 1, false], ["far in the past", 60, 60, false], ["at the limit", 60, 18, true]]:
		var pose := server.history.at(target, server.tick - c[2])
		if not check(not pose.is_empty(), "no pose %d ticks back" % c[2]):
			return
		var before := range.health(target)
		range.fire(pose[0] + Vector3(0, 0.85, 0), c[1])
		check_equal(range.health(target) < before, c[3], "%s: hit" % c[0])
		walk.call(1)


## The history interpolates between ticks and forgets a slot's former soldier.
func test_pose_history_interpolates_and_forgets() -> void:
	var soldiers := SoldierSet.new(4)
	var history := PoseHistory.new(4)
	var soldier := Soldier.new()
	soldier.alive = true
	var id := soldiers.add(soldier)
	for tick in 10:
		soldier.position = Vector3(tick, 0, 0)
		soldier.yaw = TAU - 0.05 + 0.02 * tick
		history.record(tick, soldiers)
	var pose := history.at(id, 4.5)
	check(not pose.is_empty() and absf(pose[0].x - 4.5) < 1e-5, "between ticks: %s" % [pose])
	check(not pose.is_empty() and absf(Game.remainder(pose[1] - (TAU - 0.05 + 0.09))) < 1e-4, "the yaw turned the long way: %s" % [pose])
	check(history.at(id, 10.5).is_empty(), "a time not yet recorded")
	check(history.at(id, -0.5).is_empty(), "a time before the first record")
	check(history.at(id, 9 - PoseHistory.TICKS - 1).is_empty(), "a time older than the history")
	soldiers.remove(id)
	var other := soldiers.add(Soldier.new())
	history.record(10, soldiers)
	check(history.at(id, 10).is_empty() and not history.at(other, 10).is_empty(), "the slot's former soldier still resolves")


## Dummies roam the map: they move, stay inside the play area, keep to the
## floor or what they stepped onto, and none stands still for long.
func test_dummies_roam_without_getting_stuck() -> void:
	var harness_script := preload("res://tests/harness.gd")
	var harness = harness_script.new(func(settings: ServerSettings) -> void: settings.dummies = 64)
	cleanup(func() -> void: harness.close())
	var server: Server = harness.server
	var start := {}
	for soldier in server.soldiers.all():
		start[soldier.id] = soldier.position
	var still := {}
	for i in 5 * Game.TICK_RATE:
		harness.step(1)
		for soldier in server.soldiers.all():
			if Game.horizontal_length(soldier.velocity) < 0.1:
				still[soldier.id] = still.get(soldier.id, 0) + 1
	var area := server.scene.play_area
	for soldier in server.soldiers.all():
		check(absf(soldier.position.x) <= area + 1e-3 and absf(soldier.position.z) <= area + 1e-3, "a dummy left the area: %s" % soldier.position)
		check(soldier.position.y > -0.1 and soldier.position.y < 1.6, "a dummy at height %.2f" % soldier.position.y)
		check(start.has(soldier.id) and soldier.position.distance_to(start[soldier.id]) > 1, "dummy 0x%04x hardly moved" % soldier.id)
		check(still.get(soldier.id, 0) < 2 * Game.TICK_RATE, "dummy 0x%04x stood still for %d ticks" % [soldier.id, still.get(soldier.id, 0)])
