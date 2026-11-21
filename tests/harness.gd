extends RefCounted
## Harness runs a server with clients joined over memory, in lockstep: the
## tests step the server tick by tick, and every step takes in what the
## clients received. The server's clock runs with its ticks, so that its
## limits of rates and its timeouts hold as in a real game, however fast the
## test runs.

var server: Server
var listener := Memory.MemoryListener.new()
var clients: Array[Client] = []


## _init starts a server; configure may change the settings first, and rules
## replace the default ones.
func _init(configure: Callable = Callable(), rules: Rules = null) -> void:
	var settings := ServerSettings.new()
	settings.stats_interval = 0
	settings.seed = 1
	if configure.is_valid():
		configure.call(settings)
	var made: Variant = Server.create(settings, rules if rules != null else Rules.new())
	assert(made is Server, str(made))
	server = made
	server.clock = server.tick_time
	server.add_listener(listener)


func close() -> void:
	for client in clients:
		client.conn.close("test over")
	server.close()
	listener.close()


## step runs ticks of the server; the clients take in what came after each.
func step(ticks: int = 1) -> void:
	for i in ticks:
		server.step()
		for client in clients:
			client.receive()


## dial opens a connection without saying anything on it.
func dial() -> Client:
	var client := Client.new(listener.dial())
	clients.append(client)
	return client


## join connects a player: Hello, then Welcome, then Ready, and steps until its
## soldier stands. It returns the client, whose welcome is null when refused.
func join(name: String, token: PackedByteArray = PackedByteArray()) -> Client:
	var client := dial()
	client.hello(name, token)
	for i in 3:
		step()
		if client.welcome != null or not client.conn.is_open():
			break
	if client.welcome == null:
		return client
	client.send(Messages.Ready.new())
	step(2)
	return client


## player is the server's player of a client.
func player(client: Client) -> ServerPlayer:
	return server.players[client.welcome.player]


## Client is the far end of a connection, as a test drives it.
class Client:
	var conn: Conn
	var welcome: Messages.Welcome
	var reject: Messages.Reject
	## snapshot is the newest snapshot datagram received; snapshots all of them
	## since the last clear.
	var snapshot: Snapshot
	var snapshots: Array[Snapshot] = []
	var events: Array = []

	func _init(connection: Conn) -> void:
		conn = connection

	func hello(name: String, token: PackedByteArray = PackedByteArray(), version: int = Protocol.VERSION) -> void:
		var message := Messages.Hello.new()
		message.protocol_version = version
		message.name = name
		message.token = token
		send(message)

	func send(message: Object) -> void:
		conn.send_reliable(Conn.Channel.CONTROL, Protocol.encode(message))

	## command sends a datagram with one command.
	func command(command: InputCommand) -> void:
		var packet := InputPacket.new()
		packet.commands = [command]
		conn.send_unreliable(Protocol.encode(packet))

	func receive() -> void:
		conn.poll()
		while true:
			var message := conn.receive_reliable()
			if message.is_empty():
				break
			var decoded: Variant = Protocol.decode(message[1])
			if decoded is Messages.Welcome:
				welcome = decoded
			elif decoded is Messages.Reject:
				reject = decoded
			elif decoded is Object:
				events.append(decoded)
		while true:
			var data := conn.receive_unreliable()
			if data.is_empty():
				break
			var decoded := Snapshot.new()
			if Protocol.decode_into(decoded, data) == "":
				if snapshot == null or decoded.server_tick >= snapshot.server_tick:
					snapshot = decoded
				snapshots.append(decoded)

	## closed tells why the server ended the connection: the reason it rejected
	## the client, or the close reason; "" while it is open.
	func closed() -> String:
		if reject != null:
			return reject.message
		if conn.is_open():
			return ""
		return conn.close_reason
