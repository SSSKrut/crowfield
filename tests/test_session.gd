extends TestCase
## The sessions of the server (ARCHITECTURE.md, 6.11): refusals, leaving, and
## coming back after a lost connection.

const Harness := preload("res://tests/harness.gd")


func _harness(configure: Callable) -> Harness:
	var harness := Harness.new(configure)
	cleanup(func() -> void: harness.close())
	return harness


## _wait_closed steps until the server ends a connection and returns why.
func _wait_closed(harness: Harness, client: Harness.Client, ticks: int = 120) -> String:
	for i in ticks:
		if client.closed() != "":
			return client.closed()
		harness.step(1)
	return client.closed()


## _keep_alive sends a client's command for the coming tick, as a playing
## client does.
func _keep_alive(harness: Harness, client: Harness.Client) -> void:
	client.command(InputCommand.create(harness.server.tick, 0, 0, 0, 0, 0))


func _team(harness: Harness, client: Harness.Client) -> int:
	var soldier := harness.server.soldiers.get_soldier(harness.player(client).soldier)
	return soldier.team if soldier != null else Game.Team.NONE


func test_server_rejects_incompatible_and_extra_clients() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void: settings.max_players = 1)
	var old := harness.dial()
	old.hello("old", PackedByteArray(), Protocol.VERSION + 1)
	check(_wait_closed(harness, old).contains("protocol"), "an old client was refused with %s" % old.closed())
	var first := harness.join("first")
	check(first.welcome != null, "the first client was refused: %s" % first.closed())
	var extra := harness.dial()
	extra.hello("extra")
	check(_wait_closed(harness, extra).contains("full"), "an extra client was refused with %s" % extra.closed())


func test_hello_twice_and_silence_are_dropped() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void: settings.max_players = 2)
	var twice := harness.join("twice")
	twice.hello("twice")
	check_equal(_wait_closed(harness, twice), "hello sent twice", "the reason of a second hello")
	var silent := harness.dial()
	check(_wait_closed(harness, silent, int(Server.HELLO_TIMEOUT * Game.TICK_RATE) + 5).contains("no hello"),
		"a silent connection was closed with %s" % silent.closed())


func test_leaving_player_is_removed_from_snapshots() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void: settings.max_players = 2)
	var stays := harness.join("stays")
	var leaves := harness.join("leaves")
	var gone := harness.player(leaves).soldier
	harness.step(6)
	leaves.conn.close("bye")
	stays.snapshots.clear()
	for i in 30:
		_keep_alive(harness, stays)
		harness.step(1)
	var removed := false
	for snapshot in stays.snapshots:
		if gone in snapshot.removed:
			removed = true
	check(removed, "the soldier of the leaving player was not removed")
	check_equal(harness.server.soldiers.count(), 1, "soldiers after the leave")


## A player whose input stops — a frozen client, a broken link — is dropped
## after the input timeout, and its soldier with it. Its place stays reserved:
## a newcomer finds the server full, while the player returns with its token to
## the same place and team.
func test_lost_player_returns_to_its_place_and_team() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void:
		settings.max_players = 1
		settings.input_timeout = 0.2
		settings.reconnect_window = 5)
	var lost := harness.join("lost")
	var soldier := harness.player(lost).soldier
	var team := _team(harness, lost)
	check(_wait_closed(harness, lost).contains("no input"), "the silent player was closed with %s" % lost.closed())
	check_equal(harness.server.soldiers.count(), 0, "soldiers of the lost player")
	var newcomer := harness.dial()
	newcomer.hello("newcomer")
	check(_wait_closed(harness, newcomer).contains("full"), "a newcomer took the reserved place: %s" % newcomer.closed())
	var back := harness.join("lost", lost.welcome.session_token)
	if not check(back.welcome != null, "the player could not return: %s" % back.closed()):
		return
	check(back.welcome.player == lost.welcome.player and back.welcome.session_token == lost.welcome.session_token,
		"returned as player %d, was %d" % [back.welcome.player, lost.welcome.player])
	check(_team(harness, back) == team and harness.player(back).soldier != soldier and harness.player(back).soldier != 0,
		"returned in team %d with soldier 0x%04x; was team %d with 0x%04x" % [_team(harness, back), harness.player(back).soldier, team, soldier])
	check_equal(harness.server.soldiers.count(), 1, "soldiers after the return")


## A player who quits on purpose frees the place at once.
func test_quitting_player_frees_the_place() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void: settings.max_players = 1)
	var quitter := harness.join("quitter")
	quitter.conn.close(Protocol.QUIT_REASON)
	harness.step(1)
	var newcomer := harness.join("newcomer")
	check(newcomer.welcome != null, "the place of a player who quit stayed taken: %s" % newcomer.closed())
	check(harness.server.reservations.is_empty(), "a quitting player left a reservation")


## A player who comes back while its old connection still looks alive — the
## client restarted, or its route changed — replaces it: never two soldiers.
func test_new_connection_replaces_the_old_one() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void: settings.max_players = 2)
	var watcher := harness.join("watcher")
	var old := harness.join("twice")
	var old_soldier := harness.player(old).soldier
	harness.step(6)
	var again := harness.join("twice", old.welcome.session_token)
	check(old.closed().contains("replaced"), "the old connection was closed with %s" % old.closed())
	if not check(again.welcome != null, "the player could not come back: %s" % again.closed()):
		return
	check_equal(again.welcome.player, old.welcome.player, "the player number")
	var soldier := harness.player(again).soldier
	check(soldier != 0 and soldier != old_soldier, "the player has soldier 0x%04x, had 0x%04x" % [soldier, old_soldier])
	# The watcher hears the old soldier removed and sees exactly two.
	watcher.snapshots.clear()
	for i in 30:
		_keep_alive(harness, watcher)
		_keep_alive(harness, again)
		harness.step(1)
	var seen := {}
	for snapshot in watcher.snapshots:
		for id in snapshot.removed:
			seen.erase(id)
		for record in snapshot.soldiers:
			seen[record.state.id] = true
	check(seen.has(soldier) and not seen.has(old_soldier) and seen.size() == 2, "the watcher sees soldiers %s" % [seen.keys()])
	check_equal(harness.server.soldiers.count(), 2, "soldiers on the server")


## Once the reconnect window passes, the place is free and the token is worth
## nothing.
func test_reservations_expire() -> void:
	var harness := _harness(func(settings: ServerSettings) -> void:
		settings.max_players = 1
		settings.input_timeout = 0.1
		settings.reconnect_window = 0.3)
	var lost := harness.join("lost")
	_wait_closed(harness, lost)
	harness.step(int(0.4 * Game.TICK_RATE))
	check(harness.server.reservations.is_empty(), "the reservation outlived its window")
	var late := harness.join("late", lost.welcome.session_token)
	if check(late.welcome != null, "the late player was refused: %s" % late.closed()):
		check(late.welcome.session_token != lost.welcome.session_token, "an expired token was honoured")


## Commands for a tick arrive in any order and more than once; the buffer holds
## a second of them and takes each at its tick.
func test_input_buffer() -> void:
	var player := ServerPlayer.new(0, "buffer", 4)
	for tick in [12, 10, 11, 12, 70, 9]:
		player.put_input(InputCommand.create(tick, 1, 0, 0, 0, 0), 10)
	for tick in [10, 11, 12]:
		var command := player.take_input(tick)
		check(command != null and command.tick == tick, "no command for tick %d" % tick)
	check(player.take_input(12) == null, "a command was taken twice")
	check(player.take_input(9) == null, "a late command was kept")
	check(player.take_input(70) == null, "a command more than a second ahead was kept")
