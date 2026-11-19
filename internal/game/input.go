package game

import "math"

type Buttons uint16

const (
	ButtonJump Buttons = 1 << iota
	ButtonSprint
	ButtonFire
	ButtonAim
	ButtonReload
	ButtonInteract
	ButtonCrouch

	knownButtons = ButtonCrouch<<1 - 1
)

func (b Buttons) Has(button Buttons) bool {
	return b&button != 0
}

const maxWeaponSlot = 15

// InputCommand is what a human player sends for one tick. Values are quantized
// on creation, so the client predicts from exactly what the server receives.
// ViewDelta and ViewFrac locate the snapshot the player saw, for lag compensation.
type InputCommand struct {
	Tick        Tick
	MoveForward int8
	MoveRight   int8
	Yaw         uint16
	Pitch       int16
	Buttons     Buttons
	Weapon      uint8
	ViewDelta   uint8
	ViewFrac    uint8
}

func NewInputCommand(tick Tick, forward, right, yaw, pitch float32, buttons Buttons) InputCommand {
	return InputCommand{
		Tick: tick, MoveForward: quantizeAxis(forward), MoveRight: quantizeAxis(right),
		Yaw: quantizeYaw(yaw), Pitch: quantizePitch(pitch), Buttons: buttons & knownButtons,
	}
}

func (c InputCommand) Move() (forward, right float32) {
	return float32(c.MoveForward) / 127, float32(c.MoveRight) / 127
}

func (c InputCommand) YawRadians() float32 {
	return float32(c.Yaw) * (2 * math.Pi / 65536)
}

func (c InputCommand) PitchRadians() float32 {
	return float32(c.Pitch) * (math.Pi / 2 / 32767)
}

// Sanitize clamps values that a client can send but NewInputCommand never produces.
func (c *InputCommand) Sanitize() {
	c.MoveForward = max(c.MoveForward, -127)
	c.MoveRight = max(c.MoveRight, -127)
	c.Pitch = max(c.Pitch, -32767)
	c.Buttons &= knownButtons
	c.Weapon = min(c.Weapon, maxWeaponSlot)
}

func quantizeAxis(value float32) int8 {
	return int8(math.Round(float64(max(-1, min(1, value)) * 127)))
}

func quantizeYaw(radians float32) uint16 {
	turns := float64(radians) / (2 * math.Pi)
	turns -= math.Floor(turns)
	return uint16(int64(math.Round(turns*65536)) & 0xFFFF)
}

func quantizePitch(radians float32) int16 {
	limited := max(-math.Pi/2, min(math.Pi/2, float64(radians)))
	return int16(math.Round(limited / (math.Pi / 2) * 32767))
}
