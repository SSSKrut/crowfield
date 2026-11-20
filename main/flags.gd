class_name Flags
extends RefCounted
## Flags reads command line options in the style of Go's flag package:
## -name=value, -name value, --name=value, and -name alone for a boolean.
## Durations take Go's units: 500ms, 5s, 10m, 1h.

var _values := {}
var _defaults := {}
var _help := {}
var _order: PackedStringArray = []
var positional: PackedStringArray = []


func define(name: String, default: Variant, help: String) -> void:
	_defaults[name] = default
	_values[name] = default
	_help[name] = help
	_order.append(name)


## parse reads arguments and returns an error, or "".
func parse(arguments: PackedStringArray) -> String:
	var i := 0
	while i < arguments.size():
		var argument := arguments[i]
		i += 1
		if not argument.begins_with("-") or argument == "-":
			positional.append(argument)
			continue
		var name := argument.trim_prefix("-").trim_prefix("-")
		var value := ""
		var has_value := false
		var equals := name.find("=")
		if equals >= 0:
			value = name.substr(equals + 1)
			name = name.substr(0, equals)
			has_value = true
		if name == "help" or name == "h":
			return "help"
		if not _defaults.has(name):
			return "unknown flag -%s" % name
		var default: Variant = _defaults[name]
		if default is bool:
			if not has_value:
				_values[name] = true
				continue
			if value not in ["true", "false", "1", "0"]:
				return "flag -%s takes true or false, not %s" % [name, value]
			_values[name] = value in ["true", "1"]
			continue
		if not has_value:
			if i >= arguments.size():
				return "flag -%s needs a value" % name
			value = arguments[i]
			i += 1
		var parsed: Variant = _convert(default, value)
		if parsed == null:
			return "flag -%s: bad value %s" % [name, value]
		_values[name] = parsed
	return ""


func _convert(default: Variant, value: String) -> Variant:
	if default is int:
		return value.to_int() if value.is_valid_int() else null
	if default is float:
		return value.to_float() if value.is_valid_float() else null
	if default is Duration:
		var seconds: Variant = Duration.parse(value)
		return null if seconds == null else Duration.new(seconds)
	return value


func get_value(name: String) -> Variant:
	var value: Variant = _values[name]
	if value is Duration:
		return value.seconds
	return value


## usage lists the flags with their defaults.
func usage() -> String:
	var lines: PackedStringArray = []
	for name in _order:
		var default: Variant = _defaults[name]
		var shown := str(default.seconds) + "s" if default is Duration else str(default)
		lines.append("  -%s (default %s)\n        %s" % [name, shown, _help[name]])
	return "\n".join(lines)


## Duration marks a flag that takes a duration; its value reads in seconds.
class Duration:
	var seconds: float

	func _init(value: float) -> void:
		seconds = value

	## parse reads a Go duration such as 1m30s or 250ms, or returns null.
	static func parse(text: String) -> Variant:
		if text == "0":
			return 0.0
		var units := {"h": 3600.0, "m": 60.0, "s": 1.0, "ms": 0.001, "us": 0.000001}
		var total := 0.0
		var number := ""
		var i := 0
		if text == "":
			return null
		while i < text.length():
			var c := text[i]
			if c.is_valid_int() or c == ".":
				number += c
				i += 1
				continue
			var unit := c
			if i + 1 < text.length() and not text[i + 1].is_valid_int() and text[i + 1] != ".":
				unit += text[i + 1]
			if not units.has(unit):
				unit = c
			if not units.has(unit) or number == "" or not number.is_valid_float():
				return null
			total += number.to_float() * units[unit]
			number = ""
			i += unit.length()
		if number != "":
			return null
		return total
