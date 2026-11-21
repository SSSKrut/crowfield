extends TestCase


func test_steps_follow_drawn_motion_and_landing_is_a_separate_event() -> void:
	var view := ViewModel.new()
	cleanup(func() -> void: view.free())
	const FRAME := 1.0 / 60.0
	var steps := 0
	for frame in 121:
		if view.footing(FRAME, Vector3(frame / 15.0, 0, 0), true, 0.5, true) == ViewModel.Footfall.STEP:
			steps += 1
	check_equal(steps, 5, "8 m of walking fires five footfalls")

	for frame in 12:
		check_equal(view.footing(FRAME, Vector3(8, 0, 0), true, 0.5, true),
			ViewModel.Footfall.NONE, "a blocked movement key cannot generate a step")
	for frame in 12:
		var height := sin(PI * frame / 12) * 0.55
		check_equal(view.footing(FRAME, Vector3(8, height, 0), false, 0.5, true),
			ViewModel.Footfall.NONE, "airborne feet cannot generate steps")
	check_equal(view.footing(FRAME, Vector3(8, 0, 0), true, 0, true),
		ViewModel.Footfall.LAND, "ground contact emits one distinct landing")
	check_equal(view.footing(FRAME, Vector3(8, 0, 0), true, 0, true),
		ViewModel.Footfall.NONE, "continued ground contact does not repeat the landing")
	check_equal(view.footing(FRAME, Vector3(28, 0, 0), true, 1.0, true),
		ViewModel.Footfall.NONE, "a sudden correction cannot generate steps")


func test_short_tracer_survives_its_first_frame() -> void:
	var effects := Effects.new()
	cleanup(func() -> void: effects.free())
	effects.shot(Vector3.ZERO, Vector3(0.8, 0, 0), true, Vector3.LEFT)
	effects.update(0.1)
	check_equal(effects._tracers.visible_instance_count, 1, "a nearby shot is visible on its first frame")
	check_equal(effects._impact_normal[0], Vector3.LEFT, "the surface normal travels with the impact")
	effects.update(0.1)
	check_equal(effects._tracers.visible_instance_count, 0, "the streak expires after the initial frame")
