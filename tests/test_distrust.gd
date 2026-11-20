extends TestCase
## The server trusts no client (specification, 9.8): a client sends only
## commands, and these tests forge the worst commands the protocol carries.
## Damage, hits, ammo and positions are the server's alone.

const FiringRange := preload("res://tests/firing_range.gd")
const Harness := preload("res://tests/harness.gd")


func _range(configure: Callable = Callable()) -> FiringRange:
	var range := FiringRange.new(configure)
	cleanup(func() -> void: range.close())
	return range


func _harness(configure: Callable) -> Harness:
	var harness := Harness.new(configure)
	cleanup(func() -> void: harness.close())
	return harness


## Pulling the trigger every other tick fires no faster than the weapon
## allows: the rifle about three rounds a second, however fast the clicks.
func test_forged_clicks_do_not_outshoot_the_rate() -> void:
	var range := _range()
	var rifle := range.server.rules.weapons.rifle
	for i in rifle.equip_ticks() + 1:
		range.forge(FiringRange.forged(0, 1))
	var before := range.server.profile.shots
	var ticks := 2 * Game.TICK_RATE
	for tick in ticks:
		range.forge(FiringRange.forged(InputCommand.FIRE if tick % 2 == 0 else 0, 1))
	var fired := range.server.profile.shots - before
	var most := ticks / rifle.fire_interval() + 1
	check(fired <= most and fired > 0, "clicking every other tick fired %d rifle rounds in 2 s, at most %d may" % [fired, most])


## Holding the trigger and pressing reload every tick makes no rounds: what was
## fired and what is left always add up to what the soldier spawned with, and
## it never fires faster than the weapon. Holding on fires every round, no
## more, and leaves the weapon empty.
func test_forged_reloads_do_not_make_ammo() -> void:
	var range := _range()
	var rifle := range.server.rules.weapons.assault_rifle
	var all := rifle.magazine + rifle.reserve
	var soldier := range.shooter_soldier()
	var before := range.server.profile.shots
	var left := func() -> int: return soldier.arsenal.magazine[0] + soldier.arsenal.reserve[0]
	var most := 0
	for second in 10:
		var start := range.server.profile.shots
		for i in Game.TICK_RATE:
			range.forge(FiringRange.forged(InputCommand.FIRE | InputCommand.RELOAD))
			var fired := range.server.profile.shots - before
			if fired + left.call() != all:
				fail("%d fired and %d left of %d" % [fired, left.call(), all])
				return
		most = maxi(most, range.server.profile.shots - start)
	for i in 30 * Game.TICK_RATE:
		range.forge(FiringRange.forged(InputCommand.FIRE))
	var limit := Game.TICK_RATE / rifle.fire_interval() + 1
	check(most <= limit, "fired %d rounds in a second, at most %d may" % [most, limit])
	var fired := range.server.profile.shots - before
	check(fired == all and left.call() == 0, "fired %d rounds of %d, %d left" % [fired, all, left.call()])


## The largest axes the protocol carries, diagonally and sprinting, move a
## soldier no faster than a sprint; a weapon slot outside the loadout and a
## pitch past straight up change nothing.
func test_forged_axes_do_not_outrun_the_sprint() -> void:
	var range := _range()
	var soldier := range.shooter_soldier()
	var fastest := 0.0
	for i in Game.TICK_RATE:
		range.forge(FiringRange.forged(InputCommand.SPRINT, 15, -32768, -128, 127))
		fastest = maxf(fastest, Game.horizontal_length(soldier.velocity))
	var sprint := range.server.rules.movement.sprint_speed
	check(fastest <= sprint * 1.0001, "forged axes ran at %.2f m/s, the sprint is %.2f" % [fastest, sprint])
	check(soldier.arsenal.current == 0 and soldier.pitch >= -PI / 2 - 1e-6, "weapon slot %d, pitch %.3f" % [soldier.arsenal.current, soldier.pitch])


## A claimed moment of view is tested no later than the last recorded tick and
## no earlier than the rewind limit, whatever the command says.
func test_forged_view_time_is_bounded() -> void:
	var range := _range(func(settings: ServerSettings) -> void: settings.max_rewind = 0.3)
	var server := range.server
	var latest := float(server.tick - 1)
	var oldest := float(server.tick - 18)
	for c in [[0, 0, latest], [1, 255, latest], [5, 128, server.tick - 4.5], [255, 255, oldest]]:
		var command := InputCommand.new()
		command.tick = server.tick
		command.view_delta = c[0]
		command.view_frac = c[1]
		check_near(server._view_time(command), c[2], 1e-5, "view %d ticks and %d/256 back" % [c[0], c[1]])


## A multiplayer server refuses the respawn request, which would heal and
## refill at will.
func test_respawn_is_refused_outside_solo_play() -> void:
	var range := _range()
	for i in 30:
		range.forge(FiringRange.forged(InputCommand.SPRINT | InputCommand.FIRE, 0, 0, 127))
	range.client.send(Messages.Respawn.new())
	for i in 30:
		range.forge(FiringRange.forged())
	var soldier := range.shooter_soldier()
	var spawn := range.server.scene.spawn_of(soldier.team)
	check(Vector2(soldier.position.x - spawn.x, soldier.position.z - spawn.z).length() >= 1 and soldier.arsenal.magazine[0] != 30,
		"the respawn was granted: at %s with %d rounds" % [soldier.position, soldier.arsenal.magazine[0]])


## With the respawn allowed, as in solo play, it puts the soldier back.
func test_respawn_returns_the_soldier_in_solo_play() -> void:
	var range := _range(func(settings: ServerSettings) -> void: settings.allow_respawn = true)
	for i in 60:
		range.forge(FiringRange.forged(InputCommand.SPRINT | InputCommand.FIRE, 0, 0, 127))
	var soldier := range.shooter_soldier()
	var spawn := range.server.scene.spawn_of(soldier.team)
	if not check(spawn.z - soldier.position.z >= 3, "the soldier walked only %.2f m" % (spawn.z - soldier.position.z)):
		return
	# The server repeats the last command until the next: it stands and holds
	# fire.
	range.forge(FiringRange.forged())
	range.client.send(Messages.Respawn.new())
	range.step(1)
	check(Vector2(soldier.position.x - spawn.x, soldier.position.z - spawn.z).length() < 0.5 and soldier.arsenal.magazine[0] == 30,
		"after the respawn: at %s with %d rounds" % [soldier.position, soldier.arsenal.magazine[0]])


## A client that floods the server with input datagrams has most of them
## dropped unread, while another player's commands all run in time; one that
## floods it with reliable messages is disconnected.
func test_floods_are_dropped() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void:
		settings.max_players = 3
		settings.snapshot_rate = 20)
	var honest := harness.join("honest")
	var flooder := harness.join("flooder")
	var spammer := harness.join("spammer")
	var server := harness.server
	var flood := InputPacket.new()
	flood.commands = [InputCommand.create(server.tick + 5, 1, 0, 0, 0, 0)]
	var data := Protocol.encode(flood)
	var sent := server.tick
	var late := 0
	for i in 60:
		for k in 200:
			flooder.conn.send_unreliable(data)
		while sent <= server.tick + 3:
			honest.command(InputCommand.create(sent, 1, 0, 0, 0, 0))
			sent += 1
		harness.step(1)
		if i > 2 and harness.player(honest).lead < 0:
			late += 1
	check_equal(late, 0, "ticks whose honest commands came late")
	check(server.dropped_inputs >= 1000, "only %d flooding datagrams were dropped" % server.dropped_inputs)
	for k in 4 * Server.CONTROL_BURST:
		spammer.send(Messages.Ready.new())
	harness.step(1)
	check_equal(spammer.closed(), "too many messages", "the reason the spammer was closed")
	check_equal(honest.closed(), "", "the honest player was closed")


## A client cannot claim damage: events go from the server only, and one that
## sends the server a hit or a death of its own making is disconnected, while
## the soldier it names keeps its health.
func test_claimed_damage_is_refused() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void: settings.max_players = 2)
	var victim := harness.join("victim")
	var liar := harness.join("liar")
	var target := harness.player(victim).soldier
	var server := harness.server
	var hit := Messages.HitConfirm.new()
	hit.tick = server.tick
	hit.victim = target
	hit.zone = Hitboxes.Zone.HEAD
	hit.damage = 255
	hit.killed = true
	var death := Messages.Death.new()
	death.tick = server.tick
	death.victim = target
	death.killer = target
	death.victim_name = "victim"
	death.killer_name = "liar"
	for claim in [hit, death]:
		liar.conn.send_reliable(Conn.Channel.EVENTS, Protocol.encode(claim))
		liar.conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(claim))
	harness.step(10)
	check(liar.closed().begins_with("bad message"), "the liar stays connected or left for %s" % liar.closed())
	var soldier := server.soldiers.get_soldier(target)
	check(soldier != null and soldier.health == Game.MAX_HEALTH, "the victim lost health to a claim")
