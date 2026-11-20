class_name ServerSettings
extends RefCounted
## ServerSettings configure a server, dedicated or embedded in a client. Times
## are in seconds.

## DEFAULT_CLIENT_BANDWIDTH is 32 KB/s (ARCHITECTURE.md, 6.6).
const DEFAULT_CLIENT_BANDWIDTH := 32 * 1024

var stats_interval := 5.0
## run_duration stops the server by itself; zero runs until it is stopped.
var run_duration := 0.0
var listen := ":7777"
var certificate := "server.crt"
var key := "server.key"
var tuning := ""
## weapons overrides the weapon tuning; clients must use the same.
var weapons := ""
var max_players := 16
## snapshot_rate is how many snapshots per second each client receives; it
## must divide the tick rate.
var snapshot_rate := 20
## dummies are bot soldiers without AI that roam the map, to load the network
## and the clients until real bots exist.
var dummies := 0
## seed fixes the match seed, which places the dummies, for runs that repeat;
## zero picks a random one.
var seed := 0
## A player who sends no input for input_timeout is disconnected; one whose
## connection was lost keeps its place for reconnect_window.
var input_timeout := 5.0
var reconnect_window := 60.0
## A dead soldier comes back after respawn_delay.
var respawn_delay := 5.0
## friendly_fire lets shots hurt soldiers of the shooter's own team.
var friendly_fire := false
## allow_respawn lets a player ask to go back to its spawn with full health
## and ammo, a debug aid of solo play.
var allow_respawn := false
## dummy_deaths kills that many dummies a second, struck at random, to load
## the deaths of clients.
var dummy_deaths := 0.0
## max_rewind bounds how far back in time lag compensation tests a shot; a
## player who saw further back is tested at the limit. It covers a round trip
## of 200 ms with jitter: the player also sees the others an interpolation
## delay late, and its commands come early.
var max_rewind := 0.5
## client_bandwidth is the snapshot budget of each client in bytes per
## second, transport overhead included.
var client_bandwidth := DEFAULT_CLIENT_BANDWIDTH


func validate() -> String:
	if max_players < 1 or max_players > Game.MAX_PLAYERS:
		return "max players must be in 1..%d" % Game.MAX_PLAYERS
	if snapshot_rate < 1 or Game.TICK_RATE % snapshot_rate != 0:
		return "snapshot rate %d does not divide the tick rate %d" % [snapshot_rate, Game.TICK_RATE]
	if client_bandwidth <= 0:
		return "client bandwidth %d is not positive" % client_bandwidth
	if input_timeout <= 0 or reconnect_window <= 0 or respawn_delay <= 0 or max_rewind <= 0:
		return "timeouts, the respawn delay and the rewind limit must be positive"
	if max_rewind * Game.TICK_RATE >= PoseHistory.TICKS:
		return "max rewind %.2f s is not shorter than the history of %.2f s" % [max_rewind, float(PoseHistory.TICKS) / Game.TICK_RATE]
	if dummies < 0 or max_players + dummies > SoldierSet.MAX_SOLDIERS:
		return "at most %d soldiers fit, %d players and %d dummies asked" % [SoldierSet.MAX_SOLDIERS, max_players, dummies]
	if dummy_deaths < 0:
		return "dummy deaths must not be negative"
	return ""
