class_name LoadClient
extends Node
## LoadClient is one process of the load test (simulation/load_test.gd): it
## plays a few headless clients on a server, each at the pace of its own
## session clock, and appends what they counted to a report file every
## second, one JSON line per client. It ends when its clients stop, or when
## the report file's directory goes away.

var _settings := {}
var _clients: Array[HeadlessClient] = []
var _connectors: Array[Connector] = []
var _names: PackedStringArray = []
var _next: PackedFloat64Array = []
var _space: RID
var _collision: Array[RID] = []
var _scene: MapScene
var _rules: Rules
var _conditions: NetworkConditions
var _report_at := 0.0
var _joined := 0


static func create(arguments: PackedStringArray) -> Node:
	var node := LoadClient.new()
	node.name = "LoadClient"
	node.set_meta("arguments", arguments)
	return node


func _ready() -> void:
	var flags := Flags.new()
	flags.define("connect", "127.0.0.1:7777", "server address")
	flags.define("fingerprint", "", "certificate fingerprint of the server")
	flags.define("clients", 1, "clients in this process")
	flags.define("first", 0, "number of the first client")
	flags.define("seed", 1, "seed of the random input")
	flags.define("report", "", "file to append the counts to")
	flags.define("netsim", "", "simulated network conditions")
	flags.define("tuning", "", "JSON file overriding movement tuning")
	flags.define("weapons", "", "JSON file overriding weapon tuning")
	var error := flags.parse(get_meta("arguments"))
	if error != "":
		Main.fail(self, error)
		return
	for name in ["connect", "fingerprint", "clients", "first", "seed", "report", "netsim", "tuning", "weapons"]:
		_settings[name] = flags.get_value(name)
	var rules: Variant = Rules.load_files(_settings["tuning"], _settings["weapons"])
	if rules is String:
		Main.fail(self, rules)
		return
	_rules = rules
	var conditions: Variant = NetworkConditions.parse(_settings["netsim"])
	if conditions is String:
		Main.fail(self, conditions)
		return
	_conditions = conditions
	# The clients predict in one space: their capsules do not meet each other.
	# The map goes into it once the server names it.
	_space = PhysicsServer3D.space_create()
	Engine.max_fps = 1000
	for i in _settings["clients"]:
		_names.append("Bot %d" % (_settings["first"] + i))
		_connectors.append(Connector.new(_settings["connect"], _settings["fingerprint"], ""))
		_clients.append(null)
		_next.append(0.0)


func _process(_delta: float) -> void:
	var now := ClientSession._now()
	for i in _clients.size():
		if _clients[i] == null:
			_start(i)
			continue
		var client := _clients[i]
		if client.error != "":
			continue
		var ticks := 0
		while now >= _next[i] and ticks < 8:
			if not client.tick():
				printerr("%s: %s" % [_names[i], client.error])
				break
			_next[i] += client.tick_duration()
			ticks += 1
		if now - _next[i] > 1.0:
			_next[i] = now
	if now >= _report_at:
		_report_at = now + 1.0
		_report()


func _start(i: int) -> void:
	var connector := _connectors[i]
	if connector == null:
		return
	connector.poll()
	if connector.failed():
		printerr("%s: %s" % [_names[i], connector.error])
		_connectors[i] = null
		_report_failure(i, connector.error)
		return
	if not connector.done():
		return
	var conn := connector.conn
	if not _conditions.is_none():
		conn = SimulatedConn.new(conn, _conditions)
	_clients[i] = HeadlessClient.new(conn, _names[i], _rules, _settings["seed"] + _settings["first"] + i, _space, _load_map)
	_connectors[i] = null
	_next[i] = ClientSession._now()
	_joined += 1


## _report appends a line per client: its counts so far, and the memory of
## the process.
func _report() -> void:
	var path: String = _settings["report"]
	if path == "":
		return
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		get_tree().quit()
		return
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	var memory := OS.get_static_memory_usage()
	for i in _clients.size():
		var client := _clients[i]
		if client == null:
			continue
		var session := client.session
		var line := {
			"client": _settings["first"] + i, "error": client.error, "ticks": client.ticks, "memory": memory,
			"joined": client.joined(), "shots": client.shots, "hits": client.hits, "kills": client.kills, "deaths": client.deaths,
			"corrections": client.predictor.corrections, "weapon_corrections": client.predictor.weapon_corrections,
			"largest_correction": client.largest_correction,
		}
		if session != null:
			line.merge({
				"snapshots": session.received, "bytes": session.bytes, "jumps": session.resyncs, "unresolved": session.unresolved,
				"late": session.late, "lead": session.lead, "soldiers": session.soldiers.size(),
			})
		file.store_line(JSON.stringify(line))
	file.close()


func _report_failure(i: int, reason: String) -> void:
	var path: String = _settings["report"]
	if path == "":
		return
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(JSON.stringify({"client": _settings["first"] + i, "error": reason}))
	file.close()


func _exit_tree() -> void:
	for client in _clients:
		if client != null:
			client.close()
	MapScene.free_collision(_collision)
	if _space.is_valid():
		PhysicsServer3D.free_rid(_space)


## _load_map builds the map the server plays in the space of the clients, the
## first time a server names it.
func _load_map(map_name: String) -> Variant:
	if _scene != null:
		return _scene if _scene.name == map_name else "the other clients play %s" % _scene.name
	_scene = MapScene.named(map_name)
	if _scene == null:
		return "the client has no such map"
	_collision = _scene.build_collision(_space)
	return _scene
