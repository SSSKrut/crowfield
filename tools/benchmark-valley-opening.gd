extends SceneTree
## Run with Godot --headless --path . --script tools/benchmark-valley-opening.gd.
## Times are simulation seconds from round start. A value of -1 means the
## event did not occur within 45 seconds. Friendly fire is disabled.

const SEEDS := [3, 9, 17, 31, 101]
const RUN_SECONDS := 45


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for seed_value in SEEDS:
		var settings := ServerSettings.new()
		settings.map = "valley"
		settings.bots = 24
		settings.seed = seed_value
		var server: Server = Server.create(settings, Rules.new())
		server.flag_match.started = true
		var first_damage := {Game.Team.BLUE: -1, Game.Team.RED: -1}
		var first_contest := -1
		var first_capture := -1
		var first_flag := [-1, -1, -1]
		for tick in Game.TICK_RATE * RUN_SECONDS:
			server.step()
			for slot in server.soldiers.slots():
				var soldier := server.soldiers.at(slot)
				if soldier != null and soldier.health < Game.MAX_HEALTH and first_damage[soldier.team] < 0:
					first_damage[soldier.team] = tick
			for index in server.flag_match.state.flags.size():
				var flag := server.flag_match.state.flags[index]
				if first_contest < 0 and flag.contested:
					first_contest = tick
				if first_capture < 0 and flag.owner != Game.Team.NONE:
					first_capture = tick
				if first_flag[index] < 0 and (flag.owner != Game.Team.NONE or flag.contested or flag.progress > 0):
					first_flag[index] = tick
		print(JSON.stringify({
			"seed": seed_value,
			"blue_takes_damage_s": _seconds(first_damage[Game.Team.BLUE]),
			"red_takes_damage_s": _seconds(first_damage[Game.Team.RED]),
			"first_contest_s": _seconds(first_contest),
			"first_capture_s": _seconds(first_capture),
			"first_objective_activity_s": first_flag.map(_seconds),
		}))
		server.close()
	quit()


func _seconds(tick: int) -> float:
	return snappedf(float(tick) / Game.TICK_RATE, 0.01) if tick >= 0 else -1.0
