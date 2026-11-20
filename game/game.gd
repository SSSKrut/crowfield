class_name Game
## Constants and helpers of the shared simulation: the server and the client's
## prediction run the same code, so they agree on every value here.

## TICK_RATE is shared by the client and the server: prediction only matches
## the server when both sides step movement with the same delta.
const TICK_RATE := 60
const TICK_DELTA := 1.0 / TICK_RATE

const MAX_PLAYERS := 16
## MAX_HEALTH is the health a soldier spawns with.
const MAX_HEALTH := 100

enum Team { NONE, BLUE, RED }
enum Controller { NONE, PLAYER, BOT }

## PROTOTYPE_MAP names the prototype scene in Welcome; it is the only map yet.
const PROTOTYPE_MAP := "prototype"

## Collision layers (ARCHITECTURE.md, 7.2). Characters meet the static world,
## vehicles and props, never each other; cosmetic bodies such as ragdolls
## only meet the static world and each other.
const LAYER_STATIC := 1
const LAYER_CHARACTER := 2
const LAYER_VEHICLE := 4
const LAYER_DYNAMIC := 8
const LAYER_COSMETIC := 16

const TEAM_NAMES := ["no", "blue", "red"]


## view_direction is where a soldier with this yaw and pitch looks: yaw zero
## looks along -Z and turns towards +X, a positive pitch looks up.
static func view_direction(yaw: float, pitch: float) -> Vector3:
	var cos_pitch := cos(pitch)
	return Vector3(sin(yaw) * cos_pitch, sin(pitch), -cos(yaw) * cos_pitch)


## remainder is the IEEE remainder of value by a full turn: the angle in
## [-PI, PI] that is a whole number of turns from value.
static func remainder(value: float, turn: float = TAU) -> float:
	return value - turn * roundf(value / turn)


## yaw_of is the yaw of a direction along the ground.
static func yaw_of(direction: Vector3) -> float:
	return atan2(direction.x, -direction.z)


static func horizontal_length(value: Vector3) -> float:
	return sqrt(value.x * value.x + value.z * value.z)


static func team_name(team: int) -> String:
	if team >= 0 and team < TEAM_NAMES.size():
		return TEAM_NAMES[team]
	return "team %d" % team


## seconds_to_ticks rounds a duration in seconds to whole ticks.
static func seconds_to_ticks(seconds: float) -> int:
	return roundi(seconds * TICK_RATE)


## sequence_difference compares two 16-bit sequence numbers that wrap: how
## far a is ahead of b, negative when behind.
static func sequence_difference(a: int, b: int) -> int:
	return ((a - b + 0x8000) & 0xFFFF) - 0x8000


## logical_shift is an unsigned right shift of a 64-bit value.
static func logical_shift(value: int, bits: int) -> int:
	if bits == 0:
		return value
	return (value >> bits) & ((1 << (64 - bits)) - 1)


const _FNV_OFFSET := -3750763034362895579
const _FNV_PRIME := 1099511628211


## fnv64 is the 64-bit FNV-1a hash of bytes, wrapping like the unsigned one.
static func fnv64(bytes: PackedByteArray) -> int:
	var hash := _FNV_OFFSET
	for b in bytes:
		hash = (hash ^ b) * _FNV_PRIME
	return hash
