extends RefCounted
## Keeps only recent gameplay diagnostics in memory until a capture.

const WINDOW_USEC := 5_000_000
const SAMPLE_INTERVAL_USEC := 100_000
const SAMPLE_LIMIT := 51
const EVENT_LIMIT := 128
const WRITE_INTERVAL_USEC := 500_000
const PENDING_LIMIT := 256

var _samples := Ring.new(SAMPLE_LIMIT)
var _events := Ring.new(EVENT_LIMIT)
var _next_sample_usec := 0
var _longest_frame_usec := 0
var _look_delta := Vector2.ZERO
var _file: FileAccess
var _next_write_usec := 0
var _pending: Array[Dictionary] = []
var _dropped := 0


func start_run(directory: String, now: int) -> Error:
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		return error
	var path := directory.path_join("gameplay.jsonl")
	if FileAccess.file_exists(path):
		_file = FileAccess.open(path, FileAccess.READ_WRITE)
		if _file != null and _file.get_length() > 0:
			_file.seek_end(-1)
			var last_byte := _file.get_8()
			if last_byte != 10:
				_file.store_8(10)
	else:
		_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		return FileAccess.get_open_error()
	_record(now, "run_start", {"wall_unix_ms": roundi(Time.get_unix_time_from_system() * 1000)})
	return _write(now)


func flush_if_due(now: int) -> void:
	if _file != null and now >= _next_write_usec:
		_write(now)


func finish_run(now: int) -> void:
	if _file != null:
		_pending.append({"type": "run_end", "monotonic_usec": now})
		_write(now)
		if _file != null:
			_file.close()
			_file = null


func _record(now: int, kind: String, data: Dictionary) -> void:
	if _file == null:
		return
	if _pending.size() == PENDING_LIMIT:
		_dropped += 1
		return
	var row := data.duplicate()
	row["type"] = kind
	row["monotonic_usec"] = now
	_pending.append(row)


func _write(now: int) -> Error:
	_next_write_usec = now + WRITE_INTERVAL_USEC
	if _dropped > 0:
		var index := _pending.size()
		if index > 0 and _pending.back()["type"] == "run_end":
			index -= 1
		_pending.insert(index, {"type": "records_dropped", "count": _dropped, "monotonic_usec": now})
		_dropped = 0
	if _pending.is_empty():
		return OK
	var lines := PackedStringArray()
	for record in _pending:
		lines.append(JSON.stringify(record))
	_file.store_string("\n".join(lines) + "\n")
	_file.flush()
	_pending.clear()
	var error := _file.get_error()
	if error != OK:
		push_warning("Gameplay trace write failed: " + error_string(error))
		_file.close()
		_file = null
	return error


## Accumulate frame timing and camera motion without allocating per frame.
func frame(now: int, frame_usec: int, look_delta: Vector2) -> bool:
	_longest_frame_usec = maxi(_longest_frame_usec, frame_usec)
	_look_delta += look_delta
	return now >= _next_sample_usec


func sample(now: int, state: Dictionary) -> void:
	state["longest_frame_ms"] = _longest_frame_usec / 1000.0
	state["look_delta_radians"] = [_look_delta.x, _look_delta.y]
	_samples.push(now, state)
	_record(now, "sample", state)
	_next_sample_usec = now + SAMPLE_INTERVAL_USEC
	_longest_frame_usec = 0
	_look_delta = Vector2.ZERO


func event(now: int, data: Dictionary) -> void:
	_events.push(now, data)
	_record(now, data["type"], data)


func snapshot(now: int) -> Dictionary:
	var samples := _samples.recent(now)
	var longest_frame_ms := _longest_frame_usec / 1000.0
	for state in samples:
		longest_frame_ms = maxf(longest_frame_ms, state["longest_frame_ms"])
	return {
		"window_ms": WINDOW_USEC / 1000,
		"sample_interval_ms": SAMPLE_INTERVAL_USEC / 1000,
		"longest_frame_ms": longest_frame_ms,
		"look_delta_since_sample_radians": [_look_delta.x, _look_delta.y],
		"samples": samples,
		"events": _events.recent(now),
	}


class Ring:
	var _entries: Array = []
	var _next := 0
	var _count := 0

	func _init(capacity: int) -> void:
		_entries.resize(capacity)

	func push(now: int, data: Dictionary) -> void:
		_entries[_next] = [now, data]
		_next = (_next + 1) % _entries.size()
		_count = mini(_count + 1, _entries.size())

	func recent(now: int) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for step in _count:
			var entry: Array = _entries[posmod(_next - _count + step, _entries.size())]
			var age: int = now - entry[0]
			if age > WINDOW_USEC:
				continue
			var state: Dictionary = entry[1].duplicate(true)
			state["age_ms"] = age / 1000.0
			result.append(state)
		return result
