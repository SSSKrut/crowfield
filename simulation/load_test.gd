class_name LoadTest
extends Node
## LoadTest runs headless clients against a server:
## they play with random input through the whole path of a real client —
## ENet with DTLS, the protocol, the clock, prediction and snapshot deltas —
## but draw nothing. They run in processes of their own, as real clients do,
## a few per process. Without -connect it starts its own server with bots
## on the loopback address.
##
##   godot --headless --path . -- loadtest -clients=16 -bots=256 -duration=10m -report=60s
##
## Every report shows per client the ticks and snapshots per second, the
## traffic, clock jumps, corrections of the prediction (and how many of them
## only of the weapons), shots, late commands, datagrams without a delta base,
## and the memory of the processes. At the end it prints how the memory changed
## since the first report. If a client dropped or a delta found no base, it
## exits with an error.

var _settings := {}
var _server: Server
var _runner: ServerRunner
var _listener: Listener
var _directory := ""
var _processes := PackedInt32Array()
var _started := 0.0
var _next_report := 0.0
var _last := {}
var _first_memory := -1
var _failures := 0
var _finished := false


static func create(arguments: PackedStringArray) -> Node:
	var node := LoadTest.new()
	node.name = "LoadTest"
	node.set_meta("arguments", arguments)
	return node


func _ready() -> void:
	var flags := Flags.new()
	flags.define("clients", 16, "headless clients")
	flags.define("per-process", 2, "headless clients in each process")
	flags.define("connect", "", "server address; without it the load test starts its own")
	flags.define("fingerprint", "", "certificate fingerprint of the -connect server")
	flags.define("bots", 256, "bots of the own server")
	flags.define("bot-ai", false, "let the bots of the own server fight; by default they only roam")
	flags.define("map", "prototype", "map of the own server: %s" % ", ".join(MapScene.MAPS))
	flags.define("listen", "127.0.0.1:47800", "UDP address of the own server")
	flags.define("duration", Flags.Duration.new(60), "how long to play")
	flags.define("report", Flags.Duration.new(10), "how often to report")
	flags.define("netsim", "", "simulated network conditions of every client")
	flags.define("seed", 1, "seed of the random input")
	var error := flags.parse(get_meta("arguments"))
	if error == "help":
		print("usage: godot --headless --path . -- loadtest [flags]\n" + flags.usage())
		get_tree().quit()
		return
	if error != "":
		Main.fail(self, error)
		return
	for name in ["clients", "per-process", "connect", "fingerprint", "bots", "bot-ai", "map", "listen", "duration", "report", "netsim", "seed"]:
		_settings[name] = flags.get_value(name)
	var address: String = _settings["connect"]
	var fingerprint: String = _settings["fingerprint"]
	if address == "":
		var started: Array = _start_server()
		if started[1] != "":
			Main.fail(self, started[1])
			return
		address = _settings["listen"]
		fingerprint = started[0]
	_directory = OS.get_user_data_dir().path_join("loadtest-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_directory)
	var per_process: int = maxi(1, _settings["per-process"])
	var first := 0
	while first < _settings["clients"]:
		var count := mini(per_process, _settings["clients"] - first)
		var arguments := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--", "loadclient",
			"-connect", address, "-fingerprint", fingerprint, "-clients", str(count), "-first", str(first),
			"-seed", str(_settings["seed"]), "-report", _directory.path_join("clients-%d.jsonl" % first)])
		if _settings["netsim"] != "":
			arguments.append_array(["-netsim", _settings["netsim"]])
		var pid := OS.create_process(OS.get_executable_path(), arguments)
		if pid < 0:
			Main.fail(self, "cannot start a client process")
			return
		_processes.append(pid)
		first += count
	_started = ClientSession._now()
	_next_report = _started + _settings["report"]
	print("load test: %d clients in %d processes on %s for %d s" % [_settings["clients"], _processes.size(), address, int(_settings["duration"])])


## _start_server starts the own server with bots. It returns [the
## fingerprint of its certificate, error].
func _start_server() -> Array:
	var settings := ServerSettings.new()
	settings.bots = _settings["bots"]
	settings.bot_ai = _settings["bot-ai"]
	settings.map = _settings["map"]
	settings.seed = _settings["seed"]
	settings.stats_interval = _settings["report"]
	var made: Variant = Server.create(settings, Rules.new())
	if made is String:
		return ["", made]
	_server = made
	var certificate := Certificates.generate()
	_server.certificate_pem = Certificates.pem(certificate[0])
	var listener: Variant = ENetTransport.listen(_settings["listen"], Certificates.server_options(certificate[0], certificate[1]))
	if listener is String:
		return ["", listener]
	_listener = listener
	_server.add_listener(_listener)
	Engine.max_fps = 1000
	_runner = ServerRunner.new(_server)
	add_child(_runner)
	return [Certificates.fingerprint(certificate[0]), ""]


func _process(_delta: float) -> void:
	if _finished or _directory == "":
		return
	var now := ClientSession._now()
	if now - _started >= _settings["duration"]:
		_report(now)
		_finish()
	elif now >= _next_report:
		_next_report += _settings["report"]
		_report(now)


## _report reads the newest line of every client and prints the rates since
## the last report.
func _report(now: float) -> void:
	var lines := _newest()
	var memory := {}
	var interval := float(_settings["report"])
	print("--- %d s" % roundi(now - _started))
	for client in range(_settings["clients"]):
		var line: Dictionary = lines.get(client, {})
		if line.is_empty():
			print("client %2d: no report yet" % client)
			continue
		if line.get("error", "") != "":
			print("client %2d: FAILED %s" % [client, line["error"]])
			continue
		var last: Dictionary = _last.get(client, {})
		var span := maxf(1e-3, interval if not last.is_empty() else now - _started)
		var rate := func(key: String) -> float: return (float(line.get(key, 0)) - float(last.get(key, 0))) / span
		print("client %2d: ticks %.1f/s snapshots %.1f/s %.1f KB/s jumps %d corrections %d (weapons %d, largest %.3f m) shots %d hits %d kills %d deaths %d late %d unresolved %d lead %.1f soldiers %d" % [
			client, rate.call("ticks"), rate.call("snapshots"), rate.call("bytes") / 1024, line.get("jumps", 0),
			line.get("corrections", 0), line.get("weapon_corrections", 0), line.get("largest_correction", 0.0),
			line.get("shots", 0), line.get("hits", 0), line.get("kills", 0), line.get("deaths", 0), line.get("late", 0),
			line.get("unresolved", 0), line.get("lead", 0.0), line.get("soldiers", 0)])
		memory[client / maxi(1, _settings["per-process"])] = line.get("memory", 0)
		_last[client] = line
	var total := 0
	for value in memory.values():
		total += value
	if _first_memory < 0 and total > 0:
		_first_memory = total
	print("client processes: %d, memory %.1f MB" % [memory.size(), total / 1048576.0])


## _newest is the last line each client wrote, by client number.
func _newest() -> Dictionary:
	var lines := {}
	for file in DirAccess.get_files_at(_directory):
		for text in FileAccess.get_file_as_string(_directory.path_join(file)).split("\n", false):
			var parsed: Variant = JSON.parse_string(text)
			if parsed is Dictionary and parsed.has("client"):
				lines[int(parsed["client"])] = parsed
	return lines


func _finish() -> void:
	_finished = true
	var lines := _newest()
	var memory := {}
	for client in range(_settings["clients"]):
		var line: Dictionary = lines.get(client, {})
		if line.is_empty() or line.get("error", "") != "" or not line.get("joined", false) or int(line.get("unresolved", 0)) > 0:
			_failures += 1
		memory[client / maxi(1, _settings["per-process"])] = line.get("memory", 0)
	var total := 0
	for value in memory.values():
		total += value
	if _first_memory > 0:
		print("client memory: %.1f MB at the first report, %.1f MB at the end (%+.1f%%)" % [
			_first_memory / 1048576.0, total / 1048576.0, 100.0 * (total - _first_memory) / _first_memory])
	if _server != null:
		print("server: tick=%d hits=%d" % [_server.tick, _server.total_hits])
	for pid in _processes:
		OS.kill(pid)
	for file in DirAccess.get_files_at(_directory):
		DirAccess.remove_absolute(_directory.path_join(file))
	DirAccess.remove_absolute(_directory)
	if _failures > 0:
		printerr("%d clients failed, dropped or lost a delta base" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _exit_tree() -> void:
	if _server != null:
		_server.close()
	if _listener != null:
		_listener.close()
