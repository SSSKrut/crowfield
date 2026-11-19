package game

import (
	"math"
	"testing"
)

func TestInputCommandQuantizationRoundTrip(t *testing.T) {
	cases := []struct {
		forward, right, yaw, pitch float32
	}{
		{1, 0, 0, 0},
		{-1, 1, math.Pi / 2, 0.5},
		{0.3, -0.7, 3 * math.Pi / 2, -1.45},
		{0, 0, 2*math.Pi - 0.0001, math.Pi / 2},
	}
	for _, c := range cases {
		command := NewInputCommand(7, c.forward, c.right, c.yaw, c.pitch, ButtonSprint)
		forward, right := command.Move()
		if !near(forward, c.forward, 1.0/127) || !near(right, c.right, 1.0/127) {
			t.Errorf("axes %v %v became %v %v", c.forward, c.right, forward, right)
		}
		if diff := angleDiff(command.YawRadians(), c.yaw); diff > 2*math.Pi/65536 {
			t.Errorf("yaw %v became %v", c.yaw, command.YawRadians())
		}
		if !near(command.PitchRadians(), c.pitch, math.Pi/2/32767) {
			t.Errorf("pitch %v became %v", c.pitch, command.PitchRadians())
		}
		if command.Tick != 7 || !command.Buttons.Has(ButtonSprint) || command.Buttons.Has(ButtonJump) {
			t.Errorf("tick or buttons changed: %+v", command)
		}
	}
}

func TestInputCommandWrapsAndClamps(t *testing.T) {
	if NewInputCommand(0, 0, 0, -math.Pi/2, 0, 0).Yaw != NewInputCommand(0, 0, 0, 3*math.Pi/2, 0, 0).Yaw {
		t.Error("negative yaw does not wrap to the same quantized value")
	}
	if NewInputCommand(0, 0, 0, 4*math.Pi, 0, 0).Yaw != 0 {
		t.Error("two full turns do not wrap to zero")
	}
	command := NewInputCommand(0, 5, -5, 0, 3, 0xFFFF)
	if command.MoveForward != 127 || command.MoveRight != -127 || command.Pitch != 32767 {
		t.Errorf("values were not clamped: %+v", command)
	}
	if command.Buttons != knownButtons {
		t.Errorf("unknown buttons kept: %b", command.Buttons)
	}
}

func TestInputCommandSanitize(t *testing.T) {
	command := InputCommand{MoveForward: -128, MoveRight: -128, Pitch: -32768, Buttons: 0xFFFF, Weapon: 200}
	command.Sanitize()
	want := InputCommand{MoveForward: -127, MoveRight: -127, Pitch: -32767, Buttons: knownButtons, Weapon: maxWeaponSlot}
	if command != want {
		t.Errorf("sanitized %+v, want %+v", command, want)
	}
	forward, right := command.Move()
	if forward != -1 || right != -1 || command.PitchRadians() < -math.Pi/2-1e-6 {
		t.Errorf("sanitized command leaves range: %v %v %v", forward, right, command.PitchRadians())
	}
}

func TestRepeatedCommandDropsOneOffActions(t *testing.T) {
	command := NewInputCommand(10, 1, -1, 2, 0.3, ButtonJump|ButtonSprint|ButtonFire|ButtonReload|ButtonInteract)
	repeated := command.Repeated(11)
	want := command
	want.Tick, want.Buttons = 11, ButtonSprint|ButtonFire
	if repeated != want {
		t.Errorf("repeated %+v, want %+v", repeated, want)
	}
}

func near(value, want, tolerance float32) bool {
	return float32(math.Abs(float64(value-want))) <= tolerance+1e-6
}

func angleDiff(first, second float32) float64 {
	diff := math.Mod(math.Abs(float64(first-second)), 2*math.Pi)
	return min(diff, 2*math.Pi-diff)
}
