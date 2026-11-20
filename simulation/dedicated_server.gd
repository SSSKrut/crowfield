class_name DedicatedServer
extends Node
## DedicatedServer runs a server without a window or sound:
##
##   godot --headless --path . -- server -listen :7777 -bots=64
##
## On the first run it creates server.crt and server.key next to it and prints
## the certificate fingerprint; the key is kept, so the fingerprint stays.

var _server: Server
var _listener: Listener


static func create(arguments: PackedStringArray) -> Node:
	var node := DedicatedServer.new()
	node.name = "DedicatedServer"
	node.set_meta("arguments", arguments)
	return node


static func define_flags(flags: Flags, settings: ServerSettings) -> void:
	flags.define("stats", Flags.Duration.new(settings.stats_interval), "statistics logging interval")
	flags.define("duration", Flags.Duration.new(0), "stop after this duration")
	flags.define("listen", settings.listen, "UDP address for clients")
	flags.define("cert", settings.certificate, "certificate file, created on the first run")
	flags.define("key", settings.key, "private key file, created on the first run")
	flags.define("tuning", "", "JSON file overriding movement tuning; clients need the same")
	flags.define("weapons", "", "JSON file overriding weapon tuning; clients need the same")
	flags.define("max-players", settings.max_players, "maximum number of human players")
	flags.define("snapshot-rate", settings.snapshot_rate, "snapshots per second; must divide the tick rate")
	flags.define("map", "valley", "map to play: %s" % ", ".join(MapScene.MAPS))
	flags.define("bots", 0, "bot soldiers, half of them in each team")
	flags.define("bot-ai", true, "let bots look for enemies and fight; false only lets them roam, for load tests")
	flags.define("seed", 0, "match seed for repeatable runs; 0 picks a random one")
	flags.define("input-timeout", Flags.Duration.new(settings.input_timeout), "disconnect a player who sends no input this long")
	flags.define("reconnect-window", Flags.Duration.new(settings.reconnect_window), "keep the place of a lost player this long")
	flags.define("respawn-delay", Flags.Duration.new(settings.respawn_delay), "how long the dead wait to come back")
	flags.define("friendly-fire", false, "let shots hurt the shooter's own team")
	flags.define("allow-respawn", false, "let players go back to their spawn with full health at will, for testing")
	flags.define("max-rewind", Flags.Duration.new(settings.max_rewind), "how far back lag compensation looks")
	flags.define("bot-deaths", 0.0, "bots killed at random every second, to load the clients")
	flags.define("client-bandwidth", settings.client_bandwidth / 1024, "snapshot budget of each client, KB/s")


static func read_flags(flags: Flags, settings: ServerSettings) -> void:
	settings.stats_interval = flags.get_value("stats")
	settings.run_duration = flags.get_value("duration")
	settings.listen = flags.get_value("listen")
	settings.certificate = flags.get_value("cert")
	settings.key = flags.get_value("key")
	settings.tuning = flags.get_value("tuning")
	settings.weapons = flags.get_value("weapons")
	settings.max_players = flags.get_value("max-players")
	settings.snapshot_rate = flags.get_value("snapshot-rate")
	settings.map = flags.get_value("map")
	settings.bots = flags.get_value("bots")
	settings.bot_ai = flags.get_value("bot-ai")
	settings.seed = flags.get_value("seed")
	settings.input_timeout = flags.get_value("input-timeout")
	settings.reconnect_window = flags.get_value("reconnect-window")
	settings.respawn_delay = flags.get_value("respawn-delay")
	settings.friendly_fire = flags.get_value("friendly-fire")
	settings.allow_respawn = flags.get_value("allow-respawn")
	settings.max_rewind = flags.get_value("max-rewind")
	settings.bot_deaths = flags.get_value("bot-deaths")
	settings.client_bandwidth = flags.get_value("client-bandwidth") * 1024


func _ready() -> void:
	var settings := ServerSettings.new()
	var flags := Flags.new()
	define_flags(flags, settings)
	var error := flags.parse(get_meta("arguments"))
	if error == "help":
		print("usage: godot --headless --path . -- server [flags]\n" + flags.usage())
		get_tree().quit()
		return
	if error != "":
		Main.fail(self, error)
		return
	read_flags(flags, settings)
	var rules: Variant = Rules.load_files(settings.tuning, settings.weapons)
	if rules is String:
		Main.fail(self, rules)
		return
	var certificate: Variant = Certificates.load_or_create(settings.certificate, settings.key)
	if certificate is String:
		Main.fail(self, certificate)
		return
	var made: Variant = Server.create(settings, rules)
	if made is String:
		Main.fail(self, made)
		return
	_server = made
	_server.certificate_pem = Certificates.pem(certificate[0])
	var listener: Variant = ENetTransport.listen(settings.listen, Certificates.server_options(certificate[0], certificate[1]))
	if listener is String:
		Main.fail(self, listener)
		return
	_listener = listener
	_server.add_listener(_listener)
	# The server needs no frames, only ticks: a short sleep between frames
	# keeps it from spinning a core.
	Engine.max_fps = 1000
	OS.low_processor_usage_mode = false
	var runner := ServerRunner.new(_server)
	runner.finished.connect(func() -> void: get_tree().quit())
	add_child(runner)
	print("server started: map=%s bots=%d tick_rate=%d snapshot_rate=%d client_bandwidth=%dKB/s listen=%s" % [
		settings.map, settings.bots, Game.TICK_RATE, settings.snapshot_rate, settings.client_bandwidth / 1024, settings.listen])
	print("certificate fingerprint %s" % Certificates.fingerprint(certificate[0]))


func _exit_tree() -> void:
	if _server != null:
		_server.close()
	if _listener != null:
		_listener.close()
