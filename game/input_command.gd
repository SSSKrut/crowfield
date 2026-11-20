class_name InputCommand
extends RefCounted
## InputCommand is what a human player sends for one tick. Values are quantized
## on creation, so the client predicts from exactly what the server receives.
## view_delta and view_frac tell which moment of the server the player saw
## when it made the command, for lag compensation: view_delta ticks before
## tick and view_frac/256 of a tick after that. A zero view_delta means now.

const JUMP := 1
const SPRINT := 2
const FIRE := 4
const AIM := 8
const RELOAD := 16
const INTERACT := 32
const CROUCH := 64
const KNOWN_BUTTONS := CROUCH * 2 - 1
## EDGE_BUTTONS trigger an action once; a command repeated for a lost one must
## not trigger them again.
const EDGE_BUTTONS := JUMP | RELOAD | INTERACT

const MAX_WEAPON_SLOT := 15

var tick := 0
var move_forward := 0
var move_right := 0
var yaw := 0
var pitch := 0
var buttons := 0
var weapon := 0
var view_delta := 0
var view_frac := 0


static func create(tick_number: int, forward: float, right: float, yaw_radians: float, pitch_radians: float, pressed: int) -> InputCommand:
	var command := InputCommand.new()
	command.tick = tick_number
	command.move_forward = quantize_axis(forward)
	command.move_right = quantize_axis(right)
	command.yaw = quantize_yaw(yaw_radians)
	command.pitch = quantize_pitch(pitch_radians)
	command.buttons = pressed & KNOWN_BUTTONS
	return command


func copy() -> InputCommand:
	var command := InputCommand.new()
	command.tick = tick
	command.move_forward = move_forward
	command.move_right = move_right
	command.yaw = yaw
	command.pitch = pitch
	command.buttons = buttons
	command.weapon = weapon
	command.view_delta = view_delta
	command.view_frac = view_frac
	return command


func equals(other: InputCommand) -> bool:
	return tick == other.tick and move_forward == other.move_forward and move_right == other.move_right \
		and yaw == other.yaw and pitch == other.pitch and buttons == other.buttons and weapon == other.weapon \
		and view_delta == other.view_delta and view_frac == other.view_frac


func has(button: int) -> bool:
	return buttons & button != 0


func forward_axis() -> float:
	return move_forward / 127.0


func right_axis() -> float:
	return move_right / 127.0


func yaw_radians() -> float:
	return yaw * (TAU / 65536.0)


func pitch_radians() -> float:
	return pitch * (PI / 2.0 / 32767.0)


## has_view_time tells whether the player saw a moment in the past; view_time
## is that moment of the server, as a fractional tick.
func has_view_time() -> bool:
	return view_delta != 0


func view_time() -> float:
	return float(tick) - view_delta + view_frac / 256.0


## repeated stands in for a command that did not arrive in time for its tick:
## the player probably still moves and looks the same way, but one-off
## actions are not repeated.
func repeated(at_tick: int) -> InputCommand:
	var command := copy()
	command.tick = at_tick
	command.buttons &= ~EDGE_BUTTONS
	return command


## sanitize clamps values that a client can send but create never produces.
func sanitize() -> void:
	move_forward = maxi(move_forward, -127)
	move_right = maxi(move_right, -127)
	pitch = maxi(pitch, -32767)
	buttons &= KNOWN_BUTTONS
	weapon = mini(weapon, MAX_WEAPON_SLOT)


static func quantize_axis(value: float) -> int:
	return roundi(clampf(value, -1.0, 1.0) * 127.0)


static func quantize_yaw(radians: float) -> int:
	var turns := radians / TAU
	turns -= floorf(turns)
	return roundi(turns * 65536.0) & 0xFFFF


static func quantize_pitch(radians: float) -> int:
	var limited := clampf(radians, -PI / 2.0, PI / 2.0)
	return roundi(limited / (PI / 2.0) * 32767.0)
