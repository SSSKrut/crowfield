class_name ENetTransport
## ENetTransport carries connections over ENet on UDP, encrypted by DTLS.
## Each Conn channel is an ordered reliable ENet channel; datagrams go
## unsequenced on a channel of their own, so they may be lost and reordered
## like any datagram. A last reliable channel carries the reason a side closed
## the connection, which ENet alone cannot tell.

const DEFAULT_PORT := 7777
const _DATAGRAM_CHANNEL := Conn.CHANNELS
const _CLOSE_CHANNEL := Conn.CHANNELS + 1
const _CHANNEL_COUNT := Conn.CHANNELS + 2
const _MAX_PEERS := 64
## ENet gives up on a silent peer, or one that stops acknowledging reliable
## messages, after its timeout; the game notices silence sooner by itself
## (ARCHITECTURE.md, 6.11).
const _TIMEOUT_MIN_MSEC := 5000
const _TIMEOUT_MAX_MSEC := 10000


## split_address parses host:port, [ipv6]:port or a bare host with the default
## port. It returns [host, port], or [] for a bad port.
static func split_address(address: String, default_port: int = DEFAULT_PORT) -> Array:
	var host := address
	var port := default_port
	if address.begins_with("["):
		var close := address.find("]")
		if close < 0:
			return []
		host = address.substr(1, close - 1)
		var rest := address.substr(close + 1)
		if rest.begins_with(":"):
			if not rest.substr(1).is_valid_int():
				return []
			port = rest.substr(1).to_int()
	elif address.count(":") == 1:
		var at := address.find(":")
		host = address.substr(0, at)
		if not address.substr(at + 1).is_valid_int():
			return []
		port = address.substr(at + 1).to_int()
	if port < 1 or port > 65535:
		return []
	return [host, port]


## listen opens a server on a UDP address such as :7777. Without TLS options
## the traffic is not encrypted, which only tests should do. It returns the
## listener, or the error as a String.
static func listen(address: String, tls: TLSOptions) -> Variant:
	var parts := split_address(address)
	if parts.is_empty():
		return "bad address %s" % address
	var bind: String = parts[0] if parts[0] != "" else "0.0.0.0"
	var host := ENetConnection.new()
	var error := host.create_host_bound(bind, parts[1], _MAX_PEERS, _CHANNEL_COUNT)
	if error == ERR_CANT_CREATE:
		# ENet does not say why; nearly always another program holds the port.
		return "cannot listen on UDP port %d: another server may be using it" % parts[1]
	if error != OK:
		return "listen on %s: %s" % [address, error_string(error)]
	if tls != null:
		error = host.dtls_server_setup(tls)
		if error != OK:
			host.destroy()
			return "DTLS on %s: %s" % [address, error_string(error)]
	return HostListener.new(host, address)


## dial starts a connection to a server at host and port; the connection is
## established once is_ready() says so. hostname is what the certificate must name.
## It returns the connection, or the error as a String.
static func dial(address: String, tls: TLSOptions, hostname: String) -> Variant:
	var parts := split_address(address)
	if parts.is_empty():
		return "bad address %s" % address
	var ip: String = parts[0]
	if not ip.is_valid_ip_address():
		ip = IP.resolve_hostname(parts[0])
		if ip == "":
			return "cannot resolve %s" % parts[0]
	var host := ENetConnection.new()
	var error := host.create_host(1, _CHANNEL_COUNT)
	if error != OK:
		return "open a socket: %s" % error_string(error)
	if tls != null:
		error = host.dtls_client_setup(hostname, tls)
		if error != OK:
			host.destroy()
			return "DTLS: %s" % error_string(error)
	var peer := host.connect_to_host(ip, parts[1], _CHANNEL_COUNT)
	if peer == null:
		host.destroy()
		return "connect to %s failed" % address
	return Client.new(host, peer)


## Peer is one end of an ENet connection.
class Peer:
	extends Conn
	var _peer: ENetPacketPeer
	var _remote_reason := ""

	func _init(peer: ENetPacketPeer) -> void:
		_peer = peer
		_peer.set_timeout(32, _TIMEOUT_MIN_MSEC, _TIMEOUT_MAX_MSEC)

	func send_reliable(channel: int, payload: PackedByteArray) -> Error:
		if not is_open():
			return ERR_CONNECTION_ERROR
		var error := Conn.check_send(channel, payload)
		if error != OK:
			return error
		error = _peer.send(channel, payload, ENetPacketPeer.FLAG_RELIABLE)
		if error == OK:
			stats.messages_sent += 1
			stats.bytes_sent += payload.size()
		return error

	func send_unreliable(payload: PackedByteArray) -> Error:
		if not is_open():
			return ERR_CONNECTION_ERROR
		if payload.size() > MAX_DATAGRAM_SIZE:
			return ERR_INVALID_PARAMETER
		var error := _peer.send(_DATAGRAM_CHANNEL, payload, ENetPacketPeer.FLAG_UNSEQUENCED)
		if error == OK:
			stats.datagrams_sent += 1
			stats.bytes_sent += payload.size()
		return error

	func close(reason: String) -> void:
		if not is_open():
			return
		_mark_closed(reason, false)
		_peer.send(_CLOSE_CHANNEL, reason.to_utf8_buffer(), ENetPacketPeer.FLAG_RELIABLE)
		_peer.peer_disconnect_later()

	func _received(channel: int, payload: PackedByteArray) -> void:
		if not is_open():
			return
		if channel == _CLOSE_CHANNEL:
			_remote_reason = payload.get_string_from_utf8() if BitReader.valid_utf8(payload) else "closed"
			_mark_closed(_remote_reason, true)
		elif channel == _DATAGRAM_CHANNEL:
			_deliver_datagram(payload)
		elif channel < Conn.CHANNELS:
			if not _deliver_reliable(channel, payload):
				_peer.peer_disconnect_later()

	func _disconnected() -> void:
		_mark_closed(_remote_reason if _remote_reason != "" else "connection lost", true)

	func _update_rtt() -> void:
		stats.rtt = _peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME) / 1000.0


## HostListener accepts connections on one ENet host.
class HostListener:
	extends Listener
	var _host: ENetConnection
	var _address: String
	var _peers := {}
	var _pending: Array[Conn] = []

	func _init(host: ENetConnection, at: String) -> void:
		_host = host
		_address = at

	func accept() -> Conn:
		if _pending.is_empty():
			return null
		return _pending.pop_front()

	func poll() -> void:
		if _host == null:
			return
		while true:
			var event := _host.service(0)
			var type: int = event[0]
			if type == ENetConnection.EVENT_NONE or type == ENetConnection.EVENT_ERROR:
				break
			var peer: ENetPacketPeer = event[1]
			match type:
				ENetConnection.EVENT_CONNECT:
					var conn := Peer.new(peer)
					_peers[peer] = conn
					_pending.append(conn)
				ENetConnection.EVENT_RECEIVE:
					var conn: Peer = _peers.get(peer)
					var payload := peer.get_packet()
					if conn != null:
						conn._received(event[3], payload)
				ENetConnection.EVENT_DISCONNECT:
					var conn: Peer = _peers.get(peer)
					if conn != null:
						conn._disconnected()
						_peers.erase(peer)
		for conn in _peers.values():
			conn._update_rtt()

	func flush() -> void:
		if _host != null:
			_host.flush()

	func close() -> void:
		if _host == null:
			return
		for conn in _peers.values():
			conn.close("server is shutting down")
		_host.flush()
		_host.destroy()
		_host = null
		_peers.clear()

	func address() -> String:
		return _address


## Client is the client's end, with its own ENet host.
class Client:
	extends Peer
	var _host: ENetConnection
	var _connected := false

	func _init(host: ENetConnection, peer: ENetPacketPeer) -> void:
		super(peer)
		_host = host

	func is_ready() -> bool:
		return _connected

	func poll() -> void:
		if _host == null:
			return
		while true:
			var event := _host.service(0)
			var type: int = event[0]
			if type == ENetConnection.EVENT_NONE:
				break
			if type == ENetConnection.EVENT_ERROR:
				_mark_closed("network error", true)
				break
			match type:
				ENetConnection.EVENT_CONNECT:
					_connected = true
				ENetConnection.EVENT_RECEIVE:
					_received(event[3], (event[1] as ENetPacketPeer).get_packet())
				ENetConnection.EVENT_DISCONNECT:
					_disconnected()
		if _connected and is_open():
			_update_rtt()
		if _host != null:
			_host.flush()
		if not is_open() and _host != null and _peer.get_state() == ENetPacketPeer.STATE_DISCONNECTED:
			_host.destroy()
			_host = null

	func send_reliable(channel: int, payload: PackedByteArray) -> Error:
		if not _connected:
			return ERR_CONNECTION_ERROR
		return super(channel, payload)

	func send_unreliable(payload: PackedByteArray) -> Error:
		if not _connected:
			return ERR_CONNECTION_ERROR
		return super(payload)

	func close(reason: String) -> void:
		if not is_open():
			return
		if not _connected:
			_mark_closed(reason, false)
			_peer.peer_disconnect_now()
			_host.destroy()
			_host = null
			return
		super(reason)
		_host.flush()

	## finish waits briefly for the close to reach the server and frees the
	## socket; for a program that exits right after closing.
	func finish(timeout_msec: int = 200) -> void:
		var deadline := Time.get_ticks_msec() + timeout_msec
		while _host != null and Time.get_ticks_msec() < deadline:
			poll()
			OS.delay_msec(5)
		if _host != null:
			_host.destroy()
			_host = null
