extends TestCase

const PlaytestTrace := preload("res://client/playtest_trace.gd")


func test_playtest_trace_evicts_old_data_and_caps_dense_events() -> void:
	var trace := PlaytestTrace.new()
	for i in 101:
		var now := i * PlaytestTrace.SAMPLE_INTERVAL_USEC
		trace.frame(now, 16_000, Vector2.ZERO)
		trace.sample(now, {"position": [i, 0, 0]})
	for i in 200:
		trace.event(9_000_000 + i, {"type": "movement_key", "pressed": i % 2 == 0, "index": i})
	var snapshot := trace.snapshot(10_000_000)
	check_equal(snapshot["samples"].size(), PlaytestTrace.SAMPLE_LIMIT, "sample count within the last five seconds")
	check_equal(snapshot["samples"][0]["age_ms"], 5000.0, "oldest age")
	check_equal(snapshot["events"].size(), PlaytestTrace.EVENT_LIMIT, "dense event count")
	check_equal(snapshot["events"].back()["index"], 199, "most recent event")
	check_equal(trace.snapshot(15_000_001)["samples"].size(), 0, "expired samples")
	check_equal(trace.snapshot(15_000_001)["events"].size(), 0, "expired events")


func test_playtest_trace_aggregates_frame_stalls_and_detaches_snapshot() -> void:
	var trace := PlaytestTrace.new()
	check(trace.frame(0, 16_000, Vector2.ZERO), "first frame should sample")
	trace.sample(0, {"position": [0, 0, 0]})
	check(not trace.frame(40_000, 40_000, Vector2(0.25, 0.125)), "sampled sooner than the interval")
	trace.frame(200_000, 160_000, Vector2(0.5, -0.125))
	trace.sample(200_000, {"position": [1, 0, 0]})
	trace.frame(280_000, 80_000, Vector2(0.125, 0))
	var snapshot := trace.snapshot(280_000)
	check_equal(snapshot["longest_frame_ms"], 160.0, "longest frame in captured window")
	check_equal(snapshot["samples"].back()["look_delta_radians"], [0.75, 0.0], "aggregated look")
	check_equal(snapshot["look_delta_since_sample_radians"], [0.125, 0.0], "look after last complete sample")
	snapshot["samples"].back()["position"][0] = -1
	check_equal(trace.snapshot(280_000)["samples"].back()["position"][0], 1, "snapshot data independently owned")


func test_playtest_trace_keeps_run_end_when_records_overflow() -> void:
	var directory := OS.get_cache_dir().path_join("crowfield-trace-test-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	var path := directory.path_join("gameplay.jsonl")
	cleanup(func() -> void:
		DirAccess.remove_absolute(path)
		DirAccess.remove_absolute(directory))
	var trace := PlaytestTrace.new()
	if not check_equal(trace.start_run(directory, 0), OK, "start trace"):
		return
	for i in PlaytestTrace.PENDING_LIMIT + 2:
		trace.event(i + 1, {"type": "gameplay_action"})
	trace.finish_run(PlaytestTrace.PENDING_LIMIT + 3)
	var lines := FileAccess.get_file_as_string(path).split("\n", false)
	check_equal(lines.size(), PlaytestTrace.PENDING_LIMIT + 3, "written records")
	check_equal(JSON.parse_string(lines[-2])["type"], "records_dropped", "overflow indication")
	check_equal(JSON.parse_string(lines[-1])["type"], "run_end", "clean shutdown record")
