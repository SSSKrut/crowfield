class_name SoldierState
extends RefCounted
## SoldierState is a soldier as every client sees it, already quantized, so it
## encodes without loss. Health and ammo of other soldiers are not sent.

## POSITION_UNITS_PER_METRE gives 2 mm steps: X and Z cover ±2048 m, Y ±512 m.
const POSITION_UNITS_PER_METRE := 512.0
## VELOCITY_UNITS_PER_METRE gives 1/32 m/s steps up to ±64 m/s.
const VELOCITY_UNITS_PER_METRE := 32.0

const SHOTS_BITS := 4
const HIT_COUNT_BITS := 3
const HIT_BOX_BITS := 3
const HIT_YAW_BITS := 6
const HIT_BITS := HIT_COUNT_BITS + HIT_BOX_BITS + HIT_YAW_BITS
const FLAGS_BITS := 8
const HORIZONTAL_BITS := 21
const VERTICAL_BITS := 19
const POSITION_BITS := 2 * HORIZONTAL_BITS + VERTICAL_BITS
const VELOCITY_BITS := 12
const YAW_BITS := 12
const PITCH_BITS := 10

## Bots are drawn but never predicted, so they get by with coarser velocity
## and angles: steps of 1/8 m/s, 256 yaw steps and 64 pitch steps, and no
## vertical velocity. Their values keep the units of the full fields.
const BOT_VELOCITY_BITS := 8
const BOT_VELOCITY_STEP := 4
const BOT_YAW_BITS := 8
const BOT_PITCH_BITS := 6
const BOT_ANGLE_STEP := 1 << (YAW_BITS - BOT_YAW_BITS)

const ALIVE := 1
const GROUNDED := 2

var id := 0
var bot := false
var team := 0
var flags := 0
## position is in 1/512 m; X and Z fit 21 bits, Y 19 bits.
var position := Vector3i.ZERO
## velocity is in 1/32 m/s, 12 bits each; a bot's in steps of 4, without Y.
var velocity := Vector3i.ZERO
## yaw is 12 bits of a full turn, pitch 10 bits over [-PI/2, PI/2]; a bot's in
## steps of 16.
var yaw := 0
var pitch := 0
## weapon is the kind in its hands, in 4 bits.
var weapon := 0
## shots counts the rounds fired, in 4 bits; clients play the shots between
## two states from the difference.
var shots := 0
## The last hit taken: a counter in 3 bits, the hitbox in 3 and the yaw the
## shot travelled along in 6.
var hit_count := 0
var hit_box := 0
var hit_yaw := 0


## create quantizes a soldier. It returns null when the soldier is outside the
## range the protocol can represent, which means it left the map.
static func create(soldier: Soldier) -> SoldierState:
	var position := soldier.position
	var moving := soldier.velocity
	if not position.is_finite() or not moving.is_finite():
		return null
	var state := SoldierState.new()
	state.id = soldier.id
	state.team = soldier.team
	state.bot = soldier.controller == Game.Controller.BOT
	var arsenal := soldier.arsenal
	state.weapon = arsenal.weapons[arsenal.current] if arsenal.current >= 0 and arsenal.current < Arsenal.MAX_LOADOUT else 0
	state.shots = soldier.shots & ((1 << SHOTS_BITS) - 1)
	state.hit_count = soldier.hit_count & ((1 << HIT_COUNT_BITS) - 1)
	state.hit_box = soldier.hit_box & ((1 << HIT_BOX_BITS) - 1)
	state.hit_yaw = quantize_turn(soldier.hit_yaw, HIT_YAW_BITS) >> (YAW_BITS - HIT_YAW_BITS)
	state.flags = (ALIVE if soldier.alive else 0) | (GROUNDED if soldier.grounded else 0)
	var x := roundi(clampf(position.x * POSITION_UNITS_PER_METRE, -2147483648.0, 2147483647.0))
	var y := roundi(clampf(position.y * POSITION_UNITS_PER_METRE, -2147483648.0, 2147483647.0))
	var z := roundi(clampf(position.z * POSITION_UNITS_PER_METRE, -2147483648.0, 2147483647.0))
	# Every other field is in range by construction; a position out of range
	# means the soldier left the map.
	if x < -(1 << 20) or x >= 1 << 20 or y < -(1 << 18) or y >= 1 << 18 or z < -(1 << 20) or z >= 1 << 20 \
			or SoldierSet.generation_of(state.id) == 0:
		return null
	state.position = Vector3i(x, y, z)
	if state.bot:
		const LIMIT := (1 << (BOT_VELOCITY_BITS - 1)) - 1
		const SCALE := VELOCITY_UNITS_PER_METRE / BOT_VELOCITY_STEP
		state.velocity = Vector3i(int(clampf(roundf(moving.x * SCALE), -LIMIT, LIMIT)) * BOT_VELOCITY_STEP, 0,
			int(clampf(roundf(moving.z * SCALE), -LIMIT, LIMIT)) * BOT_VELOCITY_STEP)
		state.yaw = quantize_turn(soldier.yaw, BOT_YAW_BITS)
		state.pitch = quantize_pitch(soldier.pitch, BOT_PITCH_BITS)
	else:
		const LIMIT := (1 << (VELOCITY_BITS - 1)) - 1
		state.velocity = Vector3i(int(clampf(roundf(moving.x * VELOCITY_UNITS_PER_METRE), -LIMIT, LIMIT)),
			int(clampf(roundf(moving.y * VELOCITY_UNITS_PER_METRE), -LIMIT, LIMIT)),
			int(clampf(roundf(moving.z * VELOCITY_UNITS_PER_METRE), -LIMIT, LIMIT)))
		state.yaw = quantize_turn(soldier.yaw, YAW_BITS)
		state.pitch = quantize_pitch(soldier.pitch, PITCH_BITS)
	return state


static func _round_clamped(value: float) -> int:
	return roundi(clampf(value, -2147483648.0, 2147483647.0))


func copy() -> SoldierState:
	var other := SoldierState.new()
	other.id = id
	other.bot = bot
	other.team = team
	other.flags = flags
	other.position = position
	other.velocity = velocity
	other.yaw = yaw
	other.pitch = pitch
	other.weapon = weapon
	other.shots = shots
	other.hit_count = hit_count
	other.hit_box = hit_box
	other.hit_yaw = hit_yaw
	return other


func equals(other: SoldierState) -> bool:
	return id == other.id and bot == other.bot and team == other.team and flags == other.flags \
		and position == other.position and velocity == other.velocity and yaw == other.yaw \
		and pitch == other.pitch and weapon == other.weapon and shots == other.shots \
		and hit_count == other.hit_count and hit_box == other.hit_box and hit_yaw == other.hit_yaw


func alive() -> bool:
	return flags & ALIVE != 0


## apply writes the received state into a client-side soldier. The client only
## learns whether a soldier is a bot, not which player or bot drives it, and of
## its arsenal only the weapon in its hands.
func apply(soldier: Soldier) -> void:
	soldier.id = id
	soldier.team = team
	soldier.alive = flags & ALIVE != 0
	soldier.grounded = flags & GROUNDED != 0
	soldier.controller = Game.Controller.BOT if bot else Game.Controller.PLAYER
	soldier.position = Vector3(position) / POSITION_UNITS_PER_METRE
	soldier.velocity = Vector3(velocity) / VELOCITY_UNITS_PER_METRE
	soldier.yaw = yaw * (TAU / (1 << YAW_BITS))
	var pitch_limit := (1 << (PITCH_BITS - 1)) - 1
	soldier.pitch = maxi(-pitch_limit, pitch) * (PI / 2.0 / pitch_limit)
	if soldier.arsenal == null or soldier.arsenal.weapon() != weapon:
		soldier.arsenal = Arsenal.holding(weapon)
	soldier.shots = shots
	soldier.hit_count = hit_count
	soldier.hit_box = hit_box
	soldier.hit_yaw = hit_yaw * (TAU / (1 << HIT_YAW_BITS))


func validate() -> String:
	if SoldierSet.generation_of(id) == 0 or id >= 1 << 16:
		return "soldier 0x%04x has no generation" % id
	if team < 0 or team > Game.Team.RED:
		return "soldier 0x%04x has unknown team %d" % [id, team]
	if not Protocol.fits_signed(position.x, HORIZONTAL_BITS) or not Protocol.fits_signed(position.y, VERTICAL_BITS) \
			or not Protocol.fits_signed(position.z, HORIZONTAL_BITS):
		return "soldier 0x%04x is outside the map range" % id
	if yaw < 0 or yaw >= 1 << YAW_BITS or weapon < 0 or weapon >= 1 << Protocol.WEAPON_BITS:
		return "soldier 0x%04x yaw or weapon is out of range" % id
	if shots < 0 or shots >= 1 << SHOTS_BITS or hit_count < 0 or hit_count >= 1 << HIT_COUNT_BITS \
			or hit_box < 0 or hit_box >= 1 << HIT_BOX_BITS or hit_yaw < 0 or hit_yaw >= 1 << HIT_YAW_BITS:
		return "soldier 0x%04x shots or last hit is out of range" % id
	if flags < 0 or flags >= 1 << FLAGS_BITS:
		return "soldier 0x%04x flags are out of range" % id
	if bot:
		if velocity.y != 0 or not _on_grid(velocity.x, BOT_VELOCITY_STEP, BOT_VELOCITY_BITS) \
				or not _on_grid(velocity.z, BOT_VELOCITY_STEP, BOT_VELOCITY_BITS) \
				or yaw % BOT_ANGLE_STEP != 0 or not _on_grid(pitch, BOT_ANGLE_STEP, BOT_PITCH_BITS):
			return "bot 0x%04x has velocity or angles finer than a bot's" % id
		return ""
	if not Protocol.fits_signed(velocity.x, VELOCITY_BITS) or not Protocol.fits_signed(velocity.y, VELOCITY_BITS) \
			or not Protocol.fits_signed(velocity.z, VELOCITY_BITS) or not Protocol.fits_signed(pitch, PITCH_BITS):
		return "soldier 0x%04x velocity or pitch is out of range" % id
	return ""


static func _on_grid(value: int, step: int, bits: int) -> bool:
	return value % step == 0 and Protocol.fits_signed(value / step, bits)


func velocity_bits() -> int:
	return 2 * BOT_VELOCITY_BITS if bot else 3 * VELOCITY_BITS


func angle_bits() -> int:
	return BOT_YAW_BITS + BOT_PITCH_BITS if bot else YAW_BITS + PITCH_BITS


## quantize_turn rounds an angle to one of 2^bits steps of a full turn, in the
## units of a full-precision yaw.
static func quantize_turn(radians: float, bits: int) -> int:
	var turns := radians / TAU
	turns -= floorf(turns)
	return (roundi(turns * (1 << bits)) & ((1 << bits) - 1)) << (YAW_BITS - bits)


## quantize_pitch rounds a pitch to bits signed steps over [-PI/2, PI/2], in
## the units of a full-precision pitch.
static func quantize_pitch(radians: float, bits: int) -> int:
	var step := float(1 << (PITCH_BITS - bits))
	var limit := float((1 << (PITCH_BITS - 1)) - 1)
	var steps := floorf(limit / step)
	var limited := clampf(radians, -PI / 2.0, PI / 2.0)
	return int(clampf(roundf(limited / (PI / 2.0) * limit / step), -steps, steps) * step)


## quantize_velocity rounds a velocity to steps of step/32 m/s, clamped to
## what bits signed steps hold.
static func quantize_velocity(value: float, step: int, bits: int) -> int:
	var limit := float((1 << (bits - 1)) - 1)
	return int(clampf(roundf(value * VELOCITY_UNITS_PER_METRE / step), -limit, limit)) * step
