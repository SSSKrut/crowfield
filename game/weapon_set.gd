class_name WeaponSet
extends RefCounted
## WeaponSet is the tuning of every weapon. Its data file names the weapons by
## key and may give only the values it changes.

const KEYS := ["assault_rifle", "rifle", "pistol"]

var assault_rifle: WeaponTuning
var rifle: WeaponTuning
var pistol: WeaponTuning
var _by_kind: Array[WeaponTuning] = []


## create_default is the arsenal of the specification (6.1): an automatic
## assault rifle for middle range, a precise rifle that hits hard and a pistol
## that comes out quickly.
static func create_default() -> WeaponSet:
	var set := WeaponSet.new()
	set.assault_rifle = WeaponTuning.create({
		"automatic": true, "rounds_per_minute": 600.0, "range": 300.0, "magazine": 30, "reserve": 120,
		"reload_time": 2.2, "equip_time": 0.6, "damage": 25.0, "head_multiplier": 2.0, "limb_multiplier": 0.75,
		"falloff_start": 30.0, "falloff_end": 80.0, "falloff_damage": 0.6, "hip_spread": 2.0, "aim_spread": 0.35,
		"move_spread": 2.0, "air_spread": 4.0, "bloom": 0.3, "max_bloom": 3.0, "bloom_recovery": 6.0,
		"kick_pitch": 0.9, "kick_yaw": 0.35, "kick_recovery": 5.0, "aim_zoom": 0.75,
	})
	set.rifle = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 200.0, "range": 500.0, "magazine": 10, "reserve": 40,
		"reload_time": 2.6, "equip_time": 0.8, "damage": 55.0, "head_multiplier": 2.0, "limb_multiplier": 0.75,
		"falloff_start": 100.0, "falloff_end": 300.0, "falloff_damage": 0.8, "hip_spread": 3.0, "aim_spread": 0.1,
		"move_spread": 3.0, "air_spread": 6.0, "bloom": 1.0, "max_bloom": 2.0, "bloom_recovery": 4.0,
		"kick_pitch": 3.0, "kick_yaw": 0.6, "kick_recovery": 6.0, "aim_zoom": 0.5,
	})
	set.pistol = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 400.0, "range": 150.0, "magazine": 12, "reserve": 48,
		"reload_time": 1.5, "equip_time": 0.35, "damage": 30.0, "head_multiplier": 2.0, "limb_multiplier": 0.75,
		"falloff_start": 15.0, "falloff_end": 40.0, "falloff_damage": 0.5, "hip_spread": 1.5, "aim_spread": 0.6,
		"move_spread": 1.5, "air_spread": 3.0, "bloom": 0.6, "max_bloom": 2.5, "bloom_recovery": 8.0,
		"kick_pitch": 1.5, "kick_yaw": 0.4, "kick_recovery": 8.0, "aim_zoom": 0.85,
	})
	set._index()
	return set


func _index() -> void:
	_by_kind = [null, assault_rifle, rifle, pistol]


## get_tuning returns the tuning of a kind, or null for none.
func get_tuning(kind: int) -> WeaponTuning:
	if kind <= WeaponTuning.Kind.NONE or kind >= WeaponTuning.KINDS:
		return null
	return _by_kind[kind]


func validate() -> String:
	for kind in range(1, WeaponTuning.KINDS):
		var error := get_tuning(kind).validate()
		if error != "":
			return "%s: %s" % [WeaponTuning.kind_name(kind), error]
	return ""


## hash_value covers every field of every weapon.
func hash_value() -> int:
	var bytes := PackedByteArray()
	for kind in range(1, WeaponTuning.KINDS):
		get_tuning(kind).append_hash_bytes(bytes)
	return Game.fnv64(bytes)


## load_json reads a JSON file on top of the weapons of the set. It returns an
## error or "".
func load_json(path: String) -> String:
	var data: Variant = Rules.read_json_file(path)
	if data is String:
		return "weapons %s: %s" % [path, data]
	if not data is Dictionary:
		return "weapons %s: want an object of weapons" % path
	for key in data:
		var index := KEYS.find(key)
		if index < 0:
			return "weapons %s: unknown weapon \"%s\"" % [path, key]
		if not data[key] is Dictionary:
			return "weapons %s: %s must be an object" % [path, key]
		var error := Rules.apply_json(get_tuning(index + 1), WeaponTuning.FIELDS, data[key], WeaponTuning.INTEGER_FIELDS)
		if error != "":
			return "weapons %s: %s: %s" % [path, key, error]
	var invalid := validate()
	if invalid != "":
		return "weapons %s: %s" % [path, invalid]
	return ""
