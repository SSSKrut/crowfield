extends TestCase
## The weapons beyond the first three: the pellets of a shotgun, rockets and
## grenades with their blasts, the medkit, and the bots that carry them.

const FiringRange := preload("res://tests/firing_range.gd")
const SHOTGUN := 3
const LAUNCHER := 4
const GRENADE := 5
const MEDKIT := 6

var _weapons := WeaponSet.create_default()


## _floor is a map of a floor 60 m across, with a wall 3 m tall across it at
## z = -10 when walled.
static func _floor(walled: bool = false) -> MapScene:
	var scene := MapScene.new()
	scene.name = "test"
	scene.play_area = 28.0
	scene.set_zone(Game.Team.BLUE, Vector3(0, 0.2, 8), 0)
	scene.set_zone(Game.Team.RED, Vector3(0, 0.2, -20), 0)
	scene.add_box(Vector3(30, 0.25, 30), Vector3(0, -0.25, 0))
	if walled:
		scene.add_box(Vector3(4, 1.5, 0.2), Vector3(0, 1.5, -10))
	scene.objectives.append(MapScene.Zone.new("floor", Vector3.ZERO, 10))
	return scene


func _range(walled: bool = false, friendly_fire: bool = false) -> FiringRange:
	var range := FiringRange.new(func(settings: ServerSettings) -> void:
		settings.scene = _floor(walled)
		settings.friendly_fire = friendly_fire)
	cleanup(func() -> void: range.close())
	for tuning in [range.server.rules.weapons.shotgun, range.server.rules.weapons.rocket_launcher, range.server.rules.weapons.grenade]:
		tuning.hip_spread = 0
		tuning.move_spread = 0
		tuning.kick_pitch = 0
		tuning.kick_yaw = 0
	range.server.rules.weapons.shotgun.pellet_spread = 1.0
	return range


## _take puts the weapon of a slot into the shooter's hands.
static func _take(range: FiringRange, slot: int) -> void:
	var kind := range.shooter_soldier().arsenal.weapons[slot]
	for i in range.server.rules.weapons.get_tuning(kind).equip_ticks() + 2:
		range.forge(FiringRange.forged(0, slot))


## _pull fires the weapon in hand once, aimed at a point, and lets go.
static func _pull(range: FiringRange, slot: int, at: Vector3) -> void:
	var angles := range.aim(at)
	var command := InputCommand.create(0, 0, 0, angles.x, angles.y, InputCommand.FIRE)
	command.weapon = slot
	range.forge(command)
	var release := InputCommand.create(0, 0, 0, angles.x, angles.y, 0)
	release.weapon = slot
	range.forge(release)


static func _enemy(range: FiringRange) -> int:
	return Game.Team.RED if range.shooter_soldier().team == Game.Team.BLUE else Game.Team.BLUE


static func _events(range: FiringRange, type: Variant) -> Array:
	return range.client.events.filter(func(event: Object) -> bool: return is_instance_of(event, type))


# The weapons themselves.


## A shot of the shotgun is nine pellets around the aim, the same for the same
## numbers and within the cone of the pellets and the spread.
func test_shotgun_scatters_its_pellets_repeatably() -> void:
	var tuning := _weapons.shotgun
	var aim := Game.view_direction(0.3, -0.1)
	var limit := deg_to_rad(tuning.pellet_spread + tuning.hip_spread) + 1e-4
	var shots := []
	for attempt in 2:
		var arsenal := Arsenal.create(PackedInt32Array([WeaponTuning.Kind.SHOTGUN]), _weapons)
		var command := InputCommand.create(1, 0, 0, 0.3, -0.1, InputCommand.FIRE)
		var result := arsenal.step(_weapons, command, 0.0, false, Arsenal.mix64(77))
		shots.append(result.shot)
	var first: Shot = shots[0]
	check_equal(first.pellets.size(), tuning.pellets, "pellets of a shot")
	check(first.pellets == shots[1].pellets, "the same numbers scattered the pellets differently")
	for pellet in first.pellets:
		check(pellet.angle_to(aim) <= limit, "a pellet %.2f degrees off the aim" % rad_to_deg(pellet.angle_to(aim)))
	check(first.pellets[0] != first.pellets[1], "two pellets flew the same way")


## A medkit does nothing for a soldier at full health and heals a wounded one,
## a charge at a time.
func test_medkit_works_only_on_the_wounded() -> void:
	var arsenal := Arsenal.create(PackedInt32Array([WeaponTuning.Kind.MEDKIT]), _weapons)
	var pull := InputCommand.create(1, 0, 0, 0, 0, InputCommand.FIRE)
	var whole := arsenal.step(_weapons, pull, 0.0, false, 1, false)
	check(not whole.has(Arsenal.EVENT_FIRED) and arsenal.magazine[0] == 2, "a medkit worked on a soldier at full health")
	arsenal.step(_weapons, InputCommand.create(2, 0, 0, 0, 0, 0), 0.0, false, 1, true)
	var hurt := arsenal.step(_weapons, InputCommand.create(3, 0, 0, 0, 0, InputCommand.FIRE), 0.0, false, 1, true)
	check(hurt.has(Arsenal.EVENT_FIRED) and arsenal.magazine[0] == 1, "a medkit did not work on a wounded soldier")


## A loadout of fewer weapons than slots leaves the rest empty.
func test_a_short_loadout_leaves_the_rest_empty() -> void:
	var arsenal := Arsenal.create(PackedInt32Array([WeaponTuning.Kind.SHOTGUN, WeaponTuning.Kind.GRENADE]), _weapons)
	check_equal(arsenal.weapons, PackedInt32Array([WeaponTuning.Kind.SHOTGUN, WeaponTuning.Kind.GRENADE, 0, 0, 0, 0, 0]), "slots")
	check(arsenal.magazine[1] == 1 and arsenal.reserve[1] == 2 and arsenal.magazine[2] == 0, "grenades %d + %d" % [arsenal.magazine[1], arsenal.reserve[1]])


# On the server.


## Up close the pellets of one shot add up into one wound that kills: one hit
## to the shooter, one death.
func test_shotgun_kills_with_one_shot_up_close() -> void:
	var range := _range()
	var target := range.target(_enemy(range), range.shooter_soldier().position + Vector3(0, 0, -5))
	_take(range, SHOTGUN)
	range.client.events.clear()
	_pull(range, SHOTGUN, range.server.soldiers.get_soldier(target).position + Vector3(0, Bots.AIM_HEIGHT, 0))
	check(not range.server.soldiers.get_soldier(target).alive, "the target lives with %d health" % range.health(target))
	var confirms := _events(range, Messages.HitConfirm)
	check(confirms.size() == 1 and confirms[0].killed, "%d hit confirmations for one shot" % confirms.size())
	check_equal(_events(range, Messages.Death).size(), 1, "deaths told")


## A rocket bursts on the soldier it strikes: the soldier takes the whole
## blast, one beside it its share, and one beyond the blast nothing. Every
## player hears of the launch and the blast.
func test_rocket_bursts_on_a_soldier_and_hurts_by_distance() -> void:
	var range := _range()
	var enemy := _enemy(range)
	var feet := range.shooter_soldier().position
	var struck := range.target(enemy, feet + Vector3(0, 0, -20))
	var beside := range.target(enemy, feet + Vector3(4, 0, -20))
	var beyond := range.target(enemy, feet + Vector3(9, 0, -20))
	_take(range, LAUNCHER)
	range.client.events.clear()
	_pull(range, LAUNCHER, range.server.soldiers.get_soldier(struck).position + Vector3(0, Bots.AIM_HEIGHT, 0))
	range.step(Game.TICK_RATE)
	check(not range.server.soldiers.get_soldier(struck).alive, "the soldier struck lives with %d health" % range.health(struck))
	var share := range.server.rules.weapons.rocket_launcher.blast_share(4)
	check(range.health(beside) < Game.MAX_HEALTH and range.health(beside) > 0,
		"the soldier beside has %d health, a share of %.2f" % [range.health(beside), share])
	check_equal(range.health(beyond), Game.MAX_HEALTH, "health beyond the blast")
	check_equal(_events(range, Messages.Launch).size(), 1, "launches told")
	var blasts := _events(range, Messages.Blast)
	if check_equal(blasts.size(), 1, "blasts told"):
		var at: Vector3 = blasts[0].position
		check(at.distance_to(range.server.soldiers.get_soldier(struck).position + Vector3(0, Bots.AIM_HEIGHT, 0)) < 0.8, "the rocket burst at %s" % at)


## A wall shields a soldier behind it from a blast in front of it; one in front
## is hurt.
func test_walls_shield_from_blasts() -> void:
	var range := _range(true)
	var enemy := _enemy(range)
	var behind := range.target(enemy, Vector3(0, 0, -11))
	var front := range.target(enemy, Vector3(1.5, 0, -8.5))
	_take(range, LAUNCHER)
	_pull(range, LAUNCHER, Vector3(0, 1.0, -9.8))
	range.step(Game.TICK_RATE)
	check_equal(range.health(behind), Game.MAX_HEALTH, "health behind the wall")
	check(range.health(front) < Game.MAX_HEALTH, "the soldier in front of the wall took nothing")


## Without friendly fire a blast spares the team of its owner, the owner too.
func test_blasts_spare_the_team() -> void:
	var range := _range()
	var team := range.shooter_soldier().team
	var friend := range.target(team, range.shooter_soldier().position + Vector3(1.5, 0, -6))
	_take(range, LAUNCHER)
	_pull(range, LAUNCHER, range.shooter_soldier().position + Vector3(0, 0, -5))
	range.step(Game.TICK_RATE)
	check_equal(range.health(friend), Game.MAX_HEALTH, "the teammate's health")
	check_equal(range.shooter_soldier().health, Game.MAX_HEALTH, "the owner's health")


## A grenade thrown up bounces, rests and bursts at its fuse, on the ground;
## a client flying it by the same code through its own copy of the map ends
## exactly where the server says it burst.
func test_grenade_bursts_at_its_fuse_where_the_client_flies_it() -> void:
	var range := _range()
	var feet := range.shooter_soldier().position
	_take(range, GRENADE)
	range.client.events.clear()
	_pull(range, GRENADE, feet + Vector3(0, 6, -12))
	var tuning := range.server.rules.weapons.grenade
	range.step(tuning.fuse_ticks() + 2)
	var launches := _events(range, Messages.Launch)
	var blasts := _events(range, Messages.Blast)
	if not check(launches.size() == 1 and blasts.size() == 1, "%d launches and %d blasts" % [launches.size(), blasts.size()]):
		return
	var launch: Messages.Launch = launches[0]
	var blast: Messages.Blast = blasts[0]
	check_equal(blast.tick - launch.tick, tuning.fuse_ticks(), "ticks from the throw to the blast")
	check(blast.position.y > 0 and blast.position.y < 0.2, "the grenade burst at %s, not on the ground" % blast.position)
	check(Vector2(blast.position.x - feet.x, blast.position.z - feet.z).length() > 8, "the grenade burst at %s, near the thrower" % blast.position)
	var space := PhysicsServer3D.space_create()
	var made := range.server.scene.build_collision(space)
	cleanup(func() -> void:
		MapScene.free_collision(made)
		PhysicsServer3D.free_rid(space))
	var flight := Projectile.new()
	flight.kind = launch.kind
	flight.position = launch.position
	flight.velocity = launch.velocity
	flight.launched = launch.tick
	var query := PhysicsRayQueryParameters3D.new()
	var at := launch.tick
	while not flight.step(PhysicsServer3D.space_get_direct_state(space), query, tuning, at):
		at += 1
	check_equal(flight.position, blast.position, "where the client's grenade lies at the blast")


## A medkit heals the wounded soldier of a player on the server.
func test_medkit_heals_on_the_server() -> void:
	var range := _range()
	range.server.damage(range.shooter_soldier(), 60)
	_take(range, MEDKIT)
	_pull(range, MEDKIT, Vector3(0, 0, -10))
	check_equal(range.shooter_soldier().health, Game.MAX_HEALTH - 60 + range.server.rules.weapons.medkit.heal, "health after a medkit")


# Bots.


func _bot_server(bots: int) -> Server:
	var settings := ServerSettings.new()
	settings.scene = _floor(true)
	settings.bots = bots
	settings.seed = 6
	var server: Server = Server.create(settings, Rules.new())
	server.clock = server.tick_time
	cleanup(func() -> void: server.close())
	return server


static func _hold(server: Server, i: int, at: Vector3, look: Vector3, loadout: PackedInt32Array) -> Soldier:
	var bot := server.bots.bots[i]
	var soldier := server.soldiers.get_soldier(bot.soldier)
	soldier.position = at
	soldier.yaw = Game.yaw_of(look - at)
	soldier.arsenal = Arsenal.create(loadout, server.rules.weapons)
	bot.weapon = 0
	bot.path = PackedVector3Array()
	bot.linger_until = server.tick + 100000
	bot.think_at = server.tick
	return soldier


## Every bot carries a gun, and at most one thing more.
func test_bots_carry_one_or_two_weapons() -> void:
	var server := _bot_server(64)
	var kinds := {}
	for bot in server.bots.bots:
		var arsenal := server.soldiers.get_soldier(bot.soldier).arsenal
		var carried := Array(arsenal.weapons).filter(func(kind: int) -> bool: return kind != WeaponTuning.Kind.NONE)
		check(carried.size() >= 1 and carried.size() <= 2, "bot %d carries %s" % [bot.index, carried])
		check(Bots.REACH.has(carried[0]), "bot %d has no gun first: %s" % [bot.index, carried])
		for kind in carried:
			kinds[kind] = true
	check_equal(kinds.size(), WeaponTuning.KINDS - 1, "kinds of weapons the bots carry")


## A bot with a rocket launcher fires it at an enemy it sees 40 m away.
func test_bot_fires_rockets() -> void:
	var server := _bot_server(2)
	var blue := _hold(server, 0, Vector3(5, 0, 12), Vector3(5, 0, -28),
		PackedInt32Array([WeaponTuning.Kind.ASSAULT_RIFLE, WeaponTuning.Kind.ROCKET_LAUNCHER]))
	_hold(server, 1, Vector3(5, 0, -28), Vector3(5, 0, 12), PackedInt32Array())
	server.bots.bots[0].special_at = server.tick
	var launched := false
	for i in 8 * Game.TICK_RATE:
		server.step()
		if not server.projectiles.is_empty():
			launched = true
			break
	check(launched, "no rocket in 8 s; the launcher holds %d + %d" % [blue.arsenal.magazine[1], blue.arsenal.reserve[1]])


## A wounded bot out of the fight heals itself with its medkit.
func test_wounded_bot_heals() -> void:
	var server := _bot_server(2)
	var blue := _hold(server, 0, Vector3(0, 0, 12), Vector3(0, 0, 20),
		PackedInt32Array([WeaponTuning.Kind.ASSAULT_RIFLE, WeaponTuning.Kind.MEDKIT]))
	_hold(server, 1, Vector3(0, 0, -20), Vector3(0, 0, -25), PackedInt32Array())
	blue.health = 30
	for i in 4 * Game.TICK_RATE:
		server.step()
	check_equal(blue.health, 30 + server.rules.weapons.medkit.heal, "health of the bot after its medkit")
