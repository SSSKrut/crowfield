extends TestCase
## The client's view of the network: interpolation of other soldiers, the
## clock, acknowledgements, reconciliation of the prediction, and shots at
## soldiers drawn in the past.


func test_grounded_boots_lift_only_leg_pose_on_a_slope() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var asset := CharacterAsset.load_asset()
	var view := asset.instantiate()
	tree.root.add_child(view)
	cleanup(view.free)
	view.face(Vector3.ZERO, 0.0)
	view.player.seek(0.0, true)
	var ground := Terrain.create(6, func(x: float, z: float) -> float: return 0.75 * x + 0.24 * z)
	var skeleton := view.skeleton
	var highest_foot: int = asset.bones["Foot.R"]
	var hip: int = asset.bones["Hips"]
	var hand: int = asset.bones["Palm1.R"]
	var hip_pose := skeleton.get_bone_global_pose(hip)
	var hand_pose := skeleton.get_bone_global_pose(hand)
	var rig := RagdollRig.build(asset, skeleton)
	var initial := skeleton.global_transform * skeleton.get_bone_global_pose(highest_foot)
	var before := GroundedFeet.sole_contact(initial, ground)
	check(before.y < ground.height_at(before.x, before.z) - 0.055, "the uphill boot begins below the test slope")

	view.set_foot_terrain(ground)
	check(view.grounded_feet.active, "the visual modifier follows grounded detail")
	view.grounded_feet.place_boots()
	var applied := skeleton.global_transform * skeleton.get_bone_global_pose(highest_foot)
	var after := GroundedFeet.sole_contact(applied, ground)
	check(after.y > ground.height_at(after.x, after.z) - 0.015, "the boot clears the slope to the sole tolerance")
	check(before.distance_squared_to(Vector3(after.x, before.y, after.z)) < 0.000004, "boot retains its horizontal contact")
	check(initial.basis.is_equal_approx(applied.basis), "boot keeps its pitch and roll")
	check_equal(skeleton.get_bone_global_pose(hip), hip_pose, "pelvis has the current animation")
	check_equal(skeleton.get_bone_global_pose(hand), hand_pose, "weapon hand has the current animation")

	view.set_foot_terrain(null)
	check(not view.grounded_feet.active, "airborne and coarse models skip the correction")

	view.player.seek(0.0, true)
	view.set_foot_terrain(ground)
	var pool := RagdollPool.new(rig, view.get_world_3d().space)
	var fall := view.fall(pool, Vector3.ZERO, CharacterView.Strike.new(-1, Vector3.ZERO, Vector3.ZERO))
	if check(fall, "an adjusted soldier still enters the ragdoll pool"):
		var boot := RagdollRig.Part.FOOT_RIGHT
		var frozen := view.ragdoll.transforms()[boot] * rig.parts[boot].to_part.affine_inverse()
		check(frozen.is_equal_approx(applied), "ragdoll inherits the adjusted boot at death")
		check(not view.grounded_feet.active, "ground correction ends at the ragdoll transition")
		view.stand_up()
		check_equal(pool.lent(), 0, "standing up returns the ragdoll to the pool")
	pool.close()


func test_valley_ambience_tracks_the_water_and_respects_mute() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	await root.get_tree().process_frame
	var sounds := Sounds.new(1.0)
	var muted := Sounds.new(0.0)
	root.add_child(sounds)
	root.add_child(muted)
	cleanup(func() -> void:
		sounds.free()
		muted.free())
	sounds.start_ambience(MapScene.prototype())
	check(sounds.get_node_or_null("ValleyWind") == null, "the practice map has no wind loop")
	check(sounds.get_node_or_null("ValleyRiver") == null, "the practice map has no river loop")
	var valley := MapScene.named("valley")
	muted.start_ambience(valley)
	check_equal(muted.get_child_count(), 0, "muted games create no audio players")

	sounds.start_ambience(valley)
	var wind := sounds.get_node_or_null("ValleyWind") as AudioStreamPlayer
	var river := sounds.get_node_or_null("ValleyRiver") as AudioStreamPlayer3D
	if not check(wind != null and river != null, "Valley has both ambient voices"):
		return
	check((wind.stream as AudioStreamOggVorbis).loop, "wind loops")
	check((river.stream as AudioStreamOggVorbis).loop, "river loops")
	var voices := sounds.get_child_count()
	sounds.start_ambience(valley)
	check_equal(sounds.get_child_count(), voices, "starting twice keeps just one pair of voices")
	var x := 42.0
	var source := Vector3(x, valley.waters[0].center.y, ValleyMap.river_z(x))
	sounds.update_ambience(source + Vector3(0, 2, 4), 1.0)
	check_equal(river.global_position, source, "river follows the meandering water line")
	check(river.volume_db > -20.0, "river plays at the bank")
	sounds.update_ambience(source + Vector3(0, 2, 50), 1.0)
	check(river.volume_db <= -79.0, "the river falls silent away from water")


func test_reload_audio_tracks_visible_contacts_without_repeating() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var sounds := Sounds.new(1.0)
	tree.root.add_child(sounds)
	cleanup(sounds.free)
	var rifle := WeaponTuning.Kind.ASSAULT_RIFLE
	var ready := Arsenal.Action.READY
	var reload := Arsenal.Action.RELOADING
	var release := ViewModel.RELOAD_RELEASE_PROGRESS
	var seat := ViewModel.RELOAD_SEAT_PROGRESS
	sounds.weapon(rifle, Arsenal.EVENT_RELOAD_STARTED)
	check(not sounds._magazine_out.playing, "start alone no longer makes the release sound")
	sounds.update_reload(rifle, reload, release - 0.01, Arsenal.EVENT_RELOAD_STARTED)
	check(not sounds._magazine_out.playing, "a cue waits for the visible contact")
	sounds.update_reload(rifle, reload, release, 0)
	check(sounds._magazine_out.playing, "extraction plays at its animation contact")
	sounds._magazine_out.stop()
	sounds.update_reload(rifle, reload, release - 0.03, 0)
	sounds.update_reload(rifle, reload, release + 0.02, 0)
	check(not sounds._magazine_out.playing, "rewinding through a predicted contact stays quiet")
	sounds.update_reload(rifle, reload, seat, 0)
	check(sounds._magazine_in.playing, "seating plays before the action completes")
	sounds._magazine_in.stop()
	sounds.update_reload(rifle, ready, 0.0, Arsenal.EVENT_RELOADED)
	sounds.update_reload(rifle, reload, seat + 0.05, 0)
	check(not sounds._magazine_in.playing, "a correction across completion cannot repeat the seating click")
	sounds.weapon(rifle, Arsenal.EVENT_RELOADED)
	check(not sounds._magazine_in.playing, "completion no longer plays a second click")

	sounds.update_reload(rifle, reload, seat + 0.08, Arsenal.EVENT_RELOAD_STARTED)
	check(sounds._magazine_in.playing and not sounds._magazine_out.playing, "a skipped interval plays its latest contact")
	sounds._magazine_in.stop()
	sounds.update_reload(rifle, reload, release, Arsenal.EVENT_RELOAD_STARTED)
	check(sounds._magazine_out.playing, "a subsequent reload cues its own release")
	sounds.update_reload(WeaponTuning.Kind.PISTOL, Arsenal.Action.EQUIPPING, seat, Arsenal.EVENT_EQUIP_STARTED)
	check(not sounds._magazine_in.playing, "an interrupted reload has no scheduled seating cue")


func test_remote_shots_behind_cover_filter_and_reuse_voices() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var scene := Node3D.new()
	tree.root.add_child(scene)
	cleanup(scene.free)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.make_current()
	var wall := StaticBody3D.new()
	wall.collision_layer = Game.LAYER_STATIC
	wall.position = Vector3(0, 0, -3)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 3, 0.5)
	shape.shape = box
	wall.add_child(shape)
	scene.add_child(wall)
	var sounds := Sounds.new(1.0)
	scene.add_child(sounds)
	await tree.physics_frame
	await tree.process_frame
	var kind := WeaponTuning.Kind.ASSAULT_RIFLE
	var blocked := Vector3(0, 0, -6)
	sounds.shot_at(kind, blocked)
	var first := sounds._positional[0]
	check_equal(first.attenuation_filter_cutoff_hz, Sounds.COVER_FILTER_HZ, "solid cover filters the report")
	sounds._next_positional = 0
	sounds.shot_at(kind, -blocked)
	check_equal(first.attenuation_filter_cutoff_hz, Sounds.DIRECT_FILTER_HZ, "the next clear shot resets a reused voice")
	var direct_gain := first.volume_db
	sounds._next_positional = 0
	sounds.shot_at(kind, blocked)
	check(first.volume_db < direct_gain - 4.0, "a blocked report is quieter at the same distance")
	sounds._next_positional = 0
	sounds.impact_at(Vector3(1, 0, -1))
	check_equal(first.attenuation_filter_cutoff_hz, Sounds.DIRECT_FILTER_HZ, "an impact resets a reused voice")

	for index in Sounds.SHOT_COVER_RAYS_PER_FRAME:
		sounds.shot_at(kind, blocked)
	check_equal(sounds._shot_cover_rays, Sounds.SHOT_COVER_RAYS_PER_FRAME, "a single frame has a bounded ray budget")
	var overflow := sounds._positional[sounds._next_positional]
	sounds.shot_at(kind, blocked)
	check_equal(overflow.attenuation_filter_cutoff_hz, Sounds.DIRECT_FILTER_HZ, "overflow still has a positional report")
	var previous_frame := sounds._shot_cover_frame
	await tree.process_frame
	sounds.shot_at(kind, blocked * 200)
	check_equal(sounds._shot_cover_frame, previous_frame, "an inaudible shot does not open a new ray budget")
	sounds.shot_at(kind, blocked)
	check_equal(sounds._shot_cover_rays, 1, "the next frame restores its ray budget")


func test_remote_spatial_reports_use_distinct_distance_edits() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var scene := Node3D.new()
	tree.root.add_child(scene)
	cleanup(scene.free)
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.make_current()
	var sounds := Sounds.new(1.0)
	scene.add_child(sounds)
	var kind := WeaponTuning.Kind.RIFLE
	for distance: float in [8.0, 32.0, 72.0]:
		sounds.shot_at(kind, Vector3(0, 0, -distance))
	var near := sounds._positional[0]
	var middle := sounds._positional[1]
	var far := sounds._positional[2]
	check_equal(near.stream, Sounds.GUNSHOTS[kind], "the close cue has the original attack")
	check_equal(middle.stream, Sounds.MID_REPORTS[kind], "middle range has a separate report")
	check_equal(far.stream, Sounds.FAR_REPORTS[kind], "distant cue has a separate report")
	check(far.stream.get_length() > middle.stream.get_length() and middle.stream.get_length() > near.stream.get_length(),
		"the outdoor reflections add natural decay time with distance")
	check(far.volume_db < middle.volume_db and middle.volume_db < near.volume_db,
		"each report still falls off with distance")
	check_equal(sounds._next_positional, 3, "each shot uses only one spatial voice")
	sounds.weapon(kind, Arsenal.EVENT_FIRED)
	check_equal(sounds._shots[kind][0].stream, near.stream, "the local trigger retains its immediate cue")


func test_embedded_clock_ignores_time_spent_loading_the_map() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var max_fps := Engine.max_fps
	var mouse_mode := Input.mouse_mode
	var client := SlowMapClient.new()
	client.set_meta("arguments", PackedStringArray(["-map=prototype", "-volume=0", "-config-dir="]))
	client.left.connect(fail)
	cleanup(func() -> void:
		client.free()
		Engine.max_fps = max_fps
		Input.mouse_mode = mouse_mode)
	tree.root.add_child(client)
	for frame in 120:
		await tree.process_frame
		if client.session != null and client.session.received >= 5:
			break
	if not check(client.session != null and client.session.received >= 5, "the embedded client did not receive sustained snapshots"):
		return
	check_equal(client.session.welcome.server_tick, client.map_loaded_tick, "clock seed after the blocking map load")
	check_equal(client.session.resyncs, 0, "startup clock jumps")


func test_embedded_clock_ignores_frame_stall_during_hello_round_trip() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var max_fps := Engine.max_fps
	var mouse_mode := Input.mouse_mode
	var client := SlowHelloClient.new()
	client.set_meta("arguments", PackedStringArray(["-map=prototype", "-volume=0", "-config-dir="]))
	client.left.connect(fail)
	cleanup(func() -> void:
		client.free()
		Engine.max_fps = max_fps
		Input.mouse_mode = mouse_mode)
	tree.root.add_child(client)
	for frame in 180:
		await tree.process_frame
		if client.session != null and client.session.received >= 18:
			break
	if not check(client.stalled and client.session != null and client.session.received >= 18, "the embedded client did not recover from the stall"):
		return
	check_equal(client.session.resyncs, 0, "startup clock jumps after stalled hello")


class SlowHelloClient extends ClientApp:
	var stalled := false

	func _process(delta: float) -> void:
		super._process(delta)
		if not stalled and _handshake != null and _handshake._sent >= 0:
			stalled = true
			OS.delay_msec(425)


class SlowMapClient extends ClientApp:
	var map_loaded_tick := -1

	func _load_map(map_name: String) -> Variant:
		OS.delay_msec(400)
		var loaded: Variant = super._load_map(map_name)
		map_loaded_tick = _local.server.tick
		return loaded


func _soldier(at: Vector3, velocity: Vector3, alive: bool = true, grounded: bool = false, yaw: float = 0.0) -> Soldier:
	var soldier := Soldier.new()
	soldier.position = at
	soldier.velocity = velocity
	soldier.alive = alive
	soldier.grounded = grounded
	soldier.yaw = yaw
	return soldier


func test_hermite_follows_steady_motion_exactly() -> void:
	var remote := RemoteSoldier.new()
	var velocity := Vector3(3, 0, -4)
	for tick in range(100, 131, 3):
		remote.add(tick, _soldier(velocity * (float(tick - 100) / Game.TICK_RATE), velocity))
	for render_tick: float in [100.0, 101.5, 107.25, 119.9, 130.0]:
		remote.evaluate(render_tick)
		var want := velocity * ((render_tick - 100) / Game.TICK_RATE)
		check(remote.position.distance_to(want) <= 1e-4, "at %.2f: %s, want %s" % [render_tick, remote.position, want])


func test_remote_soldier_past_the_newest_state() -> void:
	var remote := RemoteSoldier.new()
	remote.add(10, _soldier(Vector3.ZERO, Vector3(6, 0, 0)))
	remote.add(13, _soldier(Vector3(0.3, 0, 0), Vector3(6, 0, 0)))
	remote.evaluate(16)
	check_near(remote.position.x, 0.6, 1e-4, "three ticks past the newest state")
	remote.evaluate(1000)
	check_near(remote.position.x, 0.3 + 6.0 * RemoteSoldier.MAX_EXTRAPOLATION / Game.TICK_RATE, 1e-4, "long past the newest state")
	remote.evaluate(5)
	check(remote.position == Vector3.ZERO, "before the oldest state %s, want the oldest" % remote.position)
	remote.add(12, _soldier(Vector3(9, 9, 9), Vector3.ZERO))
	remote.evaluate(12)
	check_near(remote.position.y, 0.0, 1e-6, "a late older state was used")


func test_remote_soldier_stays_on_the_floor_and_turns_the_short_way() -> void:
	var remote := RemoteSoldier.new()
	remote.add(0, _soldier(Vector3.ZERO, Vector3(0, -0.5, 0), true, true, TAU - 0.1))
	remote.add(6, _soldier(Vector3.ZERO, Vector3(0, -0.5, 0), true, true, 0.1))
	remote.evaluate(3)
	check_equal(remote.position.y, 0.0, "a grounded soldier dipped")
	check(absf(Game.remainder(remote.yaw)) <= 1e-4, "turned the long way: yaw %.3f" % remote.yaw)
	remote.evaluate(100)
	check_equal(remote.position.y, 0.0, "extrapolation sank a grounded soldier")


## A soldier seen a second apart, running and then dead: it is drawn alive
## along the way and dies where the server has it dead, at the tick of that
## state, with the momentum it ran with.
func test_remote_footsteps_follow_grounded_render_samples() -> void:
	var remote := RemoteSoldier.new()
	remote.add(0, _soldier(Vector3.ZERO, Vector3.ZERO, true, true))
	remote.add(6, _soldier(Vector3.UP, Vector3.ZERO))
	remote.add(12, _soldier(Vector3.ZERO, Vector3.ZERO, true, true))
	for sample in [[0.0, true], [5.5, true], [6.0, false], [11.9, false], [12.0, true], [20.0, true]]:
		remote.evaluate(sample[0])
		check_equal(remote.grounded, sample[1], "grounded at render tick %s" % sample[0])


func test_remote_footsteps_require_continuous_nearby_ground_travel() -> void:
	var entry := SoldierViews.Entry.new()
	var remote := RemoteSoldier.new()
	remote.grounded = true
	check(not entry.footstep_due(remote, 0.5, 0.1, true), "first sample made a step")
	for step in range(1, 5):
		remote.position.x = step * 0.4
		check_equal(entry.footstep_due(remote, 0.5, 0.1, true), step == 4, "walking sample %d" % step)
	remote.position = Vector3(10, 0, 0)
	check(not entry.footstep_due(remote, 0.5, 0.1, true), "teleport made a step")
	remote.grounded = false
	remote.position.x += 0.8
	check(not entry.footstep_due(remote, 0.5, 0.1, true), "airborne soldier made a step")
	remote.grounded = true
	remote.position.x += 0.8
	check(not entry.footstep_due(remote, 0.5, 0.1, true), "landing reused airborne travel")
	remote.position.x += 0.8
	check(not entry.footstep_due(remote, 0.5, 0.1, false), "distant soldier made a step")
	remote.position.x += 0.8
	check(not entry.footstep_due(remote, 0.5, 0.1, true), "re-entry reused distant travel")
	for i in 12:
		remote.position.x += 0.1
		check(not entry.footstep_due(remote, 0.0, 0.1, true), "stationary correction made a step")
	remote.position.x += 0.4
	check(not entry.footstep_due(remote, 0.5, 0.1, true), "movement reused stationary corrections")


func test_remote_soldier_dies_where_it_died() -> void:
	var remote := RemoteSoldier.new()
	var run := Vector3(5, 0, 0)
	remote.add(100, _soldier(Vector3.ZERO, run))
	remote.add(160, _soldier(Vector3(4, 0, 0), Vector3.ZERO, false))
	remote.evaluate(150)
	check(remote.alive, "dead at tick 150 at x=%.2f, before the tick of its death" % remote.position.x)
	remote.evaluate(160)
	check(not remote.alive and remote.position.distance_to(Vector3(4, 0, 0)) <= 1e-4, "at the tick of its death: alive %s at %s" % [remote.alive, remote.position])
	check(remote.last_alive_velocity() == run, "falls with velocity %s, it ran at %s" % [remote.last_alive_velocity(), run])


## A state that moves where the soldier is drawn is kept as an offset that
## fades, and a jump as far as a respawn is shown at once.
func test_remote_soldier_catches_up_smoothly() -> void:
	var remote := RemoteSoldier.new()
	remote.add(0, _soldier(Vector3.ZERO, Vector3.ZERO))
	remote.add(10, _soldier(Vector3.ZERO, Vector3.ZERO))
	remote.evaluate(15)
	var drawn := remote.position
	remote.add(20, _soldier(Vector3(1, 0, 0), Vector3.ZERO))
	remote.keep(drawn, 15)
	remote.evaluate(15)
	check(remote.position.distance_to(drawn) <= 1e-5 and remote.offset.length() > 0.4,
		"after a new state the soldier is drawn at %s with offset %s, was at %s" % [remote.position, remote.offset, drawn])
	for i in 30:
		remote.smooth(1.0 / 60)
	check(remote.offset.length() < 0.01, "the correction has not faded: %s" % remote.offset)
	remote.evaluate(25)
	drawn = remote.position
	remote.add(30, _soldier(Vector3(50, 0, 0), Vector3.ZERO))
	remote.keep(drawn, 25)
	check(remote.offset == Vector3.ZERO, "a long jump was smoothed: %s" % remote.offset)


func test_interpolation_clock_follows_snapshots() -> void:
	var clock := InterpolationClock.new(20)
	if not check_equal(clock.delay, 7.0, "delay in ticks at 20 snapshots a second"):
		return
	clock.observe(100)
	check_equal(clock.render_tick, 93.0, "the start")
	# The frame clock runs a little fast; snapshots pull it back.
	for tick in range(103, 401, 3):
		clock.advance(3.3 / Game.TICK_RATE)
		clock.observe(tick)
	check(absf(400 - clock.delay - clock.render_tick) <= 3, "the clock is %.2f ticks off its target" % (400 - clock.delay - clock.render_tick))
	clock.observe(1000)
	check_equal(clock.render_tick, 1000 - clock.delay, "a big jump was smoothed instead of taken")


func test_ack_tracker() -> void:
	var acks := AckTracker.new()
	for sequence in [10, 11, 13, 12, 9]:
		acks.observe(sequence)
	# Newest 13; 12, 11, 10 and 9 were received too.
	check(acks.has and acks.latest == 13 and acks.bits == 0b1111, "latest %d bits %d" % [acks.latest, acks.bits])
	acks.observe(13 + 32)
	check(acks.latest == 45 and acks.bits == 1 << 31, "after a jump of 32: latest %d bits %d" % [acks.latest, acks.bits])
	acks.observe(45 + 33)
	check(acks.latest == 78 and acks.bits == 0, "after a jump of 33: latest %d bits %d" % [acks.latest, acks.bits])
	acks = AckTracker.new()
	acks.observe(65535)
	acks.observe(1)
	check(acks.latest == 1 and acks.bits == 0b10, "across the wrap: latest %d bits %d" % [acks.latest, acks.bits])


func _space() -> RID:
	var space := PhysicsServer3D.space_create()
	var made := MapScene.prototype().build_collision(space)
	cleanup(func() -> void:
		MapScene.free_collision(made)
		PhysicsServer3D.free_rid(space))
	return space


func _predictor(space: RID) -> Predictor:
	var predictor := Predictor.new(space, Rules.new())
	cleanup(func() -> void: predictor.close())
	return predictor


## _route crosses the ramp, jumps onto the platform and walks along its edge,
## so predictions start from slopes, steps and the air.
static func _route(step: int, tick: int) -> InputCommand:
	if step < 36:
		return InputCommand.create(tick, 1, 0, PI / 2, 0, InputCommand.SPRINT)
	if step < 110:
		var buttons := InputCommand.SPRINT
		if step >= 66 and step < 84:
			buttons |= InputCommand.JUMP
		return InputCommand.create(tick, 1, 0, 0, 0.1, buttons)
	if step < 160:
		return InputCommand.create(tick, 1, 0.5, -PI / 2, 0, 0)
	return InputCommand.create(tick, 0, 0, 0, 0, 0)


## _confirmed is the private state a snapshot carries of a soldier after a
## tick.
func _confirmed(tick: int, soldier: Soldier) -> PlayerState:
	var state := PlayerState.new()
	state.processed = true
	state.last_processed_tick = tick
	state.soldier = soldier.id
	state.position = soldier.position
	state.velocity = soldier.velocity
	state.health = soldier.health
	state.arsenal = soldier.arsenal.copy()
	return state


func _standing(id: int, at: Vector3) -> Soldier:
	var soldier := _soldier(at, Vector3.ZERO)
	soldier.id = id
	soldier.health = Game.MAX_HEALTH
	return soldier


func test_achieved_speed_stops_at_a_wall_with_forward_held() -> void:
	var predictor := _predictor(_space())
	predictor.reconcile(_confirmed(0, _standing(1, Vector3(0, 0.01, -2))))
	predictor.predict(InputCommand.create(1, 1, 0, 0, 0, 0))
	check(predictor.achieved_speed > 4.0, "prediction measured no motion on the open floor")
	for tick in range(2, 60):
		predictor.predict(InputCommand.create(tick, 1, 0, 0, 0, 0))
	check(Game.horizontal_length(predictor.soldier.velocity) > 4.0, "forward command was not still held")
	check_near(predictor.achieved_speed, 0.0, 0.03, "visual speed while blocked")


func test_prediction_stays_visible_when_server_is_ahead_of_the_client() -> void:
	var predictor := _predictor(_space())
	var confirmed := _standing(1, Vector3.ZERO)
	predictor.reconcile(_confirmed(10, confirmed))
	predictor.predict(InputCommand.create(11, 0, 0, 0, 0, 0))
	predictor.reconcile(_confirmed(15, confirmed))
	for tick in range(12, 16):
		var result := predictor.predict(InputCommand.create(tick, 1, 0, 0, 0, InputCommand.FIRE))
		check(predictor.started, "a late command hid the predicted soldier at tick %d" % tick)
		check(not result.has(Arsenal.EVENT_FIRED), "a late command replayed a shot")
		check_equal(predictor.last, 15, "prediction tick after a late command")
	predictor.predict(InputCommand.create(16, 1, 0, 0, 0, 0))
	check(predictor.started and predictor.last == 16, "prediction did not resume with the next new tick")
	predictor.predict(InputCommand.create(14, 0, 0, 0, 0, 0))
	check(not predictor.started, "a real backward clock jump did not reset prediction")


func test_reconcile_snaps_without_replaying_a_gap_older_than_history() -> void:
	var predictor := _predictor(_space())
	var confirmed := _standing(1, Vector3(0, 2, 0))
	var newest := 4 * Predictor.HISTORY
	predictor.predict(InputCommand.create(newest, 1, 0, 0, 0, 0))
	predictor.reconcile(_confirmed(1, confirmed))
	check_equal(predictor.last, 1, "prediction tick after snapping")
	check_equal(predictor.soldier.position, confirmed.position, "position after snapping")
	predictor.predict(InputCommand.create(newest + 1, 1, 0, 0, 0, 0))
	check_equal(predictor.last, newest + 1, "prediction tick after the next command")


## The server runs one command differently from the prediction; the client
## corrects once, replays its newer commands, and ends where the server is.
func test_reconcile_replays_from_the_server_state() -> void:
	var rules := Rules.new()
	var predictor := _predictor(_space())
	var server := CharacterController.new(_space(), rules.movement, Game.LAYER_STATIC | Game.LAYER_VEHICLE)
	cleanup(func() -> void: server.close())
	var authoritative := Soldier.new()
	authoritative.id = 0x1000
	authoritative.alive = true
	authoritative.health = Game.MAX_HEALTH
	authoritative.arsenal = Arsenal.create(Arsenal.default_loadout(), rules.weapons)
	server.teleport(authoritative, MapScene.prototype().spawn)
	const LAG := 10
	const DIFFERS := 40
	var history := {}
	for tick in 200:
		var command := _route(tick, tick)
		predictor.predict(command)
		if tick == DIFFERS:
			command = InputCommand.create(tick, 1, 0, PI / 2, 0, InputCommand.SPRINT | InputCommand.JUMP)
		server.run_command(rules.weapons, authoritative, command, 0)
		history[tick] = authoritative.copy()
		if tick >= LAG:
			predictor.reconcile(_confirmed(tick - LAG, history[tick - LAG]))
	check_equal(predictor.corrections, 1, "corrections, want one for the tick that differed")
	check(predictor.soldier.position == authoritative.position and predictor.soldier.velocity == authoritative.velocity,
		"prediction %s %s, server %s %s" % [predictor.soldier.position, predictor.soldier.velocity, authoritative.position, authoritative.velocity])


## A new session may reuse the tick numbers of the last one, whose commands the
## server never saw: the prediction must not replay them.
func test_join_forgets_the_last_session() -> void:
	var predictor := _predictor(_space())
	var spawn := MapScene.prototype().spawn
	predictor.predict(InputCommand.create(0, 1, 0, 0, 0, 0))
	predictor.reconcile(_confirmed(0, _standing(0x1000, spawn)))
	for tick in range(1, 31):
		predictor.predict(InputCommand.create(tick, 1, 0, 0, 0, 0))
	# In the new one the server has stood the soldier still until tick 20, and
	# the client's first command is for tick 25.
	predictor.join(7)
	predictor.predict(InputCommand.create(25, 0, 0, 0, 0, 0))
	predictor.reconcile(_confirmed(20, _standing(0x1000, spawn)))
	var moved := Vector2(predictor.soldier.position.x - spawn.x, predictor.soldier.position.z - spawn.z).length()
	check(moved <= 1e-3, "the soldier moved %.3f m on commands of the last session" % moved)


## The dead are not predicted: the soldier stays where the server has it while
## commands go on, and a new soldier starts the prediction without a
## correction.
func test_death_stops_the_prediction_until_a_new_soldier() -> void:
	var predictor := _predictor(_space())
	var spawn := MapScene.prototype().spawn
	var run := func(from: int, to: int) -> void:
		for tick in range(from, to):
			predictor.predict(InputCommand.create(tick, 1, 0, 0, 0, InputCommand.FIRE))
	run.call(0, 1)
	predictor.reconcile(_confirmed(0, _standing(0x1000, spawn)))
	run.call(1, 10)
	var dead := _confirmed(5, _standing(0x1000, Vector3(1, 0, 3)))
	dead.health = 0
	dead.respawn = 60
	predictor.reconcile(dead)
	run.call(10, 40)
	check(not predictor.started and predictor.soldier.position == dead.position, "the dead soldier was predicted to %s" % predictor.soldier.position)
	predictor.reconcile(_confirmed(38, _standing(0x2000, spawn)))
	check(predictor.started and predictor.corrections == 0 and predictor.soldier.id == 0x2000,
		"the new soldier: started %s, %d corrections, soldier 0x%04x" % [predictor.started, predictor.corrections, predictor.soldier.id])


## Through the whole client path — session, interpolation, lag compensation —
## a shot without spread at the drawn body of the nearest enemy bot hits,
## as long as nothing static stands in the way.
func test_shots_at_drawn_bots_hit() -> void:
	var rules := Rules.new()
	var rifle := rules.weapons.rifle
	rifle.hip_spread = 0
	rifle.aim_spread = 0
	rifle.move_spread = 0
	rifle.air_spread = 0
	rifle.bloom = 0
	rifle.kick_pitch = 0
	rifle.kick_yaw = 0
	var configure := func(settings: ServerSettings) -> void:
		settings.bots = 48
		settings.bot_ai = false
		settings.max_players = 1
	var harness = preload("res://tests/harness.gd").new(configure, rules)
	cleanup(func() -> void: harness.close())
	var server: Server = harness.server
	var space := _space()
	var client := HeadlessClient.new(harness.listener.dial(), "aimer", rules, 1, space, func(_map: String) -> MapScene: return harness.server.scene)
	cleanup(func() -> void: client.close())
	var state := PhysicsServer3D.space_get_direct_state(space)
	var shots := 0
	var clear := 0
	for tick in 12 * Game.TICK_RATE:
		var aimed := _enemy_in_view(client, rules)
		var command := InputCommand.new()
		command.weapon = 1
		if not aimed.is_empty() and tick > Game.TICK_RATE:
			var to: Vector3 = aimed[1] - aimed[0]
			command = InputCommand.create(0, 0, 0, atan2(to.x, -to.z), atan2(to.y, Vector2(to.x, to.z).length()),
				InputCommand.FIRE if tick % 10 == 0 else 0)
			command.weapon = 1
		var fired := _tick(client, command)
		if fired != null and not aimed.is_empty():
			shots += 1
			var reach: float = aimed[0].distance_to(aimed[1])
			var hit := state.intersect_ray(PhysicsRayQueryParameters3D.create(fired.origin, fired.origin + fired.direction * reach, Game.LAYER_STATIC))
			if hit.is_empty():
				clear += 1
		server.step()
	var hits := server.total_hits
	check(shots >= 15 and hits >= clear * 9 / 10, "%d hits of %d shots with a clear line (%d shots)" % [hits, clear, shots])


## _enemy_in_view is [the eye, the body of the nearest enemy bot within 25 m]
## where the client draws it now, or [].
static func _enemy_in_view(client: HeadlessClient, rules: Rules) -> Array:
	if client.session == null or not client.predictor.started:
		return []
	var own := client.session.local_soldier()
	if own == null:
		return []
	var eye := client.predictor.soldier.position + Vector3(0, rules.movement.eye_height, 0)
	var best := 25.0
	var found := Vector3.INF
	for known: KnownSoldier in client.session.soldiers.values():
		if known.soldier.id == own.id or known.soldier.team == own.team or known.remote.count == 0:
			continue
		known.remote.evaluate(client.session.clock.render_tick)
		if not known.remote.alive:
			continue
		var distance := known.remote.position.distance_to(client.predictor.soldier.position)
		if distance < best and distance > 3:
			best = distance
			found = known.remote.position + Vector3(0, 0.85, 0)
	if found == Vector3.INF:
		return []
	return [eye, found]


## _tick plays a tick of a client with a given command, the way the game does,
## and returns the shot it fired, or null.
static func _tick(client: HeadlessClient, command: InputCommand) -> Shot:
	if client.session == null:
		client.handshake.poll()
		if client.handshake.done():
			client.session = client.handshake.session
			client.predictor.join(client.session.welcome.match_seed)
		return null
	var sent := client.session.send_command(command)
	if sent == null:
		return null
	var result := client.predictor.predict(sent)
	if client.session.poll():
		client.predictor.reconcile(client.session.player)
	client.session.clock.advance(Game.TICK_DELTA)
	client.session.update_remotes(Game.TICK_DELTA)
	return result.shot if result.has(Arsenal.EVENT_FIRED) else null
