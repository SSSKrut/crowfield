class_name TestCase
extends RefCounted
## TestCase is a group of tests: every method whose name starts with test_
## runs on a fresh instance. A failed check records its message and the test
## goes on; the runner reports every failure.

var failures: PackedStringArray = []
## expected_errors are texts of engine errors a test expects; the runner does
## not count errors that contain one of them as failures.
var expected_errors: PackedStringArray = []
var _cleanups: Array[Callable] = []


## expect_error lets the engine report an error that contains text without
## failing the test, for tests of failures the engine itself logs.
func expect_error(text: String) -> void:
	expected_errors.append(text)


## cleanup runs a function once the test ends, in reverse order.
func cleanup(function: Callable) -> void:
	_cleanups.append(function)


func run_cleanups() -> void:
	for i in range(_cleanups.size() - 1, -1, -1):
		_cleanups[i].call()
	_cleanups.clear()


func fail(message: String) -> void:
	failures.append(message)


func check(condition: bool, message: String) -> bool:
	if not condition:
		fail(message)
	return condition


func check_equal(got: Variant, want: Variant, what: String = "") -> bool:
	if typeof(got) == typeof(want) and got == want:
		return true
	fail("%s: got %s, want %s" % [what if what != "" else "value", str(got), str(want)])
	return false


func check_near(got: float, want: float, tolerance: float, what: String = "") -> bool:
	if absf(got - want) <= tolerance:
		return true
	fail("%s: got %.6f, want %.6f ± %s" % [what if what != "" else "value", got, want, str(tolerance)])
	return false
