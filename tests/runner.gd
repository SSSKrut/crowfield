class_name TestRunner
extends RefCounted
## TestRunner runs the test cases in res://tests: every file named test_*.gd
## whose script extends TestCase. A filter keeps the tests whose file or method
## name contains it. A script error during a test fails it too, as does a
## script that does not compile. run returns the number of failed tests.

const DIRECTORY := "res://tests"


static func run(filter: String = "") -> int:
	var errors := ErrorLog.new()
	OS.add_logger(errors)
	var failed := 0
	var passed := 0
	var started := Time.get_ticks_msec()
	for file in DirAccess.get_files_at(DIRECTORY):
		if not file.begins_with("test_") or not file.ends_with(".gd"):
			continue
		errors.messages.clear()
		var script: GDScript = load(DIRECTORY.path_join(file))
		if script == null or not script.can_instantiate():
			printerr("FAIL %s: does not compile" % file)
			for message in errors.messages:
				printerr("       ", message)
			failed += 1
			continue
		for method in script.get_script_method_list():
			var name: String = method["name"]
			if not name.begins_with("test_"):
				continue
			if filter != "" and not filter in file and not filter in name:
				continue
			errors.messages.clear()
			var case: TestCase = script.new()
			var clock := Time.get_ticks_msec()
			case.call(name)
			case.run_cleanups()
			var elapsed := Time.get_ticks_msec() - clock
			for message in errors.messages:
				var expected := false
				for text in case.expected_errors:
					if text in message:
						expected = true
				if not expected:
					case.fail("script error: " + message)
			if case.failures.is_empty():
				passed += 1
				print("ok   %s.%s (%d ms)" % [file.get_basename(), name, elapsed])
			else:
				failed += 1
				printerr("FAIL %s.%s (%d ms)" % [file.get_basename(), name, elapsed])
				for failure in case.failures:
					printerr("       ", failure)
	OS.remove_logger(errors)
	print("%d passed, %d failed in %.1f s" % [passed, failed, (Time.get_ticks_msec() - started) / 1000.0])
	return failed


## ErrorLog keeps the errors the engine and scripts report.
class ErrorLog:
	extends Logger
	var messages: PackedStringArray = []
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		_mutex.lock()
		messages.append("%s (%s:%d %s)" % [rationale if rationale != "" else code, file, line, function])
		_mutex.unlock()
