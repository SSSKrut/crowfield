class_name Arsenal
extends RefCounted
## Arsenal is the weapons a soldier carries and their state. Only the server
## and the soldier's own player know it; the other players see the weapon in
## its hands. Spread and kick are in radians.

## MAX_LOADOUT is how many weapons a soldier carries.
const MAX_LOADOUT := 3

enum Action { READY, EQUIPPING, RELOADING }

## What a weapon did in a tick, for the hit test of the server and the
## effects of the player's own client.
const EVENT_FIRED := 1
## EVENT_DRY_FIRE is a pull of the trigger with no rounds left at all.
const EVENT_DRY_FIRE := 2
const EVENT_RELOAD_STARTED := 4
const EVENT_RELOADED := 8
const EVENT_EQUIP_STARTED := 16

## MAX_KICK bounds how far the kick of a long burst turns the aim.
const MAX_KICK := 12.0 * PI / 180.0
## A kicked aim stops short of straight up or down.
const MAX_SHOT_PITCH := PI / 2.0 - 0.01
## Kick below this much is gone, so that a calm weapon is exactly calm.
const KICK_REST := 1e-6

const _GOLDEN := -7046029254386353131
const _MIX1 := -4658895280553007687
const _MIX2 := -7723592293110705685

## weapons holds the kind in every slot, magazine and reserve their rounds.
var weapons := PackedInt32Array([0, 0, 0])
var magazine := PackedInt32Array([0, 0, 0])
var reserve := PackedInt32Array([0, 0, 0])
var current := 0
var action: int = Action.READY
## action_ticks is how many ticks the action has left, cooldown how many
## until the weapon fires again.
var action_ticks := 0
var cooldown := 0
## trigger is set from a shot until the trigger is released: a weapon that is
## not automatic fires once per pull.
var trigger := false
var bloom := 0.0
## The kick turns the aim of the next shots, and the view with it.
var kick_pitch := 0.0
var kick_yaw := 0.0


## DEFAULT_LOADOUT carries all three weapons until classes choose (stage 3).
static func default_loadout() -> PackedInt32Array:
	return PackedInt32Array([WeaponTuning.Kind.ASSAULT_RIFLE, WeaponTuning.Kind.RIFLE, WeaponTuning.Kind.PISTOL])


## create arms a soldier with full magazines, the first weapon in hand.
static func create(loadout: PackedInt32Array, set: WeaponSet) -> Arsenal:
	var arsenal := Arsenal.new()
	for i in MAX_LOADOUT:
		arsenal.weapons[i] = loadout[i]
		var tuning := set.get_tuning(loadout[i])
		if tuning != null:
			arsenal.magazine[i] = tuning.magazine
			arsenal.reserve[i] = tuning.reserve
	return arsenal


## holding is what a client knows of another soldier's arsenal: the weapon
## in its hands.
static func holding(kind: int) -> Arsenal:
	var arsenal := Arsenal.new()
	arsenal.weapons[0] = kind
	return arsenal


func copy() -> Arsenal:
	var other := Arsenal.new()
	other.weapons = weapons.duplicate()
	other.magazine = magazine.duplicate()
	other.reserve = reserve.duplicate()
	other.current = current
	other.action = action
	other.action_ticks = action_ticks
	other.cooldown = cooldown
	other.trigger = trigger
	other.bloom = bloom
	other.kick_pitch = kick_pitch
	other.kick_yaw = kick_yaw
	return other


## weapon is the weapon in the soldier's hands.
func weapon() -> int:
	if current < 0 or current >= MAX_LOADOUT:
		return WeaponTuning.Kind.NONE
	return weapons[current]


func is_empty() -> bool:
	return weapons == PackedInt32Array([0, 0, 0]) and magazine == PackedInt32Array([0, 0, 0]) \
		and reserve == PackedInt32Array([0, 0, 0]) and current == 0 and action == Action.READY \
		and action_ticks == 0 and cooldown == 0 and not trigger and bloom == 0.0 and kick_pitch == 0.0 and kick_yaw == 0.0


## agrees reports whether two states are the same, the fading spread and kick
## to within rounding: they travel as 32-bit numbers.
func agrees(other: Arsenal) -> bool:
	const LIMIT := 1e-5
	return weapons == other.weapons and magazine == other.magazine and reserve == other.reserve \
		and current == other.current and action == other.action and action_ticks == other.action_ticks \
		and cooldown == other.cooldown and trigger == other.trigger and absf(bloom - other.bloom) <= LIMIT \
		and absf(kick_pitch - other.kick_pitch) <= LIMIT and absf(kick_yaw - other.kick_yaw) <= LIMIT


## step works the weapons for a tick of the command, after the soldier moved.
## The order is: the timers run, a change of weapon starts, an action ends, a
## reload starts, then the weapon fires if it may. speed is the soldier's
## share of the sprint speed; seed makes the spread repeatable (shot_seed).
func step(set: WeaponSet, command: InputCommand, speed: float, airborne: bool, seed: int) -> WeaponStep:
	var result := WeaponStep.new()
	var tuning := set.get_tuning(weapon())
	_recover(tuning)
	if cooldown > 0:
		cooldown -= 1
	var slot := command.weapon
	if slot < MAX_LOADOUT and slot != current and weapons[slot] != WeaponTuning.Kind.NONE:
		current = slot
		tuning = set.get_tuning(weapons[slot])
		action = Action.EQUIPPING
		action_ticks = tuning.equip_ticks()
		bloom = 0.0
		result.events |= EVENT_EQUIP_STARTED
	elif action != Action.READY:
		action_ticks -= 1
		if action_ticks == 0:
			if action == Action.RELOADING:
				_refill(tuning)
				result.events |= EVENT_RELOADED
			action = Action.READY
	if tuning == null:
		return result
	var fire := command.has(InputCommand.FIRE)
	if not fire:
		trigger = false
	if action == Action.READY and command.has(InputCommand.RELOAD) and magazine[current] < tuning.magazine and reserve[current] > 0:
		_start_reload(tuning)
		result.events |= EVENT_RELOAD_STARTED
	if action != Action.READY or not fire or cooldown > 0 or (trigger and not tuning.automatic):
		return result
	if magazine[current] == 0:
		if reserve[current] > 0:
			_start_reload(tuning)
			result.events |= EVENT_RELOAD_STARTED
		elif not trigger:
			result.events |= EVENT_DRY_FIRE
		trigger = true
		return result
	magazine[current] -= 1
	cooldown = tuning.fire_interval()
	trigger = true
	result.events |= EVENT_FIRED
	result.shot = _shoot(tuning, command, speed, airborne, seed)
	return result


func _start_reload(tuning: WeaponTuning) -> void:
	action = Action.RELOADING
	action_ticks = tuning.reload_ticks()


func _refill(tuning: WeaponTuning) -> void:
	var moved := mini(tuning.magazine - magazine[current], reserve[current])
	magazine[current] += moved
	reserve[current] -= moved


## _recover fades the kick of the weapon in hand for a tick, and its bloom
## unless it is still cooling down from a shot.
func _recover(tuning: WeaponTuning) -> void:
	if tuning == null:
		bloom = 0.0
		kick_pitch = 0.0
		kick_yaw = 0.0
		return
	if cooldown == 0:
		bloom = maxf(0.0, bloom - deg_to_rad(tuning.bloom_recovery) / Game.TICK_RATE)
	var fade := exp(-tuning.kick_recovery / Game.TICK_RATE)
	kick_pitch = _rest(kick_pitch * fade)
	kick_yaw = _rest(kick_yaw * fade)


static func _rest(kick: float) -> float:
	if absf(kick) < KICK_REST:
		return 0.0
	return kick


## spread is the angle, in radians, within which the next shot of the weapon
## in hand scatters.
func spread(set: WeaponSet, aiming: bool, speed: float, airborne: bool) -> float:
	var tuning := set.get_tuning(weapon())
	if tuning == null:
		return 0.0
	return _spread(tuning, aiming, speed, airborne)


func _spread(tuning: WeaponTuning, aiming: bool, speed: float, airborne: bool) -> float:
	var degrees := tuning.aim_spread if aiming else tuning.hip_spread
	degrees += tuning.move_spread * clampf(speed, 0.0, 1.0)
	if airborne:
		degrees += tuning.air_spread
	return deg_to_rad(degrees) + bloom


## _shoot aims a shot along the view turned by the kick, scatters it within the
## spread, and kicks and blooms the weapon for the next one.
func _shoot(tuning: WeaponTuning, command: InputCommand, speed: float, airborne: bool, seed: int) -> Shot:
	var angle := _spread(tuning, command.has(InputCommand.AIM), speed, airborne)
	var yaw := command.yaw_radians() + kick_yaw
	var pitch := clampf(command.pitch_radians() + kick_pitch, -MAX_SHOT_PITCH, MAX_SHOT_PITCH)
	var random := [seed]
	var direction := scatter(yaw, pitch, angle * sqrt(_next(random)), TAU * _next(random))
	bloom = minf(deg_to_rad(tuning.max_bloom), bloom + deg_to_rad(tuning.bloom))
	kick_pitch = minf(MAX_KICK, kick_pitch + deg_to_rad(tuning.kick_pitch))
	kick_yaw = clampf(kick_yaw + deg_to_rad(tuning.kick_yaw) * (2.0 * _next(random) - 1.0), -MAX_KICK, MAX_KICK)
	var shot := Shot.new()
	shot.weapon = weapon()
	shot.direction = direction
	return shot


## scatter turns the view direction by angle, towards the side given by turn:
## zero to the right, a quarter turn up.
static func scatter(yaw: float, pitch: float, angle: float, turn: float) -> Vector3:
	var forward := Game.view_direction(yaw, pitch)
	if angle == 0.0:
		return forward
	var sin_yaw := sin(yaw)
	var cos_yaw := cos(yaw)
	var sin_pitch := sin(pitch)
	var cos_pitch := cos(pitch)
	var right := Vector3(cos_yaw, 0.0, sin_yaw)
	var up := Vector3(-sin_yaw * sin_pitch, cos_pitch, cos_yaw * sin_pitch)
	var offset := tan(angle)
	return (forward + right * (offset * cos(turn)) + up * (offset * sin(turn))).normalized()


## shot_seed makes the spread of a shot repeatable: the client predicts its
## own shots with the spread the server uses.
static func shot_seed(match_seed: int, soldier: int, tick: int) -> int:
	return mix64(match_seed ^ (soldier << 32) ^ tick)


## _next draws a number in [0, 1) from the state in random[0], by SplitMix64.
static func _next(random: Array) -> float:
	random[0] += _GOLDEN
	return float(Game.logical_shift(mix64(random[0]), 40)) / float(1 << 24)


static func mix64(value: int) -> int:
	var x := value
	x ^= Game.logical_shift(x, 30)
	x *= _MIX1
	x ^= Game.logical_shift(x, 27)
	x *= _MIX2
	return x ^ Game.logical_shift(x, 31)
