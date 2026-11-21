class_name ClientApp
extends Node3D
## ClientApp is the game client. It connects to a server and plays: to the
## server embedded in it in solo play and when hosting, or to the one given by
## -connect. Its world holds the static map for the prediction and the
## cosmetic physics: ragdolls and props. The main menu starts it with flags,
## as the command line does:
##
##   godot --path . -- [flags]
##
## Every frame it reads the input, runs the ticks the clock owes — a command
## sent and predicted for each — applies what the server sent, and draws the
## soldiers in the recent past around the predicted own soldier.

## left asks to end the game: the player chose to leave, with an empty
## message, or the game failed, with the reason.
signal left(message: String)

const RECONNECT_WINDOW := 60.0
const HELP_LINES := [
	"WASD move | Space jump | Shift sprint | LMB fire | RMB aim | R reload | 1-3, wheel weapon",
	"K ragdoll | Backspace respawn | L knock down nearest | F1 physics | F2 network | F3 camera | Esc menu",
	"F4 save playtest state | Shift+F4 save state and screenshot",
]
enum PlaytestCapture { NONE, STATE, IMAGE }
const PLAYTEST_DIR := "user://playtests"
const FRAME_DIAGNOSTIC_WINDOW_USEC := 1000000
const GAME_MENU := preload("res://menu/game_menu.tscn")
const PlaytestTrace := preload("res://client/playtest_trace.gd")
const NATIVE_INPUT_EXTENSION := "res://.godot/playtest-native/native-input.gdextension"
const NATIVE_INPUT_PATH_ENV := "CROWFIELD_NATIVE_INPUT_PATH"
const NATIVE_INPUT_GAMEPLAY_ENV := "CROWFIELD_NATIVE_INPUT_GAMEPLAY"
const MOVE_ACTIONS := ["move_forward", "move_back", "move_left", "move_right"]
const HELD_ACTIONS := MOVE_ACTIONS + ["jump", "sprint", "fire", "aim"]
const TRACE_ACTIONS := HELD_ACTIONS + ["reload", "weapon_1", "weapon_2", "weapon_3", "weapon_next", "weapon_previous"]
const VIRTUAL_INTERFACES := ["lo", "docker", "br-", "veth", "virbr"]

var settings := {}
var rules: Rules
## scene is the map, once the server named it; map_view draws it.
var scene: MapScene
var map_view: MapView
var session: ClientSession
var predictor: Predictor
var asset: CharacterAsset
var pool: RagdollPool
var bodies := Bodies.new()
var soldier_views: SoldierViews
var view_model: ViewModel
var effects: Effects
var sounds: Sounds
var feedback := Feedback.new()
var hud: Hud
var menu: GameMenu
var debug: DebugDraw
var camera: Camera3D
var sun: DirectionalLight3D

var _conditions: NetworkConditions
var _handshake: Handshake
var _connector: Connector
var _local: ServerRunner
var _local_listeners: Array[Listener] = []
## _fingerprint is the certificate fingerprint of a host.
var _fingerprint := ""
var _memory: Memory.MemoryListener
## _self is the own soldier's model, seen in third person and when it falls.
var _self_view: CharacterView
var _self_held: Node3D
var _self_held_kind := -1
var _map_collision: Array[RID] = []
var _accumulator := 0.0
var _alpha := 0.0
var _yaw := 0.0
var _pitch := 0.0
## _look is how far the mouse turned the view this frame.
var _look := Vector2.ZERO
var _mouse := Vector2.ZERO
var _captured := false
var _focused := true
## Latest non-repeat keyboard transition for each movement action.
var _movement_key_events := {}
var _input_trace := PlaytestTrace.new()
var _native_input_loaded := false
var _gameplay_capture_marker := ""
var _gameplay_capture_marked := false
var _weapon := 0
## Keep short gameplay presses until the next command.
var _jump_pressed := false
var _fire_pressed := false
var _reload_pressed := false
## Keep a keyboard movement tap even when key-up arrives before the next tick.
var _movement_pressed := {}
## What the weapons did in the ticks of this frame: shots to show once the
## camera is placed, and events to sound.
var _shots: Array[Shot] = []
var _events := 0
## _buttons are those of the last command, for the look of the weapon.
var _buttons := 0
## _feet is where the own soldier was drawn last; _fallen is its soldier while
## it lies dead, until a new one comes.
var _feet := Vector3.ZERO
var _fallen := 0
## _momentum is the velocity the own soldier was last predicted with.
var _momentum := Vector3.ZERO
var _debug := false
var _third_person := false
var _net_graph := false
var _ragdoll := false
var _elapsed := 0.0
var _demo_cycle := 0
var _played := 0.0
var _net_window := 0.0
var _net_bytes := 0
var _net_rate := 0.0
var _frames := 0
var _frame_started_usec := -1
var _last_frame_usec := 0
var _frame_window_started_usec := 0
var _frame_window_longest_usec := 0
var _previous_frame_window_longest_usec := 0
var _frame_warmup := 1.0
var _frame_stats := FrameStats.new()
var _report := FrameStats.new()
var _knockdowns := 0
## _reconnect is the restoring of a lost connection to a remote server.
var _reconnect_since := -1.0
var _reconnect_reason := ""
var _reconnect_attempts := 0
var _reconnect_next := 0.0
var _lost_token := PackedByteArray()
var _status := "connecting"
var _failed := false
## _profile sums where the frame time goes between two lines of -stats, in
## microseconds: the part of the client, and the embedded server's ticks.
var _profile := {}
var _lap := 0
var _capture_requested := PlaytestCapture.NONE
var _capture_writer: Thread
var _capture_notice := ""
var _capture_notice_until := 0


static func create(arguments: PackedStringArray) -> ClientApp:
	var app := ClientApp.new()
	app.name = "Client"
	app.set_meta("arguments", arguments)
	return app


static func define_flags(flags: Flags) -> void:
	flags.define("width", ProjectSettings.get_setting("display/window/size/viewport_width"), "window width")
	flags.define("height", ProjectSettings.get_setting("display/window/size/viewport_height"), "window height")
	flags.define("frames", 0, "close after this many frames")
	flags.define("exit-on-leave", false, "close the game when leaving a match")
	flags.define("dev-capture-dir", "", "write gameplay.jsonl to this development run directory")
	flags.define("dev-native-input", false, "record local macOS movement key timing when the dev monitor is available")
	flags.define("screenshot", "", "save a screenshot on the final frame")
	flags.define("demo", false, "walk and trigger the ragdoll automatically")
	flags.define("movement", false, "run and jump toward the ramp automatically")
	flags.define("shoot", false, "fire every weapon at the column ahead automatically")
	flags.define("cycles", 1, "number of automatic ragdoll cycles")
	flags.define("debug", false, "show physics shapes")
	flags.define("tuning", "", "JSON file overriding movement tuning")
	flags.define("weapons", "", "JSON file overriding weapon tuning")
	flags.define("volume", 0.5, "sound volume from 0 to 1; 0 is silent")
	flags.define("name", "Player", "player name")
	flags.define("netsim", "", "simulate network conditions, e.g. delay=50ms,jitter=10ms,loss=2%")
	flags.define("host", "", "let other players join on this UDP address, e.g. :7777")
	flags.define("connect", "", "join the server at this address instead of playing solo; the port defaults to %d" % ENetTransport.DEFAULT_PORT)
	flags.define("fingerprint", "", "certificate fingerprint the -connect server must have; remembered after the first connection anyway")
	flags.define("config-dir", OS.get_user_data_dir(), "where remembered servers and the host certificate are kept; empty keeps nothing")
	flags.define("map", "", "map of the embedded server, %s; the valley, or the prototype for -demo, -movement and -shoot" % ", ".join(MapScene.MAPS))
	flags.define("bots", 0, "bot soldiers on the embedded server, half of them in each team")
	flags.define("bot-ai", true, "let the bots fight; false only lets them roam")
	flags.define("bot-deaths", 0.0, "bots of the embedded server killed at random every second")
	flags.define("respawn-delay", Flags.Duration.new(0), "how long the dead of the embedded server wait; 0 is the default")
	flags.define("stats", Flags.Duration.new(0), "log frame rate, memory and ragdolls this often")
	flags.define("overview", false, "watch the whole map from above")
	flags.define("netgraph", false, "show the network graph (F2)")
	flags.define("max-fps", 144, "frame rate cap; 0 leaves it free")
	flags.define("knockdowns", 0, "knock down the nearest soldiers this many times, to load ragdolls")
	flags.define("sensitivity", 0.0025, "mouse sensitivity in radians per pixel")
	flags.define("fov", 75.0, "vertical field of view in degrees")


func _ready() -> void:
	var flags := Flags.new()
	define_flags(flags)
	var error := flags.parse(get_meta("arguments"))
	if error == "help":
		print("usage: godot --path . -- [flags]\n" + flags.usage())
		get_tree().quit()
		return
	if error != "":
		_quit_with(error)
		return
	for name in ["width", "height", "frames", "exit-on-leave", "dev-capture-dir", "dev-native-input", "screenshot", "demo", "movement", "shoot", "cycles", "debug", "tuning",
			"weapons", "volume", "name", "netsim", "host", "connect", "fingerprint", "config-dir", "map", "bots", "bot-ai",
			"bot-deaths", "respawn-delay", "stats", "overview", "netgraph", "max-fps", "knockdowns", "sensitivity", "fov"]:
		settings[name] = flags.get_value(name)
	if settings["dev-capture-dir"] != "":
		var trace_error := _input_trace.start_run(settings["dev-capture-dir"], Time.get_ticks_usec())
		if trace_error != OK:
			_quit_with("could not open gameplay trace: " + error_string(trace_error))
			return
		if OS.get_name() == "macOS" and DisplayServer.get_name() != "headless":
			_gameplay_capture_marker = ProjectSettings.globalize_path(settings["dev-capture-dir"].path_join(".gameplay-captured-pid"))
		if settings["dev-native-input"]:
			_start_native_input_trace(settings["dev-capture-dir"])
	var loaded: Variant = Rules.load_files(settings["tuning"], settings["weapons"])
	if loaded is String:
		_quit_with(loaded)
		return
	rules = loaded
	var conditions: Variant = NetworkConditions.parse(settings["netsim"])
	if conditions is String:
		_quit_with(conditions)
		return
	_conditions = conditions
	_setup_window()
	_build_world()
	# Everything is loaded before connecting: once connected, the client must
	# send a command every tick, and a stall puts its clock behind the server.
	var character: Variant = CharacterAsset.load_asset()
	if character is String:
		_quit_with(character)
		return
	asset = character
	_build_soldiers()
	error = _open()
	if error != "":
		_quit_with(error)
		return
	_debug = settings["debug"]
	_net_graph = settings["netgraph"]
	_captured = settings["frames"] == 0
	var window := get_window()
	_focused = DisplayServer.get_name() == "headless" or window.has_focus()
	window.focus_entered.connect(_set_window_focus.bind(true))
	window.focus_exited.connect(_set_window_focus.bind(false))
	_reset_gameplay_input()
	if _captured and _focused:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_native_input_scope()


func _start_native_input_trace(directory: String) -> void:
	if OS.get_name() != "macOS" or not FileAccess.file_exists(NATIVE_INPUT_EXTENSION):
		return
	OS.set_environment(NATIVE_INPUT_PATH_ENV, ProjectSettings.globalize_path(directory.path_join("native-input.jsonl")))
	var status := GDExtensionManager.load_extension(NATIVE_INPUT_EXTENSION)
	_native_input_loaded = status == GDExtensionManager.LOAD_STATUS_OK
	if not _native_input_loaded:
		OS.unset_environment(NATIVE_INPUT_PATH_ENV)
		push_warning("Native input timing unavailable (load status %d)." % status)


func _update_native_input_scope() -> void:
	var active := _captured and _focused and session != null and _reconnect_since < 0 and not _failed
	if _native_input_loaded:
		OS.set_environment(NATIVE_INPUT_GAMEPLAY_ENV, "1" if active else "0")
	if _gameplay_capture_marker.is_empty() or active == _gameplay_capture_marked:
		return
	if active:
		var marker := FileAccess.open(_gameplay_capture_marker, FileAccess.WRITE)
		if marker == null:
			return
		marker.store_line(str(OS.get_process_id()))
		marker.close()
	else:
		DirAccess.remove_absolute(_gameplay_capture_marker)
	_gameplay_capture_marked = active


func _setup_window() -> void:
	Engine.max_fps = settings["max-fps"]
	if DisplayServer.get_name() == "headless":
		return
	var size := Vector2i(settings["width"], settings["height"])
	# The window keeps the size the player gave it, unless the flags ask for another.
	if size != Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height")):
		DisplayServer.window_set_size(size)
	DisplayServer.window_set_title("Crowfield")
	if settings["max-fps"] == 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


func _build_world() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.29, 0.47, 0.75)
	sky_material.sky_horizon_color = Color(0.69, 0.77, 0.86)
	sky_material.ground_horizon_color = Color(0.69, 0.77, 0.86)
	sky_material.ground_bottom_color = Color(0.3, 0.34, 0.3)
	sky_material.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.66, 0.74, 0.84)
	environment.fog_density = 0.0011
	environment.fog_aerial_perspective = 0.4
	environment.fog_sky_affect = 0.15
	environment.ssao_enabled = true
	environment.ssao_radius = 1.2
	environment.ssao_intensity = 1.5
	environment.glow_enabled = true
	environment.glow_intensity = 0.3
	environment.glow_hdr_threshold = 1.4
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	sun = DirectionalLight3D.new()
	sun.rotation = Vector3(-0.8, 0.65, 0)
	sun.light_color = Color(1.0, 0.95, 0.87)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 140.0
	add_child(sun)
	camera = Camera3D.new()
	camera.fov = settings["fov"]
	camera.near = 0.05
	camera.far = 1000
	add_child(camera)
	camera.make_current()
	predictor = Predictor.new(get_world_3d().space, rules)
	debug = DebugDraw.new()
	add_child(debug)


## _load_map builds the map the server plays, when the handshake names it:
## its collision, for the prediction and the ragdolls, and its view. A map the
## embedded server built is shared.
func _load_map(map_name: String) -> Variant:
	if scene != null:
		return scene if scene.name == map_name else "the client already plays %s" % scene.name
	var built: MapScene
	if _local != null and _local.server.scene.name == map_name:
		built = _local.server.scene
	else:
		built = MapScene.named(map_name)
	if built == null:
		return "the client has no such map"
	scene = built
	_map_collision = scene.build_collision(get_world_3d().space)
	map_view = MapView.new(scene)
	add_child(map_view)
	return scene


func _build_soldiers() -> void:
	effects = Effects.new()
	add_child(effects)
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		effects.warm_up(camera)
	sounds = Sounds.new(settings["volume"])
	add_child(sounds)
	view_model = ViewModel.new()
	view_model.sun = sun
	add_child(view_model)
	hud = Hud.new()
	var layer := CanvasLayer.new()
	layer.layer = 1
	layer.add_child(hud)
	add_child(layer)
	hud.feedback = feedback
	hud.weapons = rules.weapons
	menu = GAME_MENU.instantiate()
	menu.visible = false
	menu.resumed.connect(_close_menu)
	menu.left.connect(func() -> void: _quit_with(""))
	var menu_layer := CanvasLayer.new()
	menu_layer.layer = 2
	menu_layer.add_child(menu)
	add_child(menu_layer)
	_self_view = asset.instantiate()
	add_child(_self_view)
	_self_view.visible = false
	_self_view.face(Vector3.ZERO, 0)
	# The rig is laid out on the first frame of the idle clip.
	_self_view.player.seek(0, true)
	asset.rig = RagdollRig.build(asset, _self_view.skeleton)
	pool = RagdollPool.new(asset.rig, get_world_3d().space)
	pool.fill()
	var fallen := Node3D.new()
	fallen.name = "Bodies"
	add_child(fallen)
	soldier_views = SoldierViews.new()
	soldier_views.asset = asset
	soldier_views.pool = pool
	soldier_views.bodies = bodies
	soldier_views.bodies_parent = fallen
	soldier_views.view_model = view_model
	soldier_views.effects = effects
	soldier_views.sounds = sounds
	soldier_views.rules = rules
	add_child(soldier_views)


## _open starts the connection the settings ask for: to the embedded server,
## which it starts, or to a remote one. It returns an error, or "".
func _open() -> String:
	if settings["connect"] != "":
		_connector = Connector.new(settings["connect"], settings["fingerprint"], settings["config-dir"])
		if _connector.failed():
			return _connector.error
		_status = "connecting to %s" % settings["connect"]
		return ""
	var server_settings := ServerSettings.new()
	server_settings.max_players = 1
	server_settings.stats_interval = 0
	server_settings.map = _map_name()
	server_settings.bots = settings["bots"]
	server_settings.bot_ai = settings["bot-ai"]
	server_settings.bot_deaths = settings["bot-deaths"]
	if settings["respawn-delay"] > 0:
		server_settings.respawn_delay = settings["respawn-delay"]
	# Going back to the spawn at will is for solo play only.
	server_settings.allow_respawn = settings["host"] == ""
	var host: String = settings["host"]
	var certificate: Array = []
	if host != "":
		server_settings.max_players = Game.MAX_PLAYERS
		var made: Variant = _host_certificate()
		if made is String:
			return made
		certificate = made
	var created: Variant = Server.create(server_settings, rules)
	if created is String:
		return created
	var server: Server = created
	_memory = Memory.MemoryListener.new()
	server.add_listener(_memory)
	_local_listeners.append(_memory)
	if host != "":
		var listener: Variant = ENetTransport.listen(host, Certificates.server_options(certificate[0], certificate[1]))
		if listener is String:
			server.close()
			return listener
		server.add_listener(listener)
		_local_listeners.append(listener)
		server.certificate_pem = Certificates.pem(certificate[0])
		_fingerprint = Certificates.fingerprint(certificate[0])
		print("hosting on %s, certificate fingerprint %s" % [host, _fingerprint])
	_local = ServerRunner.new(server)
	add_child(_local)
	_join(_memory.dial())
	return ""


## _map_name is the map of the embedded server: the one asked for, or the
## valley; the automatic scenarios run on the prototype they were made for.
func _map_name() -> String:
	if settings["map"] != "":
		return settings["map"]
	if settings["demo"] or settings["movement"] or settings["shoot"]:
		return "prototype"
	return "valley"


## _host_certificate keeps the certificate of a host in the config directory,
## so that the players who joined it once trust it again; without one it
## makes a fresh certificate every run.
func _host_certificate() -> Variant:
	var dir: String = settings["config-dir"]
	if dir == "":
		return Certificates.generate()
	return Certificates.load_or_create(dir.path_join("host.crt"), dir.path_join("host.key"))


func _join(conn: Conn, token: PackedByteArray = PackedByteArray()) -> void:
	if not _conditions.is_none():
		print("simulating network: %s" % _conditions)
		conn = SimulatedConn.new(conn, _conditions)
	_handshake = Handshake.new(conn, settings["name"], rules, _load_map, token)


func _exit_tree() -> void:
	if _gameplay_capture_marked:
		DirAccess.remove_absolute(_gameplay_capture_marker)
	if _native_input_loaded:
		OS.unset_environment(NATIVE_INPUT_GAMEPLAY_ENV)
		OS.unset_environment(NATIVE_INPUT_PATH_ENV)
		GDExtensionManager.unload_extension(NATIVE_INPUT_EXTENSION)
	_input_trace.finish_run(Time.get_ticks_usec())
	if _capture_writer != null and _capture_writer.is_started():
		_capture_writer.wait_to_finish()
	if session != null:
		session.close()
		if session.conn is ENetTransport.Client:
			(session.conn as ENetTransport.Client).finish()
	if _local != null:
		_local.server.close()
	for listener in _local_listeners:
		listener.close()
	if pool != null:
		bodies.clear()
		pool.close()
	if predictor != null:
		predictor.close()
	MapScene.free_collision(_map_collision)


func _input(event: InputEvent) -> void:
	if session == null or not _focused or not _captured or event.is_echo():
		return
	if not (event is InputEventKey or event is InputEventMouseButton):
		return
	for action in TRACE_ACTIONS:
		if event.is_action(action):
			var now := Time.get_ticks_usec()
			if action in MOVE_ACTIONS and event is InputEventKey:
				if event.is_pressed():
					_movement_pressed[action] = true
				_movement_key_events[action] = [event.is_pressed(), now / 1000]
				_input_trace.event(now, {
					"type": "movement_key",
					"action": action,
					"pressed": event.is_pressed(),
					"action_pressed": Input.is_action_pressed(action),
					"godot_physical_pressed": _movement_physical_pressed(action),
				})
				continue
			_input_trace.event(now, {
				"type": "gameplay_action",
				"action": action,
				"pressed": event.is_pressed(),
			})


## _unhandled_input takes the actions of the input map (Project Settings →
## Input Map) that happen at a press; the held ones _command reads every tick.
func _unhandled_input(event: InputEvent) -> void:
	if _failed or not _focused:
		return
	if event.is_action_pressed("menu"):
		if menu.visible:
			_close_menu()
		elif settings["frames"] == 0:
			_open_menu()
		return
	if not _captured:
		return
	if event.is_echo():
		# Godot also updates held actions from key repeat events.
		for action in HELD_ACTIONS:
			if Input.is_action_just_pressed_by_event(action, event):
				Input.action_release(action)
		return
	if event is InputEventMouseMotion:
		_mouse += event.screen_relative
	elif event.is_action_pressed("jump"):
		_jump_pressed = true
	elif event.is_action_pressed("fire"):
		_fire_pressed = true
	elif event.is_action_pressed("weapon_previous"):
		_turn_wheel(-1)
	elif event.is_action_pressed("weapon_next"):
		_turn_wheel(1)
	elif event.is_action_pressed("reload"):
		_reload_pressed = true
	elif event.is_action_pressed("weapon_1"):
		_weapon = 0
	elif event.is_action_pressed("weapon_2"):
		_weapon = 1
	elif event.is_action_pressed("weapon_3"):
		_weapon = 2
	elif event.is_action_pressed("toggle_debug"):
		_debug = not _debug
	elif event.is_action_pressed("toggle_net_graph"):
		_net_graph = not _net_graph
	elif event.is_action_pressed("toggle_camera"):
		_third_person = not _third_person
	elif event.is_action_pressed("capture_playtest", false, true):
		_request_capture(PlaytestCapture.STATE)
	elif event.is_action_pressed("capture_playtest_image", false, true):
		_request_capture(PlaytestCapture.IMAGE)
	elif event.is_action_pressed("debug_ragdoll"):
		var own := _own_soldier()
		if own != null:
			_die(predictor.drawn(_alpha), own.velocity)
	elif event.is_action_pressed("debug_respawn"):
		_reset()
	elif event.is_action_pressed("debug_knock_down"):
		soldier_views.knock_down(camera.global_position)


## _open_menu shows the game menu and frees the cursor; the soldier stands
## still meanwhile.
func _open_menu() -> void:
	_captured = false
	_reset_gameplay_input()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	menu.about = _about()
	menu.open()
	_update_native_input_scope()
	_input_trace.event(Time.get_ticks_usec(), {"type": "menu", "open": true})


func _close_menu() -> void:
	menu.visible = false
	_captured = true
	_reset_gameplay_input()
	if _focused:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_native_input_scope()
	_input_trace.event(Time.get_ticks_usec(), {"type": "menu", "open": false})


func _set_window_focus(focused: bool) -> void:
	_focused = focused
	_reset_gameplay_input()
	if _captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if focused else Input.MOUSE_MODE_VISIBLE
	_update_native_input_scope()
	_input_trace.event(Time.get_ticks_usec(), {"type": "focus", "focused": focused})


func _reset_gameplay_input() -> void:
	_mouse = Vector2.ZERO
	_clear_pressed()
	for action in HELD_ACTIONS:
		Input.action_release(action)


## _about tells what game this is, for the game menu: on a host, the
## addresses friends join and the fingerprint they may check.
func _about() -> String:
	if settings["connect"] != "":
		var state := "Playing on" if session != null and _reconnect_since < 0 else "Connecting to"
		return "%s %s as %s." % [state, settings["connect"], settings["name"]]
	var bots := " with %d bots" % settings["bots"] if settings["bots"] > 0 else ""
	if settings["host"] == "":
		return "Solo play on the %s%s." % [scene.name if scene != null else _map_name(), bots]
	var port: int = ENetTransport.split_address(settings["host"])[1]
	var addresses := PackedStringArray()
	for interface in IP.get_local_interfaces():
		var name: String = interface["name"]
		# The bridges of containers and virtual machines lead nowhere a friend is.
		if VIRTUAL_INTERFACES.any(func(prefix: String) -> bool: return name.begins_with(prefix)):
			continue
		for address: String in interface["addresses"]:
			if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
				addresses.append(address if port == ENetTransport.DEFAULT_PORT else "%s:%d" % [address, port])
	var lines := PackedStringArray(["Hosting%s on UDP port %d. Players: %d of %d." % [
		bots, port, _local.server.player_count(), Game.MAX_PLAYERS]])
	if not addresses.is_empty():
		lines.append("Friends on your network join %s." % " or ".join(addresses))
	lines.append("Certificate fingerprint: %s" % _fingerprint)
	return "\n".join(lines)


## _turn_wheel turns through the slots that hold a weapon.
func _turn_wheel(step: int) -> void:
	if not predictor.started:
		return
	var loadout := predictor.soldier.arsenal.weapons
	var next := _weapon
	for i in Arsenal.MAX_LOADOUT:
		next = (next + step + Arsenal.MAX_LOADOUT) % Arsenal.MAX_LOADOUT
		if loadout[next] != WeaponTuning.Kind.NONE:
			_weapon = next
			return


func _process(delta: float) -> void:
	if _failed:
		return
	_sample_frame()
	_input_trace.flush_if_due(Time.get_ticks_usec())
	if _capture_writer != null and _capture_writer.is_started() and not _capture_writer.is_alive():
		var result: Dictionary = _capture_writer.wait_to_finish()
		_show_capture_result(result.path, result.error, result.with_image)
	var sensitivity: float = settings["sensitivity"]
	var pitch := clampf(_pitch - _mouse.y * sensitivity, -1.45, 1.45)
	_look = Vector2(_mouse.x * sensitivity, pitch - _pitch)
	_yaw += _look.x
	_pitch = pitch
	_mouse = Vector2.ZERO
	var knock: bool = settings["knockdowns"] > _knockdowns and _played >= 2 + 0.5 * _knockdowns
	if knock:
		_knockdowns += 1
		soldier_views.knock_down(camera.global_position)
	delta = minf(delta, 0.1)
	_lap = Time.get_ticks_usec() if _frame_warmup <= 0 and settings["stats"] > 0 else 0
	if not _connect(delta):
		return
	# The automatic scenarios count their time from the first frame in play.
	_elapsed += delta
	_played += delta
	_accumulator += delta
	# Ticks last a little more or less than TICK_DELTA while the session brings
	# its commands to the right lead.
	while _reconnect_since < 0 and _accumulator >= session.tick_duration():
		_accumulator -= session.tick_duration()
		var command := session.send_command(_command())
		if command == null:
			break
		var result := predictor.predict(command)
		_events |= result.events
		if result.has(Arsenal.EVENT_FIRED):
			_shots.append(result.shot)
			_input_trace.event(Time.get_ticks_usec(), {
				"type": "shot",
				"command_tick": command.tick,
				"weapon": WeaponTuning.kind_name(result.shot.weapon),
			})
	_alpha = _accumulator / session.tick_duration()
	_charge("ticks")
	var updated := false
	if _reconnect_since < 0:
		updated = session.poll()
		feedback.take(session.news, session.player.soldier, sounds)
	feedback.update(delta)
	if _reconnect_since < 0 and not session.is_alive():
		_lose(session.failure)
		if _failed:
			return
	if updated:
		var corrections := predictor.corrections
		predictor.reconcile(session.player)
		if predictor.corrections != corrections:
			session.graph.correction(predictor.last_error)
		_follow_life()
	predictor.smooth(delta)
	session.clock.advance(delta)
	_charge("snapshots")
	_net_window += delta
	if _net_window >= 1:
		_net_rate = (session.bytes - _net_bytes) / 1024.0 / _net_window
		_net_bytes = session.bytes
		_net_window = 0.0
	var own := _own_soldier()
	if settings["demo"] and own != null and not _ragdoll and _elapsed >= 1.2:
		_die(predictor.drawn(_alpha), own.velocity)
	if settings["demo"] and _ragdoll and _elapsed >= 3 and _demo_cycle + 1 < settings["cycles"]:
		_reset()
		_demo_cycle += 1
	var feet := scene.spawn_of(_team())
	var speed := 0.0
	var server_own := session.local_soldier()
	if own != null:
		feet = predictor.drawn(_alpha)
		speed = predictor.achieved_speed
		_momentum = own.velocity
	elif server_own != null:
		# Dead, or not yet predicted: where the server has the soldier.
		feet = server_own.position
	_feet = feet
	_update_self(delta, feet, speed, server_own)
	bodies.update(delta)
	_charge("bodies")
	_update_camera(feet)
	_update_weapon(delta, own, speed)
	effects.update(delta)
	_charge("weapon")
	soldier_views.update(session, delta, camera)
	soldier_views.aim(feet + Vector3(0, rules.movement.eye_height, 0), Game.view_direction(_yaw, _pitch), rules.movement.center_height())
	var aimed := 0
	var aimed_updates := 0
	if soldier_views.aimed != null:
		aimed = soldier_views.aimed.soldier.id
		aimed_updates = soldier_views.aimed.updates
	session.graph.frame(delta, session.conn.stats.rtt, session.dilation, aimed, aimed_updates)
	_charge("soldiers")
	_draw_debug(own != null)
	_update_hud(feet, own)
	_charge("hud")
	_sample_input_trace()
	if _capture_requested != PlaytestCapture.NONE:
		var with_image := _capture_requested == PlaytestCapture.IMAGE
		_capture_requested = PlaytestCapture.NONE
		if _captured and _focused and _reconnect_since < 0:
			_capture_playtest(with_image)
	_frames += 1
	if settings["screenshot"] != "" and _frames == settings["frames"]:
		get_viewport().get_texture().get_image().save_png(settings["screenshot"])
	if settings["frames"] > 0 and _frames >= settings["frames"]:
		_finish()


## _connect drives the connection until there is a session, and the
## reconnection after a lost one. It returns whether a session plays.
func _connect(_delta: float) -> bool:
	if _reconnect_since >= 0:
		_poll_reconnect()
		if _failed:
			return false
		if _reconnect_since >= 0:
			_update_hud(_feet, null)
			return session != null
	if session != null:
		return true
	if _connector != null:
		_connector.poll()
		if _connector.failed():
			_quit_with("connect to %s: %s" % [settings["connect"], _connector.error])
			return false
		if not _connector.done():
			_update_hud(_feet, null)
			return false
		if _connector.message != "":
			print(_connector.message)
		_join(_connector.conn, _lost_token)
		_connector = null
	if _handshake == null:
		return false
	var local_tick := _local.server.tick if _local != null and _conditions.is_none() else -1
	_handshake.poll(local_tick)
	if _handshake.failed():
		_quit_with(_handshake.error)
		return false
	if not _handshake.done():
		_update_hud(_feet, null)
		return false
	session = _handshake.session
	_handshake = null
	predictor.join(session.welcome.match_seed)
	_trace_match()
	return true


## _command reads the input for one tick. While the cosmetic ragdoll lies on
## the ground the soldier stands still on the server.
func _command() -> InputCommand:
	var forward := 0.0
	var right := 0.0
	var buttons := 0
	var yaw := _yaw
	if _ragdoll:
		pass
	elif settings["movement"]:
		if _elapsed < 0.6:
			yaw = PI / 2
			forward = 1.0
			buttons = InputCommand.SPRINT
		elif _elapsed < 2.2:
			yaw = 0.0
			forward = 1.0
			buttons = InputCommand.SPRINT
			if _elapsed >= 1.1 and _elapsed < 1.4:
				buttons |= InputCommand.JUMP
	elif settings["demo"]:
		if _elapsed < 1.2:
			forward = 1.0
			buttons = InputCommand.SPRINT
	elif settings["shoot"]:
		var drill := _shooting_drill(_elapsed)
		_weapon = drill[0]
		buttons = drill[1]
		_pitch = -0.08
	elif _captured and _focused:
		forward = _movement_strength("move_forward") - _movement_strength("move_back")
		right = _movement_strength("move_right") - _movement_strength("move_left")
		if Input.is_action_pressed("jump") or _jump_pressed:
			buttons |= InputCommand.JUMP
		if Input.is_action_pressed("sprint"):
			buttons |= InputCommand.SPRINT
		if Input.is_action_pressed("fire") or _fire_pressed:
			buttons |= InputCommand.FIRE
		if Input.is_action_pressed("aim"):
			buttons |= InputCommand.AIM
		if _reload_pressed:
			buttons |= InputCommand.RELOAD
	_clear_pressed()
	_buttons = buttons
	var command := InputCommand.create(0, forward, right, yaw, _pitch, buttons)
	command.weapon = _weapon
	return command


func _movement_strength(action: StringName) -> float:
	return 1.0 if _movement_pressed.has(action) else Input.get_action_strength(action)


func _clear_pressed() -> void:
	_jump_pressed = false
	_fire_pressed = false
	_reload_pressed = false
	_movement_pressed.clear()


func _input_diagnostics() -> Dictionary:
	var command: InputCommand = session.history.back() if not session.history.is_empty() else null
	var predicted := predictor.soldier.velocity
	var authoritative := session.player.velocity
	return {
		"window_focused": _focused,
		"mouse_captured": Input.mouse_mode == Input.MOUSE_MODE_CAPTURED,
		"movement_keys": _movement_key_diagnostics(),
		"command": {
			"tick": command.tick,
			"forward": command.forward_axis(),
			"right": command.right_axis(),
			"buttons": command.buttons,
		} if command != null else null,
		"predicted_horizontal_velocity": [predicted.x, predicted.z] if predictor.started else null,
		"predicted_achieved_horizontal_speed": predictor.achieved_speed if predictor.started else null,
		"server_horizontal_velocity": [authoritative.x, authoritative.z] if session.player.processed else null,
		"server_processed_tick": session.player.last_processed_tick if session.player.processed else null,
	}


func _movement_key_diagnostics() -> Dictionary:
	var states := {}
	var now := Time.get_ticks_msec()
	for action in MOVE_ACTIONS:
		var transition: Array = _movement_key_events.get(action, [])
		states[action] = {
			"action_pressed": Input.is_action_pressed(action),
			"godot_physical_pressed": _movement_physical_pressed(action),
			"last_key_pressed": transition[0] if not transition.is_empty() else null,
			"last_key_age_ms": now - transition[1] if not transition.is_empty() else null,
		}
	return states


func _movement_physical_pressed(action: StringName) -> Variant:
	var pressed: Variant = null
	for binding in InputMap.action_get_events(action):
		if binding is InputEventKey and binding.physical_keycode != KEY_NONE:
			pressed = pressed == true or Input.is_physical_key_pressed(binding.physical_keycode)
	return pressed


func _sample_input_trace() -> void:
	var now := Time.get_ticks_usec()
	if not _input_trace.frame(now, _last_frame_usec, _look):
		return
	var command: InputCommand = session.history.back() if not session.history.is_empty() else null
	var predicted := predictor.soldier.position
	var authoritative := session.player.position
	var arsenal := _arsenal()
	var armed := arsenal != null and arsenal.weapon() != WeaponTuning.Kind.NONE
	_input_trace.sample(now, {
		"command_tick": command.tick if command != null else null,
		"forward": command.forward_axis() if command != null else null,
		"right": command.right_axis() if command != null else null,
		"buttons": command.buttons if command != null else null,
		"server_processed_tick": session.player.last_processed_tick if session.player.processed else null,
		"predicted_position": [predicted.x, predicted.y, predicted.z] if predictor.started else null,
		"predicted_achieved_horizontal_speed": predictor.achieved_speed if predictor.started else null,
		"server_position": [authoritative.x, authoritative.y, authoritative.z] if session.player.processed else null,
		"window_focused": _focused,
		"gameplay_captured": _captured and _focused,
		"yaw_radians": _yaw,
		"pitch_radians": _pitch,
		"last_frame_ms": _last_frame_usec / 1000.0,
		"health": session.player.health if session.player.processed else null,
		"soldier": session.player.soldier if session.player.processed else null,
		"weapon": WeaponTuning.kind_name(arsenal.weapon()) if armed else null,
		"magazine": arsenal.magazine[arsenal.current] if armed else null,
	})


func _trace_match() -> void:
	_update_native_input_scope()
	_input_trace.event(Time.get_ticks_usec(), {
		"type": "match",
		"map": session.welcome.map,
		"match_seed": str(session.welcome.match_seed),
	})


## _shooting_drill is the input of -shoot at a time: bursts of the assault
## rifle from the hip and aimed, the rifle through its scope, then the pistol
## emptied and reloaded.
static func _shooting_drill(elapsed: float) -> Array:
	if elapsed < 0.4:
		return [0, 0]
	if elapsed < 1.4:
		return [0, InputCommand.FIRE]
	if elapsed < 1.7:
		return [0, InputCommand.AIM]
	if elapsed < 2.7:
		return [0, InputCommand.AIM | InputCommand.FIRE]
	if elapsed < 3.8:
		return [1, 0]
	if elapsed < 4.3:
		return [1, InputCommand.AIM]
	if elapsed < 4.4:
		return [1, InputCommand.AIM | InputCommand.FIRE]
	if elapsed < 5.4:
		return [2, 0]
	if elapsed < 8 and int(elapsed * 6) % 2 == 0:
		return [2, InputCommand.FIRE]
	return [2, 0]


## _own_soldier is the predicted soldier, or null before the first snapshot
## of it.
func _own_soldier() -> Soldier:
	return predictor.soldier if predictor.started else null


## _arsenal is the predicted state of the player's weapons, or null.
func _arsenal() -> Arsenal:
	var own := _own_soldier()
	return own.arsenal if own != null else null


## _first_person reports whether the camera is the soldier's eye.
func _first_person() -> bool:
	return not _third_person and not _ragdoll and not settings["overview"] and _own_soldier() != null


func _team() -> int:
	var own := session.local_soldier() if session != null else null
	return own.team if own != null else Game.Team.NONE


## _update_self shows the own soldier's model in third person, in overview
## and when it lies fallen; in first person the player sees its weapon only.
func _update_self(delta: float, feet: Vector3, speed: float, server_own: Soldier) -> void:
	var shown: bool = _ragdoll or ((_third_person or settings["overview"]) and server_own != null)
	_self_view.visible = shown
	if not _ragdoll:
		_self_view.face(feet, _yaw)
		_self_view.animate(delta, speed)
	_self_view.update_fall(delta)
	_self_view.set_tint(soldier_views.tint(_team()))
	var kind := WeaponTuning.Kind.NONE
	var arsenal := _arsenal()
	if arsenal != null and shown and not _ragdoll:
		kind = arsenal.weapon()
	if kind != _self_held_kind:
		if _self_held != null:
			_self_held.queue_free()
		_self_held = view_model.make_held(kind, soldier_views.tint(_team()))
		_self_held_kind = kind
		if _self_held != null:
			add_child(_self_held)
	if _self_held != null:
		_self_held.transform = ViewModel.held_transform(feet, _yaw, _pitch)


## _update_camera looks where the player aims, turned by the kick of the
## weapon, which the aim of the next shot has too. Aiming down the sights
## narrows the field of view by the weapon's zoom.
func _update_camera(feet: Vector3) -> void:
	var yaw := _yaw
	var pitch := _pitch
	var fov: float = settings["fov"]
	var arsenal := _arsenal()
	if arsenal != null:
		yaw += arsenal.kick_yaw
		pitch = clampf(pitch + arsenal.kick_pitch, -1.55, 1.55)
		var tuning := rules.weapons.get_tuning(arsenal.weapon())
		if tuning != null and _first_person():
			fov *= 1 + (tuning.aim_zoom - 1) * view_model.aim
	camera.fov = fov
	var forward := Game.view_direction(yaw, pitch)
	var eye := feet + Vector3(0, rules.movement.eye_height, 0)
	if settings["overview"]:
		# High above the south edge of the map: every soldier is in view.
		var area := scene.play_area
		camera.look_at_from_position(Vector3(0, area * 0.75 + 6, area * 1.2 + 4), Vector3(0, 0, area * 0.1))
		return
	if _third_person or _ragdoll:
		var target := eye
		if _ragdoll:
			target = _self_view.fallen_at + Vector3(0, 0.6, 0)
		camera.look_at_from_position(target - forward * 5.5 + Vector3(0, 0.8, 0), target)
		return
	camera.look_at_from_position(eye, eye + forward, Vector3.UP)


## _update_weapon moves the weapon in hand for the frame and shows what the
## weapons did in its ticks: a shot's flash, tracer and hole where the
## client's own world says it struck, and the sounds.
func _update_weapon(delta: float, own: Soldier, speed: float) -> void:
	var arsenal := _arsenal()
	if arsenal == null:
		_shots.clear()
		_events = 0
		view_model.hide_weapon()
		return
	var held := _buttons & InputCommand.AIM != 0
	var aiming := held and arsenal.action == Arsenal.Action.READY
	var sprinting := _buttons & InputCommand.SPRINT != 0 and not held and _buttons & InputCommand.FIRE == 0 \
		and speed > rules.movement.walk_speed
	view_model.update(delta, aiming, sprinting, own.grounded, speed / rules.movement.sprint_speed, _look)
	var progress := 0.0
	var tuning := rules.weapons.get_tuning(arsenal.weapon())
	if tuning != null:
		var total := tuning.reload_ticks() if arsenal.action == Arsenal.Action.RELOADING else tuning.equip_ticks()
		progress = 1 - (arsenal.action_ticks - _alpha) / maxi(1, total)
	var placed := false
	if _first_person():
		view_model.show_weapon(arsenal.weapon(), soldier_views.tint(_team()))
		placed = view_model.place(camera, arsenal.weapon(), arsenal.action, clampf(progress, 0, 1))
	else:
		view_model.hide_weapon()
	var state := get_world_3d().direct_space_state
	for shot in _shots:
		var reach := rules.weapons.get_tuning(shot.weapon).range
		var query := PhysicsRayQueryParameters3D.create(shot.origin, shot.origin + shot.direction * reach, Game.LAYER_STATIC | Game.LAYER_VEHICLE)
		var hit := state.intersect_ray(query)
		var end: Vector3 = hit["position"] if not hit.is_empty() else shot.origin + shot.direction * reach
		var muzzle := view_model.held_muzzle(shot.weapon, _feet, _yaw, _pitch)
		if muzzle == Vector3.INF:
			muzzle = camera.global_position
		if placed:
			muzzle = view_model.muzzle_in_world(camera)
			view_model.fired(_noise(shot.direction))
		effects.shot(muzzle, end, not hit.is_empty())
		sounds.weapon(shot.weapon, Arsenal.EVENT_FIRED)
	sounds.weapon(arsenal.weapon(), _events & ~Arsenal.EVENT_FIRED)
	_shots.clear()
	_events = 0


## _noise turns a direction into a number in [0, 1) that varies from shot to
## shot, for the look of a flash.
static func _noise(direction: Vector3) -> float:
	var value := absf(direction.x * 7919 + direction.y * 104729 + direction.z * 1299709)
	return value - floorf(value)


## _die drops the own soldier as a ragdoll where it stands: when the server
## says it died, or by the debug key, which the server knows nothing of. The
## debug key throws the soldier forward; a shot strikes it where the bullet
## hit.
func _die(feet: Vector3, velocity: Vector3) -> void:
	if _ragdoll:
		return
	_self_view.face(feet, _yaw)
	var blow := CharacterView.Strike.new(RagdollRig.Part.HIPS, feet + Vector3(0, 0.55, 0),
		Game.view_direction(_yaw, 0) * 35 + Vector3(0, 20, 0))
	var own := session.local_soldier()
	if _fallen != 0 and own != null:
		blow = SoldierViews.strike(feet, _yaw, own.hit_box, own.hit_yaw)
	bodies.make_room(pool, camera.global_position)
	if _self_view.fall(pool, velocity, blow):
		_self_view.visible = true
		_ragdoll = true


## _follow_life shows the death of the own soldier as soon as the server
## tells it, and stands the player up again when a new soldier comes.
func _follow_life() -> void:
	var player := session.player
	var dead := player.soldier != 0 and player.health == 0
	if dead and _fallen != player.soldier:
		# The body falls where the server has it dead, which everyone else sees,
		# not where the prediction ran on to, with the momentum it had.
		_fallen = player.soldier
		_input_trace.event(Time.get_ticks_usec(), {"type": "death", "soldier": player.soldier})
		var feet := _feet
		var own := session.local_soldier()
		if own != null:
			feet = own.position
		_die(feet, SoldierViews.momentum(_momentum))
	elif not dead and _fallen != 0 and player.soldier != _fallen:
		_input_trace.event(Time.get_ticks_usec(), {"type": "respawn", "soldier": player.soldier})
		_fallen = 0
		_ragdoll = false
		feedback.killed_by = ""
		_self_view.stand_up()


func _reset() -> void:
	if _fallen != 0 or session == null:
		# The dead wait for the server.
		return
	_yaw = 0.0
	_pitch = 0.0
	_elapsed = 0.0
	_ragdoll = false
	_self_view.stand_up()
	map_view.reset()
	session.respawn()


## _lose handles a lost connection: playing solo or hosting it is the end, on
## a remote server the client comes back with its token.
func _lose(reason: String) -> void:
	if settings["connect"] == "":
		_quit_with("disconnected: %s" % reason)
		return
	print("connection lost: %s; reconnecting" % reason)
	_lost_token = session.token()
	session.abandon()
	_reconnect_since = ClientSession._now()
	_update_native_input_scope()
	_reconnect_reason = reason
	_reconnect_attempts = 0
	_reconnect_next = 0.0


## _poll_reconnect tries to connect again once a second, with the token of
## the lost session, until the server's window to keep the place closes.
func _poll_reconnect() -> void:
	var now := ClientSession._now()
	if now - _reconnect_since > RECONNECT_WINDOW:
		_quit_with("could not reconnect within %d s: %s" % [int(RECONNECT_WINDOW), _reconnect_reason])
		return
	if _connector == null and _handshake == null:
		if now < _reconnect_next:
			return
		_reconnect_attempts += 1
		_reconnect_next = now + 1.0
		_connector = Connector.new(settings["connect"], settings["fingerprint"], settings["config-dir"])
	if _connector != null:
		_connector.poll()
		if _connector.failed():
			_connector = null
			return
		if not _connector.done():
			return
		_join(_connector.conn, _lost_token)
		_connector = null
	_handshake.poll()
	if _handshake.failed():
		_handshake = null
		return
	if not _handshake.done():
		return
	session = _handshake.session
	_handshake = null
	predictor.join(session.welcome.match_seed)
	_reconnect_since = -1.0
	_accumulator = 0.0
	_trace_match()
	print("reconnected as player %d" % session.welcome.player)


func _draw_debug(spawned: bool) -> void:
	if not _debug:
		debug.flush()
		return
	for box in scene.boxes:
		debug.box(box.transform, box.half_extents, Color.BLACK)
	for entry in soldier_views.shown:
		debug.hitboxes(entry.known.remote.position, entry.known.remote.yaw)
	if spawned and not _ragdoll:
		# The server's view of the own soldier, to compare with the prediction.
		var server_own := session.local_soldier()
		if server_own != null:
			var radius := rules.movement.capsule_radius
			debug.capsule(server_own.position + Vector3(0, radius, 0),
				server_own.position + Vector3(0, 2 * rules.movement.center_height() - radius, 0), radius, Color.ORANGE)
	debug.grid(30, Color(0.4, 0.4, 0.4))
	var origin := camera.global_position
	var forward := -camera.global_basis.z
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + forward * 100,
		Game.LAYER_STATIC | Game.LAYER_VEHICLE | Game.LAYER_DYNAMIC))
	if not hit.is_empty():
		debug.line(origin + Vector3(0, -0.05, 0), hit["position"], Color.RED)
	debug.flush()


func _update_hud(feet: Vector3, own: Soldier) -> void:
	var lines := PackedStringArray()
	var connected := session != null
	if _debug or _net_graph:
		lines.append_array(HELP_LINES)
		lines.append("FPS %d | XYZ %.2f %.2f %.2f | %s | drawn %d (full %d) | bodies %d (ragdolls %d)" % [
			Engine.get_frames_per_second(), feet.x, feet.y, feet.z, CharacterAsset.CLIPS[_self_view.clip],
			soldier_views.drawn, soldier_views.full, bodies.all.size(), bodies.ragdolls()])
		if connected:
			lines.append("%d Hz | tick %d server %d lead %d (clock %+.1f%%) | RTT %d ms | snapshots %.1f KB/s | jumps %d | corrections %d (last %.3f m) | soldiers %d" % [
				Game.TICK_RATE, session.tick, session.server_tick, session.player.input_lead, 100 * session.dilation,
				roundi(session.conn.stats.rtt * 1000), _net_rate, session.resyncs, predictor.corrections, predictor.last_error,
				session.soldiers.size()])
	if not connected:
		lines.append(_status + "…")
	if _capture_notice != "" and Time.get_ticks_msec() < _capture_notice_until:
		lines.append(_capture_notice)
	hud.lines = lines
	var arsenal := _arsenal()
	hud.arsenal = arsenal
	hud.fov = camera.fov
	hud.aim = view_model.aim if _first_person() else 0.0
	hud.scoped = arsenal != null and _first_person() and view_model.scoped(arsenal.weapon())
	if arsenal != null and own != null:
		hud.spread = arsenal.spread(rules.weapons, _buttons & InputCommand.AIM != 0,
			Game.horizontal_length(own.velocity) / rules.movement.sprint_speed, not own.grounded)
	var player := session.player if connected else PlayerState.new()
	hud.has_soldier = player.soldier != 0
	hud.dead = player.soldier != 0 and player.health == 0
	hud.health = player.health
	hud.respawn_ticks = player.respawn
	hud.team = _team()
	hud.view_yaw = _yaw
	hud.net_graph = session.graph if connected and _net_graph else null
	hud.jumps = session.resyncs if connected else 0
	hud.reconnect_lines = PackedStringArray()
	if _reconnect_since >= 0:
		hud.reconnect_lines = PackedStringArray([
			"Connection lost: %s" % _reconnect_reason,
			"Reconnecting: attempt %d, %d s of %d" % [_reconnect_attempts, int(ClientSession._now() - _reconnect_since), int(RECONNECT_WINDOW)],
		])
	hud.queue_redraw()


func _request_capture(kind: PlaytestCapture) -> void:
	if _capture_writer == null and session != null and _reconnect_since < 0:
		_capture_requested = kind
		_capture_notice = ""


## Save the state of this frame, optionally with the corresponding rendered image.
func _capture_playtest(with_image: bool) -> void:
	_capture_writer = Thread.new()
	var image: Image
	if with_image:
		await RenderingServer.frame_post_draw
		if _failed or not _focused or not _captured or _reconnect_since >= 0:
			_capture_writer = null
			return
		image = get_viewport().get_texture().get_image()
		if image == null or image.is_empty():
			_show_capture_result("", ERR_UNAVAILABLE, true)
			return
	var soldier := _own_soldier()
	if soldier == null:
		soldier = session.local_soldier()
	var arsenal := _arsenal()
	var weapon: Dictionary = {}
	if arsenal != null and arsenal.weapon() != WeaponTuning.Kind.NONE:
		weapon = {
			"kind": WeaponTuning.kind_name(arsenal.weapon()),
			"magazine": arsenal.magazine[arsenal.current],
			"reserve": arsenal.reserve[arsenal.current],
		}
	var direction := -camera.global_basis.z
	var state := {
		"map": session.welcome.map,
		"match_seed": str(session.welcome.match_seed),
		"session_tick": session.tick,
		"server_tick": session.server_tick,
		"position": [_feet.x, _feet.y, _feet.z],
		"view": {
			"direction": [direction.x, direction.y, direction.z],
			"fov_degrees": camera.fov,
			"first_person": _first_person(),
		},
		"weapon": weapon if not weapon.is_empty() else null,
		"health": session.player.health,
		"grounded": soldier.grounded if soldier != null else null,
		"fps": Engine.get_frames_per_second(),
		"last_frame_ms": _last_frame_usec / 1000.0,
		"recent_worst_frame_ms": maxi(_frame_window_longest_usec, _previous_frame_window_longest_usec) / 1000.0,
		"input": _input_diagnostics(),
		"recent_input": _input_trace.snapshot(Time.get_ticks_usec()),
	}
	var stem := "playtest-%s-%d" % [Time.get_datetime_string_from_system(true).replace(":", ""), Time.get_ticks_usec()]
	var path := ProjectSettings.globalize_path(PLAYTEST_DIR.path_join(stem))
	var error := _capture_writer.start(_write_capture.bind(path, image, state), Thread.PRIORITY_LOW)
	if error != OK:
		_show_capture_result(path, error, with_image)


## Only the GPU readback needs the game thread. The writer owns this image and state.
static func _write_capture(path: String, image: Image, state: Dictionary) -> Dictionary:
	var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error == OK and image != null:
		error = image.save_png(path + ".png")
	if error == OK:
		var file := FileAccess.open(path + ".json", FileAccess.WRITE)
		if file == null:
			error = FileAccess.get_open_error()
		else:
			file.store_string(JSON.stringify(state, "\t", true, true) + "\n")
			file.flush()
			error = file.get_error()
			file.close()
	if error != OK:
		for extension in [".png", ".json"]:
			if FileAccess.file_exists(path + extension):
				DirAccess.remove_absolute(path + extension)
	return {"path": path, "error": error, "with_image": image != null}


func _show_capture_result(path: String, error: Error, with_image: bool) -> void:
	_capture_writer = null
	if error == OK:
		var saved := "image and state" if with_image else "state"
		_capture_notice = "Playtest %s saved to %s" % [saved, PLAYTEST_DIR]
		print("Playtest %s saved: %s%s" % [saved, path, ".png and .json" if with_image else ".json"])
	else:
		_capture_notice = "Playtest capture failed: " + error_string(error)
		push_warning(_capture_notice)
	_capture_notice_until = Time.get_ticks_msec() + 4000


func _charge(part: String) -> void:
	if _lap == 0:
		return
	var now := Time.get_ticks_usec()
	_profile[part] = _profile.get(part, 0) + now - _lap
	_lap = now


## Measure the preceding frame from the monotonic clock so stalls count in
## diagnostics even when the engine adjusts the simulation delta.
func _sample_frame() -> void:
	var now := Time.get_ticks_usec()
	var previous_start := _frame_started_usec
	_frame_started_usec = now
	if previous_start < 0 or now == previous_start:
		return
	_last_frame_usec = now - previous_start
	# Keep the current and previous one-second windows so F4 can catch a stall
	# even when the key arrives on a subsequent frame.
	var window_age := now - _frame_window_started_usec
	if window_age >= FRAME_DIAGNOSTIC_WINDOW_USEC:
		_previous_frame_window_longest_usec = _frame_window_longest_usec if window_age < 2 * FRAME_DIAGNOSTIC_WINDOW_USEC else 0
		_frame_window_started_usec = now
		_frame_window_longest_usec = 0
	_frame_window_longest_usec = maxi(_frame_window_longest_usec, _last_frame_usec)
	var duration := _last_frame_usec / 1000000.0
	if _frame_warmup > 0:
		_frame_warmup -= duration
		if _frame_warmup <= 0 and _local != null and settings["stats"] > 0:
			_local.server.profile = TickProfile.new()
		return
	_frame_stats.add(duration)
	var interval: float = settings["stats"]
	if interval <= 0:
		return
	_report.add(duration)
	if _report.total < interval:
		return
	if _local != null:
		_profile["server"] = _local.server.profile.total
		_local.server.profile = TickProfile.new()
	var parts := ""
	for part in _profile:
		parts += " %s=%.2fms" % [part, _profile[part] / 1000.0 / _report.frames]
	print("client: %s memory=%.1fMB ragdolls=%d (made %d) bodies=%d drawn=%d deaths_seen=%d |%s" % [
		_report.describe(), OS.get_static_memory_usage() / 1048576.0, pool.lent(), pool.made(), bodies.all.size(),
		soldier_views.drawn, soldier_views.falls, parts])
	_report = FrameStats.new()
	_profile.clear()


func _finish() -> void:
	var own := session.local_soldier() if session != null else null
	var position := own.position if own != null else Vector3.ZERO
	var grounded := own.grounded if own != null else false
	print("prototype finished: tick=%d server_tick=%d feet=%s grounded=%s ragdoll=%s active=%s animation=%s snapshots=%d snapshot_traffic=%.1fKB/s resyncs=%d corrections=%d soldiers=%d unresolved=%d drawn=%d full_detail=%d bodies=%d ragdolls=%d peak_ragdolls=%d %s" % [
		session.tick if session != null else 0, session.server_tick if session != null else 0, position, grounded, _ragdoll,
		_self_view.ragdoll_active(), CharacterAsset.CLIPS[_self_view.clip], session.received if session != null else 0,
		(session.bytes if session != null else 0) / 1024.0 / maxf(_played, 1e-3), session.resyncs if session != null else 0,
		predictor.corrections, session.soldiers.size() if session != null else 0, session.unresolved if session != null else 0,
		soldier_views.drawn, soldier_views.full, bodies.all.size(), bodies.ragdolls(), bodies.peak, _frame_stats.describe()])
	get_tree().quit()


## _quit_with ends the game for a reason: the main menu shows it, or the
## program ends with it when the game was started by flags.
func _quit_with(message: String) -> void:
	_failed = true
	_update_native_input_scope()
	left.emit(message)


## FrameStats measures the average rate and longest frame of its samples.
class FrameStats:
	var frames := 0
	var total := 0.0
	var longest := 0.0

	func add(delta: float) -> void:
		frames += 1
		total += delta
		longest = maxf(longest, delta)

	func describe() -> String:
		if frames == 0:
			return "fps=0"
		return "fps=%.0f longest_frame=%.1fms" % [frames / total, longest * 1000]
