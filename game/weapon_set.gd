class_name WeaponSet
extends RefCounted
## WeaponSet is the tuning of every weapon. Its data file names the weapons by
## key and may give only the values it changes.

const KEYS := ["assault_rifle", "rifle", "pistol", "shotgun", "rocket_launcher", "grenade", "medkit", "tank_cannon"]

var assault_rifle: WeaponTuning
var rifle: WeaponTuning
var pistol: WeaponTuning
var shotgun: WeaponTuning
var rocket_launcher: WeaponTuning
var grenade: WeaponTuning
var medkit: WeaponTuning
var tank_cannon: WeaponTuning
var _by_kind: Array[WeaponTuning] = []


## create_default is the arsenal of the specification (6.1): an automatic
## assault rifle for middle range, a precise rifle that hits hard and a pistol
## that comes out quickly; and of its later stages (6.3): a shotgun that kills
## with one shot up close, a rocket launcher, grenades and a medkit; and the
## cannon of the tank (14.1), whose shell flies flat and fast and bursts.
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
	# Nine pellets of 14 kill with one shot within eight metres.
	set.shotgun = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 70.0, "range": 80.0, "magazine": 6, "reserve": 30,
		"reload_time": 2.8, "equip_time": 0.7, "damage": 14.0, "head_multiplier": 1.5, "limb_multiplier": 0.75,
		"falloff_start": 8.0, "falloff_end": 30.0, "falloff_damage": 0.25, "hip_spread": 1.0, "aim_spread": 0.6,
		"move_spread": 1.0, "air_spread": 2.0, "bloom": 0.5, "max_bloom": 1.0, "bloom_recovery": 4.0,
		"kick_pitch": 4.0, "kick_yaw": 1.0, "kick_recovery": 6.0, "aim_zoom": 0.85, "pellets": 9, "pellet_spread": 4.0,
	})
	set.rocket_launcher = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 60.0, "range": 250.0, "magazine": 1, "reserve": 4,
		"reload_time": 2.6, "equip_time": 0.9, "damage": 150.0, "head_multiplier": 1.0, "limb_multiplier": 1.0,
		"falloff_start": 0.0, "falloff_end": 0.0, "falloff_damage": 1.0, "hip_spread": 1.5, "aim_spread": 0.4,
		"move_spread": 2.0, "air_spread": 4.0, "bloom": 0.0, "max_bloom": 0.0, "bloom_recovery": 0.0,
		"kick_pitch": 2.5, "kick_yaw": 0.5, "kick_recovery": 4.0, "aim_zoom": 0.8,
		"use": WeaponTuning.Use.PROJECTILE, "projectile_speed": 55.0, "projectile_gravity": 2.0,
		"blast_radius": 6.0, "blast_inner": 1.2,
	})
	set.grenade = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 60.0, "range": 100.0, "magazine": 1, "reserve": 2,
		"reload_time": 0.6, "equip_time": 0.5, "damage": 130.0, "head_multiplier": 1.0, "limb_multiplier": 1.0,
		"falloff_start": 0.0, "falloff_end": 0.0, "falloff_damage": 1.0, "hip_spread": 1.0, "aim_spread": 1.0,
		"move_spread": 1.0, "air_spread": 1.0, "bloom": 0.0, "max_bloom": 0.0, "bloom_recovery": 0.0,
		"kick_pitch": 0.0, "kick_yaw": 0.0, "kick_recovery": 0.0, "aim_zoom": 1.0,
		"use": WeaponTuning.Use.PROJECTILE, "projectile_speed": 17.0, "projectile_gravity": 9.81, "bounce": 0.35,
		"fuse": 2.8, "blast_radius": 7.0, "blast_inner": 1.5,
	})
	set.medkit = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 40.0, "range": 1.0, "magazine": 2, "reserve": 0,
		"reload_time": 1.0, "equip_time": 0.5, "damage": 1.0, "head_multiplier": 1.0, "limb_multiplier": 1.0,
		"falloff_start": 0.0, "falloff_end": 0.0, "falloff_damage": 1.0, "hip_spread": 0.0, "aim_spread": 0.0,
		"move_spread": 0.0, "air_spread": 0.0, "bloom": 0.0, "max_bloom": 0.0, "bloom_recovery": 0.0,
		"kick_pitch": 0.0, "kick_yaw": 0.0, "kick_recovery": 0.0, "aim_zoom": 1.0,
		"use": WeaponTuning.Use.HEAL, "heal": 50,
	})
	# The reload is the tank's own (Vehicle.RELOAD_TIME); the magazine only
	# satisfies the checks every weapon passes.
	set.tank_cannon = WeaponTuning.create({
		"automatic": false, "rounds_per_minute": 17.0, "range": 400.0, "magazine": 1, "reserve": 0,
		"reload_time": 3.5, "equip_time": 0.1, "damage": 140.0, "head_multiplier": 1.0, "limb_multiplier": 1.0,
		"falloff_start": 0.0, "falloff_end": 0.0, "falloff_damage": 1.0, "hip_spread": 0.0, "aim_spread": 0.0,
		"move_spread": 0.0, "air_spread": 0.0, "bloom": 0.0, "max_bloom": 0.0, "bloom_recovery": 0.0,
		"kick_pitch": 0.0, "kick_yaw": 0.0, "kick_recovery": 0.0, "aim_zoom": 1.0,
		"use": WeaponTuning.Use.PROJECTILE, "projectile_speed": 160.0, "projectile_gravity": 4.0,
		"blast_radius": 7.0, "blast_inner": 1.6,
	})
	set._index()
	return set


func _index() -> void:
	_by_kind = [null, assault_rifle, rifle, pistol, shotgun, rocket_launcher, grenade, medkit, tank_cannon]


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
