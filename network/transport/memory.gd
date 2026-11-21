class_name Memory
## Memory connects the client and the server of one process: solo play reaches
## the embedded server through it. Messages still travel as encoded bytes with
## the limits of the network, so that what works in solo play works over the
## network too.


## pair returns two connected ends: [client, server].
static func pair() -> Array[Conn]:
	var first := End.new()
	var second := End.new()
	first._peer = weakref(second)
	second._peer = weakref(first)
	return [first, second]


class End:
	extends Conn
	# The callers own the ends. Each end only borrows the other while sending.
	var _peer: WeakRef

	func is_open() -> bool:
		if super.is_open() and (_peer == null or _peer.get_ref() == null):
			_mark_closed("peer disconnected", true)
		return super.is_open()

	func send_reliable(channel: int, payload: PackedByteArray) -> Error:
		if not is_open():
			return ERR_CONNECTION_ERROR
		var error := Conn.check_send(channel, payload)
		if error != OK:
			return error
		stats.messages_sent += 1
		stats.bytes_sent += payload.size()
		var peer := _peer.get_ref() as End
		if peer != null and peer.is_open() and not peer._deliver_reliable(channel, payload):
			peer._mark_closed("receive queue overflowed", false)
			_mark_closed("peer does not read its reliable messages", false)
			return ERR_OUT_OF_MEMORY
		return OK

	func send_unreliable(payload: PackedByteArray) -> Error:
		if not is_open():
			return ERR_CONNECTION_ERROR
		if payload.size() > MAX_DATAGRAM_SIZE:
			return ERR_INVALID_PARAMETER
		stats.datagrams_sent += 1
		stats.bytes_sent += payload.size()
		var peer := _peer.get_ref() as End
		if peer != null and peer.is_open():
			peer._deliver_datagram(payload)
		return OK

	func close(reason: String) -> void:
		if not is_open():
			return
		_mark_closed(reason, false)
		var peer := _peer.get_ref() as End
		if peer != null:
			peer._mark_closed(reason, true)


## Listener lets the embedded server accept the client of its own process
## with the same accept as network clients.
class MemoryListener:
	extends Listener
	var _pending: Array[Conn] = []
	var _closed := false
	var _accepted: Array[Conn] = []

	## dial returns the client end of a new connection, whose server end the
	## next accept returns; null once the listener is closed.
	func dial() -> Conn:
		if _closed:
			return null
		var ends := Memory.pair()
		_pending.append(ends[1])
		return ends[0]

	func accept() -> Conn:
		if _pending.is_empty():
			return null
		var conn: Conn = _pending.pop_front()
		_accepted.append(conn)
		return conn

	func close() -> void:
		_closed = true
		for conn in _pending:
			conn.close("listener closed")
		_pending.clear()
		for conn in _accepted:
			conn.close("listener closed")
		_accepted.clear()

	func address() -> String:
		return "memory"
