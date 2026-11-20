class_name SimulatedConn
extends Conn
## SimulatedConn wraps a connection with network conditions in both
## directions: delay and jitter, loss and duplication of datagrams. Reliable
## messages are only delayed and stay in order. It works over any Conn,
## including the in-memory one of solo play, where a ping of 100 ms is the
## main way to debug prediction.

var inner: Conn
var conditions: NetworkConditions
var _random := RandomNumberGenerator.new()
## _scheduled holds deliveries as [due time, order, direction, channel,
## payload]: direction 0 sends to the inner connection, 1 hands to the reader.
## channel -1 marks a datagram.
var _scheduled: Array = []
var _order := 0
## _last_ordered keeps the latest due time of each reliable lane, so that a
## message is never delivered before an earlier one of its lane.
var _last_ordered := {}
var _dropped := 0


func _init(wrapped: Conn, network: NetworkConditions) -> void:
	inner = wrapped
	conditions = network
	if network.seed != 0:
		_random.seed = network.seed
	else:
		_random.randomize()


func send_reliable(channel: int, payload: PackedByteArray) -> Error:
	if not is_open():
		return ERR_CONNECTION_ERROR
	var error := Conn.check_send(channel, payload)
	if error != OK:
		return error
	stats.messages_sent += 1
	stats.bytes_sent += payload.size()
	_schedule_ordered(0, channel, payload)
	return OK


func send_unreliable(payload: PackedByteArray) -> Error:
	if not is_open():
		return ERR_CONNECTION_ERROR
	if payload.size() > inner.max_unreliable_size():
		return ERR_INVALID_PARAMETER
	stats.datagrams_sent += 1
	stats.bytes_sent += payload.size()
	_schedule_datagram(0, payload)
	return OK


func max_unreliable_size() -> int:
	return inner.max_unreliable_size()


func is_ready() -> bool:
	return inner.is_ready()


func poll() -> void:
	inner.poll()
	while true:
		var message := inner.receive_reliable()
		if message.is_empty():
			break
		_schedule_ordered(1, message[0], message[1])
	while true:
		var datagram := inner.receive_unreliable()
		if datagram.is_empty():
			break
		_schedule_datagram(1, datagram)
	var now := _now()
	var due: Array = []
	var waiting: Array = []
	for item in _scheduled:
		if item[0] <= now:
			due.append(item)
		else:
			waiting.append(item)
	_scheduled = waiting
	due.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for item in due:
		_deliver(item)
	inner.poll()
	stats.rtt = inner.stats.rtt + 2 * (conditions.delay + conditions.jitter / 2)
	stats.datagrams_dropped = _dropped
	if not inner.is_open() and is_open() and _pending_inbound() == 0:
		_mark_closed(inner.close_reason, inner.closed_by_peer)


func close(reason: String) -> void:
	if not is_open():
		return
	_mark_closed(reason, false)
	_scheduled.clear()
	inner.close(reason)


func _deliver(item: Array) -> void:
	var direction: int = item[2]
	var channel: int = item[3]
	var payload: PackedByteArray = item[4]
	if direction == 0:
		if channel < 0:
			inner.send_unreliable(payload)
		else:
			inner.send_reliable(channel, payload)
	elif is_open():
		if channel < 0:
			_deliver_datagram(payload)
		else:
			_deliver_reliable(channel, payload)


func _schedule_datagram(direction: int, payload: PackedByteArray) -> void:
	if _random.randf() < conditions.loss:
		_dropped += 1
		return
	_schedule(_now() + _delay(), direction, -1, payload)
	if _random.randf() < conditions.duplicate:
		_schedule(_now() + _delay(), direction, -1, payload)


func _schedule_ordered(direction: int, channel: int, payload: PackedByteArray) -> void:
	var lane := direction * Conn.CHANNELS + channel
	var at: float = maxf(_now() + _delay(), _last_ordered.get(lane, 0.0))
	_last_ordered[lane] = at
	_schedule(at, direction, channel, payload)


func _schedule(at: float, direction: int, channel: int, payload: PackedByteArray) -> void:
	_order += 1
	_scheduled.append([at, _order, direction, channel, payload])


func _delay() -> float:
	var delay := conditions.delay
	if conditions.jitter > 0:
		delay += _random.randf() * conditions.jitter
	return delay


func _pending_inbound() -> int:
	var count := 0
	for item in _scheduled:
		if item[2] == 1:
			count += 1
	return count


static func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0
