class_name ServerRunner
extends Node
## ServerRunner ticks a server in real time, 60 times a second, whatever the
## frame rate of the process: a late frame runs the ticks it owes, and a stall
## longer than a quarter second is forgiven rather than caught up. Every
## stats_interval it logs the tick rate, the tick profile and the traffic.

signal finished

var server: Server
var _next_usec := 0
var _last_stats_usec := 0
var _started_usec := 0


func _init(simulation: Server) -> void:
	server = simulation
	name = "ServerRunner"


func _ready() -> void:
	_next_usec = Time.get_ticks_usec()
	_last_stats_usec = _next_usec
	_started_usec = _next_usec


## Keep paused wall time out of the tick schedule and statistics.
func defer_clock(duration_usec: int) -> void:
	_next_usec += duration_usec
	_last_stats_usec += duration_usec
	_started_usec += duration_usec


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var ran := 0
	while now >= _next_usec and ran < 8:
		server.step()
		ran += 1
		_next_usec += 1000000 / Game.TICK_RATE + (1 if server.tick % 3 != 0 else 0)
		now = Time.get_ticks_usec()
	if now - _next_usec > 250000:
		_next_usec = now
	_log_stats(now)
	var settings := server.settings
	if settings.run_duration > 0 and now - _started_usec >= settings.run_duration * 1000000:
		print("server stopped: tick=%d soldiers=%d" % [server.tick, server.soldiers.count()])
		finished.emit()
		set_process(false)


func _log_stats(now: int) -> void:
	var interval := server.settings.stats_interval
	var since := (now - _last_stats_usec) / 1000000.0
	if interval <= 0 or since < interval:
		return
	var profile := server.profile
	var players := server.player_count()
	print("server running: tick=%d rate=%.1f players=%d soldiers=%d missed_commands=%d dropped_inputs=%d shots=%d hits=%d kills=%d snapshots=%.1fKB/s/player memory=%.1fMB %s" % [
		server.tick, profile.ticks / since, players, server.soldiers.count(), profile.missed_commands,
		server.dropped_inputs, profile.shots, profile.hits, profile.kills,
		profile.snapshot_bytes / 1024.0 / since / maxi(1, players),
		OS.get_static_memory_usage() / 1048576.0, profile.describe()])
	server.dropped_inputs = 0
	server.profile = TickProfile.new()
	_last_stats_usec = now
