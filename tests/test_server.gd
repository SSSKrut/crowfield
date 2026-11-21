extends TestCase
## The server with clients in the same process: joining, prediction without
## corrections, the snapshot budget, combat and its rules, and the limits of
## what a client may send.


func _server(configure: Callable = Callable()) -> Server:
	var settings := ServerSettings.new()
	settings.stats_interval = 0
	settings.seed = 1
	if configure.is_valid():
		configure.call(settings)
	var made: Variant = Server.create(settings, Rules.new())
	if made is String:
		fail(made)
		return null
	var server: Server = made
	cleanup(func() -> void: server.close())
	return server


func _space() -> RID:
	var space := PhysicsServer3D.space_create()
	var made := MapScene.prototype().build_collision(space)
	cleanup(func() -> void:
		MapScene.free_collision(made)
		PhysicsServer3D.free_rid(space))
	return space


## _join connects a headless client to the server over memory, under network
## conditions if any.
func _join(server: Server, listener: Memory.MemoryListener, name: String, space: RID, conditions: NetworkConditions = null) -> HeadlessClient:
	var conn := listener.dial()
	if conditions != null:
		conn = SimulatedConn.new(conn, conditions)
	var client := HeadlessClient.new(conn, name, server.rules, name.hash(), space, func(_map: String) -> MapScene: return server.scene)
	cleanup(func() -> void: client.close())
	return client


## _run steps the server and the clients together for a number of ticks, in
## lockstep: a client tick, then a server tick. The server's clock runs with
## its ticks, faster than real time, so that its limits of the message rate
## hold as in a real game.
func _run(server: Server, clients: Array, ticks: int) -> void:
	server.clock = server.tick_time
	for i in ticks:
		for client in clients:
			if not client.tick():
				fail("client stopped: %s" % client.error)
				return
		server.step()


func test_client_joins_and_predicts_without_corrections() -> void:
	var server := _server(func(s: ServerSettings) -> void: s.bots = 32; s.bot_ai = false)
	var listener := Memory.MemoryListener.new()
	server.add_listener(listener)
	var space := _space()
	var client := _join(server, listener, "Alice", space)
	_run(server, [client], 600)
	check(client.joined(), "the client did not join: %s" % client.error)
	if not client.joined():
		return
	var session := client.session
	check(session.received > 150, "only %d snapshot datagrams in 10 s" % session.received)
	check_equal(client.predictor.corrections, 0, "corrections of the prediction")
	check_equal(session.unresolved, 0, "datagrams without a delta base")
	check_equal(session.resyncs, 0, "clock jumps")
	check(session.soldiers.size() >= 33, "the client knows %d soldiers, want 33" % session.soldiers.size())
	check(client.shots > 0, "the wandering client never fired")


func test_prediction_holds_under_a_bad_network() -> void:
	var server := _server(func(s: ServerSettings) -> void: s.bots = 16; s.bot_ai = false)
	var listener := Memory.MemoryListener.new()
	server.add_listener(listener)
	var conditions: NetworkConditions = NetworkConditions.parse("delay=50ms,jitter=10ms,loss=5%,seed=3")
	var client := _join(server, listener, "Bob", _space(), conditions)
	# Real time passes for the simulated network: tick at the real pace.
	var deadline := Time.get_ticks_msec() + 6000
	var next := Time.get_ticks_usec()
	while Time.get_ticks_msec() < deadline:
		if Time.get_ticks_usec() < next:
			OS.delay_usec(500)
			continue
		next += 1000000 / Game.TICK_RATE
		if not client.tick():
			fail("client stopped: %s" % client.error)
			return
		server.step()
	check(client.joined(), "the client did not join: %s" % client.error)
	if client.joined():
		check(client.session.received > 80, "only %d snapshot datagrams" % client.session.received)
		check_equal(client.predictor.corrections, 0, "corrections of the prediction")
		check_equal(client.session.unresolved, 0, "datagrams without a delta base")


## 256 bots fit the budget of 32 KB/s, and the soldier under the crosshair
## is updated with every snapshot.
func test_snapshots_keep_the_budget() -> void:
	var server := _server(func(s: ServerSettings) -> void: s.bots = 256; s.bot_ai = false)
	var listener := Memory.MemoryListener.new()
	server.add_listener(listener)
	var client := _join(server, listener, "Carol", _space())
	_run(server, [client], 120)
	var start_bytes := server.profile.snapshot_bytes
	var start_ticks := server.tick
	_run(server, [client], 300)
	var seconds := float(server.tick - start_ticks) / Game.TICK_RATE
	var rate := (server.profile.snapshot_bytes - start_bytes) / seconds
	check(rate <= ServerSettings.DEFAULT_CLIENT_BANDWIDTH * 1.02, "snapshots cost %.1f KB/s, over the budget" % (rate / 1024))
	check(rate >= ServerSettings.DEFAULT_CLIENT_BANDWIDTH * 0.9, "snapshots cost only %.1f KB/s of the budget" % (rate / 1024))
	check_equal(client.session.unresolved, 0, "datagrams without a delta base")
	check(client.session.soldiers.size() >= 250, "the client knows %d soldiers" % client.session.soldiers.size())


class CrouchDriver extends HeadlessClient.Wanderer:
	var crouch := false

	func command(_predictor: Predictor) -> InputCommand:
		return InputCommand.create(0, 0, 0, 0, 0, InputCommand.CROUCH if crouch else 0)


func test_two_clients_agree_on_crouched_stance_and_standing() -> void:
	var server := _server()
	var listener := Memory.MemoryListener.new()
	server.add_listener(listener)
	var holder := _join(server, listener, "Holder", _space())
	var watcher := _join(server, listener, "Watcher", _space())
	var driver := CrouchDriver.new(5)
	holder.input = driver
	watcher.input = CrouchDriver.new(7)
	_run(server, [holder, watcher], 120)
	if not check(holder.joined() and watcher.joined(), "both clients have joined"):
		return
	var id := holder.session.player.soldier
	var slot := SoldierSet.slot_of(id)
	var before := holder.predictor.corrections
	for wanted in [true, false]:
		driver.crouch = wanted
		_run(server, [holder, watcher], 24)
		var own := server.soldiers.get_soldier(id)
		var observer: KnownSoldier = watcher.session.soldiers.get(slot)
		check_equal(own.crouched, wanted, "server stance")
		check_equal(holder.session.player.crouched, wanted, "private snapshot stance")
		check_equal(holder.predictor.soldier.crouched, wanted, "predicted stance")
		check_equal(observer.soldier.crouched, wanted, "remote snapshot stance")
		observer.remote.evaluate(10000.0)
		check_equal(observer.remote.crouched, wanted, "remote rendered stance")
	check_equal(holder.predictor.corrections, before, "stance changes do not correct deterministic prediction")
