class_name InterpolationClock
extends RefCounted
## InterpolationClock is the client's view of server time minus the
## interpolation delay. It runs with the frame clock and is pulled gently
## towards each snapshot, so jitter does not shake the remote soldiers.

## SNAPSHOTS is the delay in snapshot intervals: with one snapshot lost there
## is still a later one to interpolate towards.
const SNAPSHOTS := 2

var render_tick := 0.0
var delay := 0.0
var started := false


func _init(snapshot_rate: int) -> void:
	var interval := float(Game.TICK_RATE) / maxi(1, snapshot_rate)
	delay = SNAPSHOTS * interval + 1


func observe(server_tick: int) -> void:
	var target := server_tick - delay
	if not started or absf(target - render_tick) > 30:
		render_tick = target
		started = true
		return
	render_tick += (target - render_tick) * 0.1


func advance(delta: float) -> void:
	render_tick += delta * Game.TICK_RATE
