extends TestCase
## The transports: memory for solo play, the network simulator over it, and
## ENet with DTLS on the loopback.

## A certificate takes a while to make; the tests of this file share theirs.
static var _made: Array = []


static func _certificate(index: int) -> Array:
	while _made.size() <= index:
		_made.append(Certificates.generate())
	return _made[index]


static func _bytes(text: String) -> PackedByteArray:
	return text.to_utf8_buffer()


## _reliable reads every reliable message queued as [channel, text].
static func _reliable(conn: Conn) -> Array:
	var got := []
	while true:
		var message := conn.receive_reliable()
		if message.is_empty():
			return got
		got.append([message[0], (message[1] as PackedByteArray).get_string_from_utf8()])
	return got


static func _datagrams(conn: Conn) -> PackedStringArray:
	var got := PackedStringArray()
	while true:
		var data := conn.receive_unreliable()
		if data.is_empty():
			return got
		got.append(data.get_string_from_utf8())
	return got


func test_memory_keeps_the_order_of_each_channel() -> void:
	var ends := Memory.pair()
	var sent := []
	for i in 10:
		var channel := Conn.Channel.CONTROL if i % 3 == 0 else Conn.Channel.EVENTS
		ends[0].send_reliable(channel, _bytes("m%d" % i))
		sent.append([channel, "m%d" % i])
		ends[0].send_unreliable(_bytes("d%d" % i))
	check_equal(_reliable(ends[1]), sent, "reliable messages")
	check_equal(_datagrams(ends[1]).size(), 10, "datagrams")
	ends[1].send_reliable(Conn.Channel.CONTROL, _bytes("back"))
	check_equal(_reliable(ends[0]), [[Conn.Channel.CONTROL, "back"]], "the answer")


func test_memory_refuses_what_the_network_would() -> void:
	var ends := Memory.pair()
	var big := PackedByteArray()
	big.resize(Conn.MAX_RELIABLE_SIZE + 1)
	check(ends[0].send_reliable(Conn.Channel.CONTROL, big) != OK, "a reliable message over the limit was sent")
	big.resize(Conn.MAX_DATAGRAM_SIZE + 1)
	check(ends[0].send_unreliable(big) != OK, "a datagram over the limit was sent")
	check(ends[0].send_reliable(Conn.CHANNELS, _bytes("x")) != OK, "a message on a channel that does not exist was sent")
	check(ends[0].is_open(), "a refused send closed the connection")


## A reader that falls behind keeps the newest datagrams; one that stops
## reading reliable messages is cut off, and the sender learns it.
func test_memory_queues_are_bounded() -> void:
	var ends := Memory.pair()
	for i in 200:
		ends[0].send_unreliable(_bytes("d%d" % i))
	var got := _datagrams(ends[1])
	check(got.size() == Conn.DATAGRAM_QUEUE_LIMIT and got[got.size() - 1] == "d199" and got[0] == "d%d" % (200 - Conn.DATAGRAM_QUEUE_LIMIT),
		"kept %d datagrams, %s to %s" % [got.size(), got[0] if got.size() > 0 else "", got[got.size() - 1] if got.size() > 0 else ""])
	check_equal(ends[1].stats.datagrams_dropped, 200 - Conn.DATAGRAM_QUEUE_LIMIT, "datagrams dropped")
	var refused := -1
	for i in Conn.RELIABLE_QUEUE_LIMIT + 1:
		if ends[0].send_reliable(Conn.Channel.EVENTS, _bytes("m")) != OK:
			refused = i
			break
	check_equal(refused, Conn.RELIABLE_QUEUE_LIMIT, "the message refused")
	check(not ends[0].is_open() and not ends[1].is_open(), "an overflow left a side open")


## The reason of a close reaches the peer, after what was sent before it.
func test_memory_close_tells_the_reason() -> void:
	var ends := Memory.pair()
	ends[1].send_reliable(Conn.Channel.CONTROL, _bytes("last words"))
	ends[1].close("kicked")
	check(not ends[0].is_open() and ends[0].close_reason == "kicked" and ends[0].closed_by_peer,
		"the peer is open %s, reason %s, by peer %s" % [ends[0].is_open(), ends[0].close_reason, ends[0].closed_by_peer])
	check(not ends[1].closed_by_peer, "the closing side was closed by its peer")
	check_equal(_reliable(ends[0]), [[Conn.Channel.CONTROL, "last words"]], "what came before the close")
	check(ends[0].send_reliable(Conn.Channel.CONTROL, _bytes("late")) != OK, "a closed connection sent")


func test_memory_closes_when_peer_is_released() -> void:
	var ends := Memory.pair()
	var remaining := ends[0]
	ends.clear()
	check_equal(remaining.send_reliable(Conn.Channel.CONTROL, _bytes("late")), ERR_CONNECTION_ERROR, "send to a released peer")
	check(not remaining.is_open() and remaining.closed_by_peer, "the remaining end still appears connected")


func _simulated(text: String) -> Array:
	var parsed: Variant = NetworkConditions.parse(text)
	if parsed is String:
		fail(parsed)
		return []
	var ends := Memory.pair()
	return [SimulatedConn.new(ends[0], parsed), ends[1]]


## _drain polls a simulated connection until nothing is in flight, or a
## second passed.
static func _drain(conn: SimulatedConn) -> void:
	var deadline := Time.get_ticks_msec() + 1000
	while not conn._scheduled.is_empty() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(2)
		conn.poll()
	conn.poll()


## Under delay, jitter and loss, reliable messages arrive in order both ways
## and late; datagrams are lost, some of them.
func test_simulator_delays_and_loses() -> void:
	var pair := _simulated("delay=20ms,jitter=30ms,loss=30%,seed=7")
	if pair.is_empty():
		return
	var client: SimulatedConn = pair[0]
	var server: Conn = pair[1]
	var want := []
	var started := Time.get_ticks_msec()
	for i in 50:
		client.send_reliable(Conn.Channel.CONTROL, _bytes("up%d" % i))
		server.send_reliable(Conn.Channel.EVENTS, _bytes("down%d" % i))
		want.append([Conn.Channel.EVENTS, "down%d" % i])
		client.send_unreliable(_bytes("d%d" % i))
		server.send_unreliable(_bytes("d%d" % i))
	client.poll()
	check(_reliable(server).is_empty() and _reliable(client).is_empty(), "messages arrived without the delay")
	_drain(client)
	check(Time.get_ticks_msec() - started >= 20, "everything arrived in %d ms, the delay is 20 ms" % (Time.get_ticks_msec() - started))
	var up := _reliable(server)
	var ordered := up.size() == 50
	for i in up.size():
		ordered = ordered and up[i][1] == "up%d" % i
	check(ordered, "the client's messages arrived as %s" % [up])
	check_equal(_reliable(client), want, "the server's messages")
	var up_datagrams := _datagrams(server).size()
	var down_datagrams := _datagrams(client).size()
	check(up_datagrams > 15 and up_datagrams < 50 and down_datagrams > 15 and down_datagrams < 50,
		"with 30%% loss %d and %d datagrams of 50 arrived" % [up_datagrams, down_datagrams])
	check(client.stats.rtt >= 0.07 - 1e-6, "the simulated round trip is %.3f s" % client.stats.rtt)


## A server that says something and closes is heard to the end: the client
## closes only once the last words, delayed, arrived.
func test_simulator_delivers_last_words() -> void:
	var pair := _simulated("delay=30ms")
	if pair.is_empty():
		return
	var client: SimulatedConn = pair[0]
	var server: Conn = pair[1]
	server.send_reliable(Conn.Channel.CONTROL, _bytes("last words"))
	server.close("kicked")
	client.poll()
	check(client.is_open(), "the client closed before the last words arrived")
	_drain(client)
	check(not client.is_open() and client.close_reason == "kicked" and client.closed_by_peer,
		"the client is open %s, reason %s" % [client.is_open(), client.close_reason])
	check_equal(_reliable(client), [[Conn.Channel.CONTROL, "last words"]], "the last words")


func test_network_conditions_parse() -> void:
	var parsed: Variant = NetworkConditions.parse("delay=50ms,jitter=10ms,loss=3%,dup=1%,seed=7")
	if check(parsed is NetworkConditions, "a good condition was refused: %s" % [parsed]):
		var conditions: NetworkConditions = parsed
		check(absf(conditions.delay - 0.05) < 1e-9 and absf(conditions.jitter - 0.01) < 1e-9 and absf(conditions.loss - 0.03) < 1e-9
			and absf(conditions.duplicate - 0.01) < 1e-9 and conditions.seed == 7, "parsed as %s seed %d" % [conditions, conditions.seed])
		check(str(conditions).begins_with("delay=50ms,jitter=10ms,loss=3"), "printed as %s" % conditions)
	var none: Variant = NetworkConditions.parse(" ")
	check(none is NetworkConditions and none.is_none(), "an empty condition is not none")
	for bad in ["delay", "delay=fast", "loss=100%", "loss=-1%", "dup=2", "seed=x", "lag=10ms", "delay=-5ms"]:
		check(NetworkConditions.parse(bad) is String, "%s was accepted" % bad)


func test_split_address() -> void:
	var cases := {
		"example.org:1234": ["example.org", 1234],
		"example.org": ["example.org", ENetTransport.DEFAULT_PORT],
		":7000": ["", 7000],
		"127.0.0.1:48000": ["127.0.0.1", 48000],
		"[::1]:5000": ["::1", 5000],
		"[::1]": ["::1", ENetTransport.DEFAULT_PORT],
		"::1": ["::1", ENetTransport.DEFAULT_PORT],
		"host:0": [],
		"host:65536": [],
		"host:port": [],
		"[::1": [],
	}
	for address: String in cases:
		check_equal(ENetTransport.split_address(address), cases[address], address)


## _enet listens with DTLS on a free loopback port and dials it with the
## given client options. It returns [listener, client], or [] when no port was
## free.
func _enet(server_certificate: Array, client_certificate: X509Certificate) -> Array:
	for attempt in 10:
		var port := 48000 + randi() % 1000
		var listening: Variant = ENetTransport.listen("127.0.0.1:%d" % port, Certificates.server_options(server_certificate[0], server_certificate[1]))
		if listening is String:
			continue
		var listener: Listener = listening
		var dialled: Variant = ENetTransport.dial("127.0.0.1:%d" % port, Certificates.pinned_options(client_certificate), Certificates.COMMON_NAME)
		if dialled is String:
			listener.close()
			fail(dialled)
			return []
		var client: Conn = dialled
		cleanup(func() -> void:
			client.close("test over")
			listener.close())
		return [listener, client]
	fail("no free port in 48000..48999")
	return []


## _pump polls both ends until done says so or the time runs out; it returns
## whether done.
static func _pump(listener: Listener, conns: Array, done: Callable, timeout_msec: int = 3000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		listener.poll()
		for conn: Conn in conns:
			conn.poll()
		listener.flush()
		if done.call():
			return true
		OS.delay_msec(2)
	return false


## Over ENet with DTLS a client that pins the server's certificate gets in;
## messages go both ways, in order on each channel, datagrams too, and the
## reason of a close reaches the other side.
func test_enet_carries_messages_both_ways() -> void:
	var made := _enet(_certificate(0), _certificate(0)[0])
	if made.is_empty():
		return
	var listener: Listener = made[0]
	var client: Conn = made[1]
	var accepted := []
	var connected := _pump(listener, [client], func() -> bool:
		var conn := listener.accept()
		if conn != null:
			accepted.append(conn)
		return client.is_ready() and not accepted.is_empty())
	if not check(connected, "the client did not connect: ready %s, open %s %s" % [client.is_ready(), client.is_open(), client.close_reason]):
		return
	var server: Conn = accepted[0]
	for i in 5:
		client.send_reliable(Conn.Channel.CONTROL, _bytes("up%d" % i))
		client.send_reliable(Conn.Channel.EVENTS, _bytes("event%d" % i))
		server.send_reliable(Conn.Channel.EVENTS, _bytes("down%d" % i))
		client.send_unreliable(_bytes("d"))
		server.send_unreliable(_bytes("d"))
	var up := []
	var down := []
	var datagrams := [0, 0]
	_pump(listener, [client, server], func() -> bool:
		up.append_array(_reliable(server))
		down.append_array(_reliable(client))
		datagrams[0] += _datagrams(server).size()
		datagrams[1] += _datagrams(client).size()
		return up.size() == 10 and down.size() == 5 and datagrams[0] == 5 and datagrams[1] == 5)
	var control := up.filter(func(m: Array) -> bool: return m[0] == Conn.Channel.CONTROL).map(func(m: Array) -> String: return m[1])
	var events := up.filter(func(m: Array) -> bool: return m[0] == Conn.Channel.EVENTS).map(func(m: Array) -> String: return m[1])
	check_equal(control, ["up0", "up1", "up2", "up3", "up4"], "the client's control messages")
	check_equal(events, ["event0", "event1", "event2", "event3", "event4"], "the client's events")
	check_equal(down.map(func(m: Array) -> String: return m[1]), ["down0", "down1", "down2", "down3", "down4"], "the server's events")
	check(datagrams[0] == 5 and datagrams[1] == 5, "datagrams on the loopback: %d up, %d down" % datagrams)
	server.close("kicked")
	var told := _pump(listener, [client], func() -> bool: return not client.is_open())
	check(told and client.close_reason == "kicked" and client.closed_by_peer, "the client was told %s" % client.close_reason)


func test_enet_close_reason_reaches_the_server() -> void:
	var made := _enet(_certificate(0), _certificate(0)[0])
	if made.is_empty():
		return
	var listener: Listener = made[0]
	var client: Conn = made[1]
	var accepted := []
	var connected := _pump(listener, [client], func() -> bool:
		var conn := listener.accept()
		if conn != null:
			accepted.append(conn)
		return client.is_ready() and not accepted.is_empty())
	if not check(connected, "the client did not connect"):
		return
	var server: Conn = accepted[0]
	client.close(Protocol.QUIT_REASON)
	var told := _pump(listener, [client], func() -> bool: return not server.is_open())
	check(told and server.close_reason == Protocol.QUIT_REASON and server.closed_by_peer,
		"the server was told %s, by peer %s" % [server.close_reason, server.closed_by_peer])



## A client that pins another certificate than the server's never gets in:
## the encrypted handshake fails, and the server accepts no connection.
func test_enet_refuses_another_certificate() -> void:
	expect_error("TLS handshake error")
	expect_error("-0x")
	var made := _enet(_certificate(0), _certificate(1)[0])
	if made.is_empty():
		return
	var listener: Listener = made[0]
	var client: Conn = made[1]
	var accepted := [null]
	_pump(listener, [client], func() -> bool:
		if accepted[0] == null:
			accepted[0] = listener.accept()
		return client.is_ready() or accepted[0] != null, 1500)
	check(not client.is_ready(), "a client pinning another certificate connected")
	check(accepted[0] == null, "the server accepted a client that pinned another certificate")
