class_name ConnStats
extends RefCounted
## ConnStats counts payloads, not transport overhead. datagrams_dropped counts
## the datagrams this side dropped: overflowing queues and simulated loss.

## rtt is the round trip time in seconds, as far as the transport knows it.
var rtt := 0.0
var datagrams_sent := 0
var datagrams_received := 0
var datagrams_dropped := 0
var messages_sent := 0
var messages_received := 0
var bytes_sent := 0
var bytes_received := 0


func copy() -> ConnStats:
	var other := ConnStats.new()
	other.rtt = rtt
	other.datagrams_sent = datagrams_sent
	other.datagrams_received = datagrams_received
	other.datagrams_dropped = datagrams_dropped
	other.messages_sent = messages_sent
	other.messages_received = messages_received
	other.bytes_sent = bytes_sent
	other.bytes_received = bytes_received
	return other
