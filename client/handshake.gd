class_name Handshake
extends RefCounted
## Handshake joins a server over a connection: Hello, then Welcome or Reject,
## then Ready. The Welcome names the map the server plays; the client builds it
## before it says Ready, and refuses a map that differs from its own. A player
## who lost its connection gives the token of its last session to get its
## place back; a new one gives none. Poll it every frame until done() or
## failed().

const TIMEOUT := 5.0

var conn: Conn
var session: ClientSession
## scene is the map the server plays, once welcomed.
var scene: MapScene
## error tells why the handshake failed.
var error := ""
var _name: String
var _rules: Rules
var _maps: Callable
var _token: PackedByteArray
var _started := 0.0
var _started_tick := -1
var _sent := -1.0


## maps is called with the name of the map the server plays and returns the
## MapScene the client built for it, or the error as a String.
func _init(connection: Conn, player_name: String, rules: Rules, maps: Callable, token: PackedByteArray = PackedByteArray()) -> void:
	conn = connection
	_name = player_name
	_rules = rules
	_maps = maps
	_token = token
	_started = ClientSession._now()


func done() -> bool:
	return session != null


func failed() -> bool:
	return error != ""


## local_tick is the current tick of a server on this thread. It stays fixed
## while this call builds the map.
func poll(local_tick: int = -1) -> void:
	if done() or failed():
		return
	conn.poll()
	if not conn.is_open():
		_fail("server refused: %s" % conn.close_reason)
		return
	if _timed_out(local_tick):
		_fail("the server did not answer in %d s" % int(TIMEOUT))
		conn.close("handshake failed")
		return
	if _sent < 0:
		if not conn.is_ready():
			return
		var hello := Messages.Hello.new()
		hello.protocol_version = Protocol.VERSION
		hello.name = _name
		hello.token = _token
		var encoded := Protocol.encode(hello)
		if encoded.is_empty():
			_fail("bad hello: %s" % Protocol.encode_error(hello))
			return
		conn.send_reliable(Conn.Channel.CONTROL, encoded)
		_sent = ClientSession._now()
		conn.poll()
	var message := conn.receive_reliable()
	if message.is_empty():
		return
	# Hello and Welcome make one round trip, the first measure of the network.
	var rtt := ClientSession._now() - _sent
	var welcome := Messages.Welcome.new()
	var problem := Protocol.decode_into(welcome, message[1])
	if problem != "":
		var reject := Messages.Reject.new()
		if Protocol.decode_into(reject, message[1]) == "":
			_fail("server refused (%s): %s" % [reject.reason_name(), reject.message])
		else:
			_fail("bad welcome: %s" % problem)
		conn.close("handshake failed")
		return
	if welcome.tick_rate != Game.TICK_RATE:
		problem = "server runs at %d Hz, the client at %d Hz" % [welcome.tick_rate, Game.TICK_RATE]
	elif welcome.tuning_hash != _rules.hash_value():
		problem = "server uses different movement or weapon tuning; prediction would not match"
	else:
		var built: Variant = _maps.call(welcome.map)
		if built is String:
			problem = "server plays map %s: %s" % [welcome.map, built]
		elif (built as MapScene).hash_value() != welcome.map_hash:
			problem = "server plays map %s, which differs from the client's" % welcome.map
		else:
			scene = built
	if problem != "":
		_fail(problem)
		conn.close("handshake failed")
		return
	conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(Messages.Ready.new()))
	if local_tick >= 0:
		welcome.server_tick = local_tick
		# The memory transport adds no network latency. The measured delay
		# here is time spent waiting for the client and server to process a frame.
		rtt = 0.0
	else:
		# A remote server keeps ticking while this client builds the map.
		welcome.server_tick += floori((ClientSession._now() - _sent - rtt) * Game.TICK_RATE)
	session = ClientSession.new(conn, _name, welcome, rtt)


func _timed_out(local_tick: int) -> bool:
	if local_tick < 0:
		return ClientSession._now() - _started > TIMEOUT
	# A frame stall blocks the loopback server as well as the client.
	if _started_tick < 0:
		_started_tick = local_tick
	return local_tick - _started_tick > TIMEOUT * Game.TICK_RATE


func _fail(reason: String) -> void:
	error = reason
