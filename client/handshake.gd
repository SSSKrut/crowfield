class_name Handshake
extends RefCounted
## Handshake joins a server over a connection: Hello, then Welcome or Reject,
## then Ready. A player who lost its connection gives the token of its last
## session to get its place back; a new one gives none. Poll it every frame
## until done() or failed().

const TIMEOUT := 5.0

var conn: Conn
var session: ClientSession
## error tells why the handshake failed.
var error := ""
var _name: String
var _rules: Rules
var _map_hash: int
var _token: PackedByteArray
var _started := 0.0
var _sent := -1.0


func _init(connection: Conn, player_name: String, rules: Rules, map_hash: int, token: PackedByteArray = PackedByteArray()) -> void:
	conn = connection
	_name = player_name
	_rules = rules
	_map_hash = map_hash
	_token = token
	_started = ClientSession._now()


func done() -> bool:
	return session != null


func failed() -> bool:
	return error != ""


func poll() -> void:
	if done() or failed():
		return
	conn.poll()
	if not conn.is_open():
		_fail("server refused: %s" % conn.close_reason)
		return
	if ClientSession._now() - _started > TIMEOUT:
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
	elif welcome.map != Game.PROTOTYPE_MAP or welcome.map_hash != _map_hash:
		problem = "server plays map %s, which differs from the client's %s" % [welcome.map, Game.PROTOTYPE_MAP]
	if problem != "":
		_fail(problem)
		conn.close("handshake failed")
		return
	conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(Messages.Ready.new()))
	session = ClientSession.new(conn, _name, welcome, rtt)


func _fail(reason: String) -> void:
	error = reason
