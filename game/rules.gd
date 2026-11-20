class_name Rules
extends RefCounted
## Rules are the parameters both ends of a connection must share, because the
## client predicts with them: movement and weapons. The server sends their
## hash in Welcome, and a client with other rules refuses to play.

var movement := MovementTuning.new()
var weapons := WeaponSet.create_default()


static func create_default() -> Rules:
	return Rules.new()


## load reads the movement and the weapon files on top of the defaults; an
## empty path keeps the defaults of its part. It returns the rules, or the
## error as a String.
static func load_files(movement_path: String, weapons_path: String) -> Variant:
	var rules := Rules.new()
	if movement_path != "":
		var error := rules.movement.load_json(movement_path)
		if error != "":
			return error
	if weapons_path != "":
		var error := rules.weapons.load_json(weapons_path)
		if error != "":
			return error
	return rules


func validate() -> String:
	var error := movement.validate()
	if error != "":
		return error
	return weapons.validate()


func hash_value() -> int:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_s64(0, movement.hash_value())
	bytes.encode_s64(8, weapons.hash_value())
	return Game.fnv64(bytes)


## read_json_file returns the parsed JSON of a file, or the error as a String.
static func read_json_file(path: String) -> Variant:
	var text := FileAccess.get_file_as_string(path)
	if text == "" and FileAccess.get_open_error() != OK:
		return "cannot read: %s" % error_string(FileAccess.get_open_error())
	var json := JSON.new()
	if json.parse(text) != OK:
		return "line %d: %s" % [json.get_error_line(), json.get_error_message()]
	return json.data


## apply_json_file sets the fields of target that a JSON object in a file
## names; see apply_json.
static func apply_json_file(target: Object, fields: Array, path: String, integers: Array = []) -> String:
	var data: Variant = read_json_file(path)
	if data is String:
		return data
	if not data is Dictionary:
		return "want a JSON object"
	return apply_json(target, fields, data, integers)


## apply_json sets the fields of target that values names. An unknown field or
## a value of the wrong type is an error, so that a typo does not pass
## silently.
static func apply_json(target: Object, fields: Array, values: Dictionary, integers: Array = []) -> String:
	for key in values:
		if not key in fields:
			return "unknown field %s" % key
		var value: Variant = values[key]
		var current: Variant = target.get(key)
		if current is bool:
			if not value is bool:
				return "%s must be true or false" % key
		elif key in integers:
			if not (value is float or value is int) or float(value) != floorf(value):
				return "%s must be a whole number" % key
			value = int(value)
		elif value is float or value is int:
			value = float(value)
		else:
			return "%s must be a number" % key
		target.set(key, value)
	return ""
