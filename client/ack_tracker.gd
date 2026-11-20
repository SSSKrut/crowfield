class_name AckTracker
extends RefCounted
## AckTracker remembers which snapshot datagrams arrived: the newest sequence
## and a bit for each of the 32 before it.

var has := false
var latest := 0
var bits := 0


func observe(sequence: int) -> void:
	if not has:
		has = true
		latest = sequence
		bits = 0
		return
	var distance := Game.sequence_difference(sequence, latest)
	if distance > 32:
		latest = sequence
		bits = 0
	elif distance > 0:
		latest = sequence
		bits = ((bits << distance) | (1 << (distance - 1))) & 0xFFFFFFFF
	elif distance < 0 and -distance <= 32:
		bits |= 1 << (-distance - 1)
