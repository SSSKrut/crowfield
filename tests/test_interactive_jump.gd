extends TestCase
## Runs the interactive solo client and its game menu with real input events.

const FRAME_LIMIT := 240

var _tree: SceneTree
var _client: ClientApp


func test_interactive_jump() -> void:
	if not await _start_client():
		return

	var tick := _client.session.tick
	_tap(KEY_SPACE)
	if Input.is_action_pressed("jump") or _client.session.tick != tick:
		fail("the test did not release Space before the next tick")
		return
	var commands := await _commands(tick, 2)
	if commands.size() != 2 or not commands[0].has(InputCommand.JUMP) or commands[1].has(InputCommand.JUMP):
		fail("a short Space tap must set jump on exactly the next command")
		return
	if _client.predictor.soldier.velocity.y <= 0:
		fail("the grounded soldier did not jump")
		return
	var jump_edges: Array[bool] = []
	for event in _client._input_trace.snapshot(Time.get_ticks_usec())["events"]:
		if event["type"] == "gameplay_action" and event["action"] == "jump":
			jump_edges.append(event["pressed"])
	check_equal(jump_edges, [true, false], "quick tap transitions in the trace")

	tick = _client.session.tick
	_key(KEY_W, true)
	_mouse_motion(Vector2(80, 0))
	_tap(KEY_SPACE)
	_tap(KEY_ESCAPE)
	if not _client.menu.visible:
		_key(KEY_W, false)
		fail("Escape did not open the game menu")
		return
	_client.menu.get_node("%Resume").pressed.emit()
	if _client.menu.visible:
		_key(KEY_W, false)
		fail("Resume did not close the game menu")
		return
	_key(KEY_W, true, true)
	commands = await _commands(tick, 1)
	_key(KEY_W, false)
	if commands.size() != 1 or commands[0].has(InputCommand.JUMP):
		fail("a tap pending when the menu opened leaked into resumed play")
		return
	check(commands[0].forward_axis() == 0, "held W survived the menu")
	check_near(_client._yaw, 0.0, 0.001, "queued look survived the menu")

	tick = _client.session.tick
	_key(KEY_SPACE, true)
	commands = await _commands(tick, 2)
	_key(KEY_SPACE, false)
	if commands.size() != 2 or not commands[0].has(InputCommand.JUMP) or not commands[1].has(InputCommand.JUMP):
		fail("held Space must keep setting jump across ticks")
		return
	commands = await _commands(_client.session.tick, 1)
	if commands.size() != 1 or commands[0].has(InputCommand.JUMP):
		fail("released Space kept setting jump")


func test_focus_releases_movement_and_look() -> void:
	if not await _start_client(30):
		return
	var tick := _client.session.tick
	_key(KEY_W, true)
	var commands := await _commands(tick, 1)
	if not check(commands.size() == 1 and commands[0].forward_axis() > 0, "W must move before losing focus"):
		_key(KEY_W, false)
		return
	var pressed: Dictionary = _client._input_diagnostics()["movement_keys"]["move_forward"]
	check(pressed["action_pressed"] and pressed["godot_physical_pressed"], "press did not appear in both Godot input states")
	check(pressed["last_key_pressed"] and pressed["last_key_age_ms"] >= 0, "press transition missing from diagnostic")

	tick = _client.session.tick
	_mouse_motion(Vector2(80, 0))
	_tree.root.focus_exited.emit()
	commands = await _commands(tick, 1)
	check(commands.size() == 1 and commands[0].forward_axis() == 0, "movement continued after losing focus")
	check_near(_client._yaw, 0.0, 0.001, "queued look survived loss of focus")

	tick = _client.session.tick
	_mouse_motion(Vector2(80, 0))
	_tree.root.focus_entered.emit()
	_key(KEY_W, true, true)
	commands = await _commands(tick, 1)
	check(commands.size() == 1 and commands[0].forward_axis() == 0, "held W resumed without a fresh press")
	check_near(_client._yaw, 0.0, 0.001, "mouse motion while unfocused changed look")

	_key(KEY_W, false)
	tick = _client.session.tick
	_key(KEY_W, true)
	_mouse_motion(Vector2(40, 0))
	commands = await _commands(tick, 1)
	check(commands.size() == 1 and commands[0].forward_axis() > 0, "fresh W press did not move after regaining focus")
	check(_client._yaw > 0, "fresh mouse motion did not change look")
	tick = _client.session.tick
	_key(KEY_W, true, true)
	commands = await _commands(tick, 1)
	check(commands.size() == 1 and commands[0].forward_axis() > 0, "key repeat stopped a held W")
	await _tree.create_timer(0.15).timeout
	_key(KEY_W, false)
	tick = _client.session.tick
	commands = await _commands(tick, 1)
	check(commands.size() == 1 and commands[0].forward_axis() == 0, "movement continued after releasing W")
	check_near(Game.horizontal_length(_client.predictor.soldier.velocity), 0.0, 0.001, "prediction still moving after W release")
	for frame in FRAME_LIMIT:
		if _client.session.player.last_processed_tick >= tick:
			break
		await _tree.process_frame
	var diagnostic := _client._input_diagnostics()
	var released: Dictionary = diagnostic["movement_keys"]["move_forward"]
	check(not released["action_pressed"] and not released["godot_physical_pressed"], "release did not reset both Godot input states")
	check_equal(released["last_key_pressed"], false, "latest W transition after release")
	check(diagnostic["window_focused"], "diagnostic did not report regained focus")
	check(diagnostic["command"]["tick"] >= tick and diagnostic["command"]["forward"] == 0, "diagnostic reported a stale forward command")
	check_equal(diagnostic["predicted_horizontal_velocity"], [0.0, 0.0], "reported prediction velocity")
	check(diagnostic["server_processed_tick"] >= tick, "server did not process the release")
	check_equal(diagnostic["server_horizontal_velocity"], [0.0, 0.0], "reported server velocity")
	var trace: Dictionary = _client._input_trace.snapshot(Time.get_ticks_usec())
	var saw_focus_out := false
	var saw_focus_in := false
	var saw_key_up := false
	var saw_movement := false
	var saw_look := false
	for event in trace["events"]:
		if event["type"] == "focus":
			saw_focus_in = saw_focus_in or event["focused"]
			saw_focus_out = saw_focus_out or not event["focused"]
		elif event["type"] == "movement_key":
			saw_key_up = saw_key_up or (event["action"] == "move_forward" and not event["pressed"]
				and not event["godot_physical_pressed"] and not event["action_pressed"])
	for sample in trace["samples"]:
		var speed: Variant = sample["predicted_achieved_horizontal_speed"]
		saw_movement = saw_movement or (speed != null and speed > 1.0)
		saw_look = saw_look or absf(sample["look_delta_radians"][0]) > 0.01
	check(saw_focus_out and saw_focus_in and saw_key_up, "rolling trace omitted a focus transition or W release")
	check(saw_movement and saw_look, "rolling trace omitted walking or camera motion")


func test_w_press_and_release_in_one_input_batch_moves_once() -> void:
	if not await _start_client(60):
		return
	var tick := _client.session.tick
	_key(KEY_W, true)
	var commands := await _commands(tick, 2)
	_key(KEY_W, false)
	check(commands.size() == 2 and commands[0].forward_axis() == 1 and commands[1].forward_axis() == 1,
		"ordinary W hold did not keep moving")
	commands = await _commands(_client.session.tick, 1)
	check(commands.size() == 1 and commands[0].forward_axis() == 0, "ordinary W release did not stop")

	tick = _client.session.tick
	_key(KEY_W, true, false, false)
	_key(KEY_W, false)
	check(_client.session.tick == tick and not Input.is_action_pressed("move_forward")
		and not Input.is_physical_key_pressed(KEY_W), "fixture must deliver press and release before the next command")
	commands = await _commands(tick, 2)
	check(commands.size() == 2 and commands[0].forward_axis() == 1 and commands[1].forward_axis() == 0,
		"batched W press and release must move on exactly one command")


func test_dev_capture_marker_tracks_play_menu_and_focus() -> void:
	if not await _start_client():
		return
	var marker := ProjectSettings.globalize_path("user://.test-gameplay-captured-%d" % OS.get_process_id())
	cleanup(func() -> void:
		if FileAccess.file_exists(marker):
			DirAccess.remove_absolute(marker))
	_client._gameplay_capture_marker = marker
	_client._update_native_input_scope()
	check_equal(FileAccess.get_file_as_string(marker).strip_edges(), str(OS.get_process_id()), "active playtest PID")
	_client._open_menu()
	check(not FileAccess.file_exists(marker), "menu left active capture registered")
	_client._close_menu()
	check(FileAccess.file_exists(marker), "resuming did not register capture")
	_tree.root.focus_exited.emit()
	check(not FileAccess.file_exists(marker), "focus loss left capture registered")
	_tree.root.focus_entered.emit()
	check(FileAccess.file_exists(marker), "regaining focus did not register capture")
	_client.left.disconnect(fail)
	_client._quit_with("")
	check(not FileAccess.file_exists(marker), "quitting left capture registered")


func _start_client(frame_cap: int = 144) -> bool:
	_tree = Engine.get_main_loop() as SceneTree
	await _tree.process_frame
	var max_fps := Engine.max_fps
	var mouse_mode := Input.mouse_mode
	_client = ClientApp.create(["-map=prototype", "-volume=0", "-config-dir=", "-max-fps=%d" % frame_cap])
	_client.left.connect(fail)
	cleanup(func() -> void:
		_client.free()
		Engine.max_fps = max_fps
		Input.mouse_mode = mouse_mode)
	_tree.root.add_child(_client)
	for frame in FRAME_LIMIT:
		await _tree.process_frame
		if _client.predictor.started and _client.predictor.soldier.grounded:
			break
	if not _client.predictor.started or not _client.predictor.soldier.grounded:
		fail("solo client never reached a grounded soldier")
		return false
	return true


func _commands(from_tick: int, count: int) -> Array[InputCommand]:
	var commands: Array[InputCommand] = []
	for frame in FRAME_LIMIT:
		await _tree.process_frame
		if _client.session.tick < from_tick + count:
			continue
		for command in _client.session.history:
			if command.tick >= from_tick and command.tick < from_tick + count:
				commands.append(command)
		break
	return commands


func _tap(code: Key) -> void:
	_key(code, true)
	_key(code, false)


func _key(code: Key, pressed: bool, echo: bool = false, flush: bool = true) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)
	if flush:
		Input.flush_buffered_events()


func _mouse_motion(relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.relative = relative
	event.screen_relative = relative
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func test_crouch_key_lowers_the_live_camera_and_releases() -> void:
	if not await _start_client(60):
		return
	var tick := _client.session.tick
	_key(KEY_C, true)
	cleanup(func() -> void: _key(KEY_C, false))
	var commands := await _commands(tick, 2)
	if not check(commands.size() == 2 and commands[0].has(InputCommand.CROUCH)
			and commands[1].has(InputCommand.CROUCH), "held C keeps setting crouch across ticks"):
		return
	for _frame in FRAME_LIMIT:
		if _client.session.player.crouched:
			break
		await _tree.process_frame
	var tuning := _client.rules.movement
	var relative_y := _client.camera.global_position.y - _client._feet.y
	check(_client.session.player.crouched and _client.predictor.soldier.crouched, "actual local server and prediction crouch")
	check_near(relative_y, tuning.view_height(true), 0.005, "camera uses authoritative crouch eye")
	_key(KEY_C, false)
	commands = await _commands(_client.session.tick, 2)
	check(commands.size() == 2 and not commands[0].has(InputCommand.CROUCH)
		and not commands[1].has(InputCommand.CROUCH), "released C clears the input")
	check(not _client.predictor.soldier.crouched, "camera rises where the standing capsule fits")
	check_near(_client.camera.global_position.y - _client._feet.y, tuning.view_height(), 0.005, "camera returns to its standing eye")
