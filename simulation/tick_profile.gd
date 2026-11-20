class_name TickProfile
extends RefCounted
## TickProfile measures where tick time goes, per system, between two log
## lines.

enum System { EVENTS, PLAYERS, BOTS, SHOTS, GRID, HISTORY, SNAPSHOTS }
const NAMES := ["events", "players", "bots", "shots", "grid", "history", "snapshots"]

var ticks := 0
## total and longest are in microseconds, like systems.
var total := 0
var longest := 0
var systems := PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
var missed_commands := 0
## shots counts the shots fired, hits those that struck a soldier, and kills
## the soldiers that died.
var shots := 0
var hits := 0
var kills := 0
## snapshot_bytes counts what snapshots cost on the wire, with the estimated
## overhead of every datagram.
var snapshot_bytes := 0
var _mark := 0


func start() -> void:
	_mark = Time.get_ticks_usec()


## lap charges the time since the previous lap to a system.
func lap(system: int) -> void:
	var now := Time.get_ticks_usec()
	systems[system] += now - _mark
	_mark = now


func finish(started: int) -> void:
	var elapsed := Time.get_ticks_usec() - started
	ticks += 1
	total += elapsed
	longest = maxi(longest, elapsed)


## describe reports the average and longest tick and the average share of each
## system.
func describe() -> String:
	if ticks == 0:
		return "no ticks"
	var text := "tick avg=%s max=%s |" % [_duration(total / ticks), _duration(longest)]
	for i in NAMES.size():
		text += " %s=%s" % [NAMES[i], _duration(systems[i] / ticks)]
	return text


static func _duration(microseconds: int) -> String:
	if microseconds >= 1000:
		return "%.2fms" % (microseconds / 1000.0)
	return "%dµs" % microseconds
