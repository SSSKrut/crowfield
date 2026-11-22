class_name WeaponTuning
extends RefCounted
## WeaponTuning describes a weapon. Angles are in degrees and times in
## seconds, as in the data file. The server and every client must use the
## same values: the client predicts its own weapon.

## A soldier carries the kinds below CARRIED; the tank cannon is fitted to a
## tank (Vehicle) and fired by its driver.
enum Kind { NONE, ASSAULT_RIFLE, RIFLE, PISTOL, SHOTGUN, ROCKET_LAUNCHER, GRENADE, MEDKIT, TANK_CANNON }
const KINDS := 9
const CARRIED := 8
const NAMES := ["none", "assault rifle", "rifle", "pistol", "shotgun", "rocket launcher", "grenade", "medkit", "tank cannon"]
const LABELS := ["", "Assault rifle", "Rifle", "Pistol", "Shotgun", "RPG", "Grenade", "Medkit", "Tank cannon"]
## What a weapon does when it fires: BULLETS the server traces at once,
## shotgun pellets too; a PROJECTILE that flies until it bursts, a rocket or a
## grenade; or HEAL the one who uses it.
enum Use { BULLETS, PROJECTILE, HEAL }
## A shot of a shotgun has at most MAX_PELLETS pellets.
const MAX_PELLETS := 16

## The protocol carries a magazine in 8 bits and the spare rounds in 10.
const MAX_MAGAZINE := 255
const MAX_RESERVE := 1023
## Timers of weapons count ticks in 8 bits: at most 4.25 s.
const MAX_WEAPON_TICKS := 255

const FIELDS := [
	"automatic", "rounds_per_minute", "damage", "head_multiplier", "limb_multiplier",
	"falloff_start", "falloff_end", "falloff_damage", "range", "magazine", "reserve",
	"reload_time", "equip_time", "hip_spread", "aim_spread", "move_spread", "air_spread",
	"bloom", "max_bloom", "bloom_recovery", "kick_pitch", "kick_yaw", "kick_recovery", "aim_zoom",
	"use", "pellets", "pellet_spread", "projectile_speed", "projectile_gravity", "bounce", "fuse",
	"blast_radius", "blast_inner", "heal",
]
const INTEGER_FIELDS := ["magazine", "reserve", "use", "pellets", "heal"]

## Automatic weapons fire while the trigger is held, the others once per pull.
var automatic := false
var rounds_per_minute := 600.0
## damage is what a hit in the torso takes at close range; hits in the head
## and the limbs take it times their multipliers. Beyond falloff_start metres
## it falls linearly to falloff_damage of itself at falloff_end. A pellet of a
## shotgun takes it by itself; a projectile takes it, whole, at the heart of
## its blast.
var damage := 25.0
var head_multiplier := 2.0
var limb_multiplier := 0.75
var falloff_start := 30.0
var falloff_end := 80.0
var falloff_damage := 0.6
## range is how far a shot reaches, in metres; a projectile without a fuse
## bursts in the air there.
var range := 300.0
## A soldier spawns with magazine rounds in the weapon and reserve spare.
var magazine := 30
var reserve := 120
var reload_time := 2.2
var equip_time := 0.6
## The spread is a cone around the aim: hip_spread, or aim_spread while
## aiming, plus move_spread at sprint speed and less when slower, air_spread
## off the ground, and the bloom of recent shots. A shot adds bloom, up to
## max_bloom; once the weapon could fire again, the bloom fades by
## bloom_recovery degrees a second, so it grows through a burst.
var hip_spread := 2.0
var aim_spread := 0.35
var move_spread := 2.0
var air_spread := 4.0
var bloom := 0.3
var max_bloom := 3.0
var bloom_recovery := 6.0
## A shot kicks the aim up by kick_pitch and sideways by up to kick_yaw; the
## kick fades at the rate kick_recovery per second.
var kick_pitch := 0.9
var kick_yaw := 0.35
var kick_recovery := 5.0
## aim_zoom narrows the field of view while aiming. Only the client uses it.
var aim_zoom := 0.75
var use: int = Use.BULLETS
## A shot of a shotgun is pellets pellets, scattered within pellet_spread
## degrees around the shot.
var pellets := 1
var pellet_spread := 0.0
## A projectile leaves at projectile_speed and falls at projectile_gravity, in
## metres per second and per second squared. One that bounces keeps bounce of
## its speed off what it strikes and bursts at its fuse, in seconds; one that
## does not bursts where it strikes. Its blast takes the whole damage within
## blast_inner metres, falling to nothing at blast_radius.
var projectile_speed := 0.0
var projectile_gravity := 0.0
var bounce := 0.0
var fuse := 0.0
var blast_radius := 0.0
var blast_inner := 0.0
## heal is the health a medkit gives back.
var heal := 0


static func create(values: Dictionary) -> WeaponTuning:
	var tuning := WeaponTuning.new()
	for key in values:
		tuning.set(key, values[key])
	return tuning


static func kind_name(kind: int) -> String:
	if kind >= 0 and kind < KINDS:
		return NAMES[kind]
	return "weapon %d" % kind


## fuse_ticks is the time of the fuse in ticks.
func fuse_ticks() -> int:
	return Game.seconds_to_ticks(fuse)


## blast_share is the share of the damage of a blast at a distance from its
## heart.
func blast_share(distance: float) -> float:
	if distance <= blast_inner:
		return 1.0
	if distance >= blast_radius:
		return 0.0
	return 1.0 - (distance - blast_inner) / (blast_radius - blast_inner)


## fire_interval is the number of ticks between two shots.
func fire_interval() -> int:
	return Game.seconds_to_ticks(60.0 / rounds_per_minute)


func reload_ticks() -> int:
	return Game.seconds_to_ticks(reload_time)


func equip_ticks() -> int:
	return Game.seconds_to_ticks(equip_time)


## damage_at is the damage of a torso hit from the given distance.
func damage_at(distance: float) -> float:
	if distance <= falloff_start:
		return damage
	if distance >= falloff_end:
		return damage * falloff_damage
	var share := (distance - falloff_start) / (falloff_end - falloff_start)
	return damage * (1.0 - share * (1.0 - falloff_damage))


## hit_damage is the damage of a hit in a zone from a distance, in whole
## points of health, at least one.
func hit_damage(zone: int, distance: float) -> int:
	var amount := damage_at(distance)
	match zone:
		Hitboxes.Zone.HEAD:
			amount *= head_multiplier
		Hitboxes.Zone.LIMB:
			amount *= limb_multiplier
	return maxi(1, roundi(amount))


func validate() -> String:
	if rounds_per_minute <= 0 or not _in_ticks(60.0 / rounds_per_minute):
		return "rounds per minute must be between %d and %d" % [60 * Game.TICK_RATE / MAX_WEAPON_TICKS + 1, 60 * Game.TICK_RATE]
	if damage <= 0 or head_multiplier <= 0 or limb_multiplier <= 0:
		return "damage and its multipliers must be positive"
	if falloff_start < 0 or falloff_end < falloff_start or falloff_damage < 0 or falloff_damage > 1:
		return "falloff must start before it ends and keep between 0 and 1 of the damage"
	if range <= 0:
		return "range must be positive"
	if magazine < 1 or magazine > MAX_MAGAZINE or reserve < 0 or reserve > MAX_RESERVE:
		return "magazine must hold 1 to %d rounds and the reserve 0 to %d" % [MAX_MAGAZINE, MAX_RESERVE]
	if not _in_ticks(reload_time) or not _in_ticks(equip_time):
		return "reload and equip times must be between one tick and %.2f s" % (float(MAX_WEAPON_TICKS) / Game.TICK_RATE)
	if hip_spread < 0 or aim_spread < 0 or move_spread < 0 or air_spread < 0 or bloom < 0 or max_bloom < 0 or bloom_recovery < 0:
		return "spread and bloom must not be negative"
	if kick_pitch < 0 or kick_yaw < 0 or kick_recovery < 0:
		return "kick must not be negative"
	if aim_zoom <= 0 or aim_zoom > 1:
		return "aim zoom must be in (0, 1]"
	if use < Use.BULLETS or use > Use.HEAL:
		return "use must be 0 for bullets, 1 for a projectile or 2 for healing"
	if pellets < 1 or pellets > MAX_PELLETS or pellet_spread < 0:
		return "a shot has 1 to %d pellets in a spread that is not negative" % MAX_PELLETS
	if use == Use.PROJECTILE:
		if projectile_speed <= 0 or projectile_gravity < 0 or bounce < 0 or bounce >= 1 or fuse < 0:
			return "a projectile needs a speed, and a gravity, bounce below 1 and fuse that are not negative"
		if bounce > 0 and not _in_seconds(fuse):
			return "a projectile that bounces needs a fuse of up to %.0f s" % MAX_FUSE
		if blast_radius <= 0 or blast_inner < 0 or blast_inner >= blast_radius:
			return "a blast needs a radius larger than its inner radius"
	if use == Use.HEAL and (heal < 1 or heal > Game.MAX_HEALTH):
		return "a medkit heals 1 to %d" % Game.MAX_HEALTH
	return ""


## A fuse burns at most MAX_FUSE seconds.
const MAX_FUSE := 10.0


func _in_seconds(seconds: float) -> bool:
	return seconds > 0 and seconds <= MAX_FUSE


func _in_ticks(seconds: float) -> bool:
	var count := Game.seconds_to_ticks(seconds)
	return seconds > 0 and count >= 1 and count <= MAX_WEAPON_TICKS


## append_hash_bytes adds every field to bytes, so that the hash of a weapon
## set covers each of them.
func append_hash_bytes(bytes: PackedByteArray) -> void:
	for field in FIELDS:
		var value: Variant = get(field)
		var at := bytes.size()
		if value is bool:
			bytes.append(1 if value else 0)
		elif value is int:
			bytes.resize(at + 4)
			bytes.encode_s32(at, value)
		else:
			bytes.resize(at + 4)
			bytes.encode_float(at, value)
