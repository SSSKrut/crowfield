class_name PlayerState
extends RefCounted
## PlayerState is the private part of a snapshot for the player who receives
## it. Position, velocity and the arsenal keep full precision for
## reconciliation and are only sent while the player has a soldier, with its
## health.

## NO_INPUT is the input_lead of a player whose commands have not arrived yet.
const NO_INPUT := -128
const HEALTH_BITS := 7
const RESPAWN_BITS := 16

const _MAGAZINE_BITS := 8
const _RESERVE_BITS := 10
const _CURRENT_BITS := 2
const _ACTION_BITS := 2
const _ACTION_TICKS_BITS := 8
const _COOLDOWN_BITS := 8

var processed := false
var last_processed_tick := 0
## input_lead is how many ticks the newest command the server had from the
## player was ahead of the tick when it ran; negative when commands come late,
## NO_INPUT before the first. The client speeds its ticks up or slows them
## down to keep it at 2.
var input_lead := NO_INPUT
var soldier := 0
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var crouched := false
## health is zero while the soldier is dead; respawn is then how many ticks
## are left until the player comes back, at least one.
var health := 0
var respawn := 0
var arsenal := Arsenal.new()


func validate() -> String:
	if soldier != 0 and SoldierSet.generation_of(soldier) == 0:
		return "player soldier 0x%04x has no generation" % soldier
	if not position.is_finite() or not velocity.is_finite():
		return BitReader.INVALID_FLOAT
	if soldier == 0:
		if not arsenal.is_empty() or health != 0 or respawn != 0 or crouched:
			return "player state without a soldier"
		return ""
	var error := _validate_health(health, respawn)
	if error != "":
		return error
	return _validate_arsenal(arsenal)


## _validate_health accepts health up to the maximum and a time to respawn only,
## and always, for the dead.
static func _validate_health(points: int, ticks: int) -> String:
	if points < 0 or points > Game.MAX_HEALTH:
		return "health %d is over %d" % [points, Game.MAX_HEALTH]
	if (points == 0) != (ticks != 0) or ticks < 0 or ticks >= 1 << RESPAWN_BITS:
		return "only the dead wait to respawn"
	return ""


## _validate_arsenal accepts what the encoding carries, and only in its one
## form: an empty slot has no ammo, and only a busy weapon has time left.
static func _validate_arsenal(a: Arsenal) -> String:
	for i in Arsenal.MAX_LOADOUT:
		var kind := a.weapons[i]
		if kind < 0 or kind >= WeaponTuning.KINDS:
			return "unknown weapon %d" % kind
		if kind == WeaponTuning.Kind.NONE and (a.magazine[i] != 0 or a.reserve[i] != 0):
			return "an empty weapon slot has ammo"
		if a.magazine[i] < 0 or a.magazine[i] >= 1 << _MAGAZINE_BITS or a.reserve[i] < 0 or a.reserve[i] >= 1 << _RESERVE_BITS:
			return "%d rounds do not fit" % a.reserve[i]
	if a.current < 0 or a.current >= Arsenal.MAX_LOADOUT:
		return "weapon slot %d is out of range" % a.current
	if a.action < 0 or a.action > Arsenal.Action.RELOADING:
		return "unknown weapon action %d" % a.action
	if (a.action == Arsenal.Action.READY) != (a.action_ticks == 0) or a.action_ticks < 0 or a.action_ticks >= 1 << _ACTION_TICKS_BITS:
		return "only a busy weapon has time left"
	if a.cooldown < 0 or a.cooldown >= 1 << _COOLDOWN_BITS:
		return "cooldown %d is out of range" % a.cooldown
	for value in [a.bloom, a.kick_pitch, a.kick_yaw]:
		if is_nan(value) or is_inf(value):
			return BitReader.INVALID_FLOAT
	return ""


func bits() -> int:
	var count := 1 + 8 + 16
	if processed:
		count += 32
	if soldier != 0:
		count += 6 * 32 + 1 + HEALTH_BITS + _arsenal_bits()
		if health == 0:
			count += RESPAWN_BITS
	return count


## _arsenal_bits is the size of the player's own weapons: every slot's weapon,
## and the ammo of the occupied ones; the action, with its time left unless
## the weapon is ready; the cooldown, the trigger, and the bloom and kick at
## full precision, which the prediction continues from.
func _arsenal_bits() -> int:
	var count := Arsenal.MAX_LOADOUT * Protocol.WEAPON_BITS + _CURRENT_BITS + _ACTION_BITS + _COOLDOWN_BITS + 1 + 3 * 32
	for kind in arsenal.weapons:
		if kind != WeaponTuning.Kind.NONE:
			count += _MAGAZINE_BITS + _RESERVE_BITS
	if arsenal.action != Arsenal.Action.READY:
		count += _ACTION_TICKS_BITS
	return count


func write(w: BitWriter) -> void:
	w.write_bool(processed)
	if processed:
		w.write_bits(last_processed_tick, 32)
	w.write_signed(input_lead, 8)
	w.write_bits(soldier, 16)
	if soldier == 0:
		return
	for value in [position.x, position.y, position.z, velocity.x, velocity.y, velocity.z]:
		w.write_float32(value)
	w.write_bool(crouched)
	w.write_bits(health, HEALTH_BITS)
	if health == 0:
		w.write_bits(respawn, RESPAWN_BITS)
	var a := arsenal
	for i in Arsenal.MAX_LOADOUT:
		w.write_bits(a.weapons[i], Protocol.WEAPON_BITS)
		if a.weapons[i] != WeaponTuning.Kind.NONE:
			w.write_bits(a.magazine[i], _MAGAZINE_BITS)
			w.write_bits(a.reserve[i], _RESERVE_BITS)
	w.write_bits(a.current, _CURRENT_BITS)
	w.write_bits(a.action, _ACTION_BITS)
	if a.action != Arsenal.Action.READY:
		w.write_bits(a.action_ticks, _ACTION_TICKS_BITS)
	w.write_bits(a.cooldown, _COOLDOWN_BITS)
	w.write_bool(a.trigger)
	w.write_float32(a.bloom)
	w.write_float32(a.kick_pitch)
	w.write_float32(a.kick_yaw)


func read(r: BitReader) -> void:
	processed = r.read_bool()
	last_processed_tick = 0
	if processed:
		last_processed_tick = r.read_bits(32)
	input_lead = r.read_signed(8)
	soldier = r.read_bits(16)
	position = Vector3.ZERO
	velocity = Vector3.ZERO
	crouched = false
	health = 0
	respawn = 0
	arsenal = Arsenal.new()
	if soldier == 0:
		return
	if SoldierSet.generation_of(soldier) == 0:
		r.fail("player soldier 0x%04x has no generation" % soldier)
	var px := r.read_float32()
	var py := r.read_float32()
	position = Vector3(px, py, r.read_float32())
	var vx := r.read_float32()
	var vy := r.read_float32()
	velocity = Vector3(vx, vy, r.read_float32())
	crouched = r.read_bool()
	health = r.read_bits(HEALTH_BITS)
	if health == 0:
		respawn = r.read_bits(RESPAWN_BITS)
	if r.error == "":
		var error := _validate_health(health, respawn)
		if error != "":
			r.fail(error)
	var a := arsenal
	for i in Arsenal.MAX_LOADOUT:
		a.weapons[i] = r.read_bits(Protocol.WEAPON_BITS)
		if a.weapons[i] != WeaponTuning.Kind.NONE:
			a.magazine[i] = r.read_bits(_MAGAZINE_BITS)
			a.reserve[i] = r.read_bits(_RESERVE_BITS)
	a.current = r.read_bits(_CURRENT_BITS)
	a.action = r.read_bits(_ACTION_BITS)
	if a.action != Arsenal.Action.READY:
		a.action_ticks = r.read_bits(_ACTION_TICKS_BITS)
	a.cooldown = r.read_bits(_COOLDOWN_BITS)
	a.trigger = r.read_bool()
	a.bloom = r.read_float32()
	a.kick_pitch = r.read_float32()
	a.kick_yaw = r.read_float32()
	if r.error == "":
		var error := _validate_arsenal(a)
		if error != "":
			r.fail(error)
