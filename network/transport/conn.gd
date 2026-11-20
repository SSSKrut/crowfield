class_name Conn
extends RefCounted
## Conn moves encoded messages between a client and a server. A connection has
## ordered reliable channels for events and unreliable datagrams for input and
## snapshots. It is implemented over ENet, over memory for the embedded
## server, and by a network simulator over either.
##
## Everything is polled: poll() moves what arrived into the receive queues and
## pushes out what was sent. Sending never blocks: the server tick must not
## wait for a slow client. Datagram queues keep the newest datagrams, because a
## stale snapshot is worse than none. A reliable queue that overflows means the
## peer stopped reading, so send_reliable reports it and the caller should drop
## that peer.

enum Channel { CONTROL, EVENTS }
const CHANNELS := 2

## MAX_DATAGRAM_SIZE fits one UDP packet on every path. The snapshot budget of
## 1100 bytes stays below it.
const MAX_DATAGRAM_SIZE := 1200
const MAX_RELIABLE_SIZE := 64 * 1024
const RELIABLE_QUEUE_LIMIT := 256
const DATAGRAM_QUEUE_LIMIT := 128

var stats := ConnStats.new()
## close_reason tells why the connection ended, and closed_by_peer whether the
## peer ended it; both are set once the connection is closed.
var close_reason := ""
var closed_by_peer := false
var _closed := false
var _reliable: Array = []
var _datagrams: Array[PackedByteArray] = []


func is_open() -> bool:
	return not _closed


## is_ready reports whether the connection is established and can carry
## messages; a network connection takes a handshake first.
func is_ready() -> bool:
	return true


## send_reliable queues a message on an ordered reliable channel. It returns
## an error when the connection is closed, the message too large or the queue
## full.
func send_reliable(_channel: int, _payload: PackedByteArray) -> Error:
	return ERR_UNAVAILABLE


## send_unreliable queues a datagram; it may be lost.
func send_unreliable(_payload: PackedByteArray) -> Error:
	return ERR_UNAVAILABLE


## receive_reliable returns the next reliable message as [channel, payload],
## or [] when none is queued. Messages of one channel arrive in order.
func receive_reliable() -> Array:
	if _reliable.is_empty():
		return []
	return _reliable.pop_front()


## receive_unreliable returns the next datagram, or an empty array.
func receive_unreliable() -> PackedByteArray:
	if _datagrams.is_empty():
		return PackedByteArray()
	return _datagrams.pop_front()


func poll() -> void:
	pass


func max_unreliable_size() -> int:
	return MAX_DATAGRAM_SIZE


## close ends the connection at once and tells the peer the reason. Messages
## still queued may be lost.
func close(reason: String) -> void:
	_mark_closed(reason, false)


## _deliver_reliable queues a message that arrived; false when the queue is
## full, which closes the connection.
func _deliver_reliable(channel: int, payload: PackedByteArray) -> bool:
	if _reliable.size() >= RELIABLE_QUEUE_LIMIT:
		_mark_closed("receive queue overflowed", false)
		return false
	_reliable.append([channel, payload])
	stats.messages_received += 1
	stats.bytes_received += payload.size()
	return true


func _deliver_datagram(payload: PackedByteArray) -> void:
	if _datagrams.size() >= DATAGRAM_QUEUE_LIMIT:
		_datagrams.pop_front()
		stats.datagrams_dropped += 1
	_datagrams.append(payload)
	stats.datagrams_received += 1
	stats.bytes_received += payload.size()


func _mark_closed(reason: String, by_peer: bool) -> void:
	if _closed:
		return
	_closed = true
	close_reason = reason
	closed_by_peer = by_peer


static func check_send(channel: int, payload: PackedByteArray) -> Error:
	if channel < 0 or channel >= CHANNELS:
		return ERR_INVALID_PARAMETER
	if payload.size() > MAX_RELIABLE_SIZE:
		return ERR_OUT_OF_MEMORY
	return OK
