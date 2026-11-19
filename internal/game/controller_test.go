package game

import (
	"testing"

	"ravenfield/internal/physics"
)

func TestCharacterControllerWalksAndSprints(t *testing.T) {
	controller, soldier := newTestSoldier(t)
	tick := settle(t, controller, soldier)
	tuning := DefaultMovementTuning()
	for _, c := range []struct {
		buttons Buttons
		speed   float32
	}{{0, tuning.WalkSpeed}, {ButtonSprint, tuning.SprintSpeed}} {
		start := soldier.Position
		for range TickRate {
			if err := controller.Step(soldier, NewInputCommand(tick, 1, 0, 0, 0, c.buttons)); err != nil {
				t.Fatal(err)
			}
			tick++
		}
		// Yaw 0 faces -Z, so one second forward moves the soldier by its speed along -Z.
		moved := start.Z - soldier.Position.Z
		if !near(moved, c.speed, 0.05) || !near(soldier.Position.X, start.X, 0.01) {
			t.Errorf("buttons %b: moved %.3f m to %+v, want %.1f m along -Z", c.buttons, moved, soldier.Position, c.speed)
		}
		if !soldier.Grounded || !near(soldier.Position.Y, 0, 0.05) {
			t.Errorf("buttons %b: soldier left the floor: %+v grounded=%t", c.buttons, soldier.Position, soldier.Grounded)
		}
	}
}

func TestCharacterControllerJumps(t *testing.T) {
	controller, soldier := newTestSoldier(t)
	tick := settle(t, controller, soldier)
	peak := float32(0)
	for i := range TickRate * 2 {
		buttons := Buttons(0)
		if i == 0 {
			buttons = ButtonJump
		}
		if err := controller.Step(soldier, NewInputCommand(tick, 0, 0, 0, 0, buttons)); err != nil {
			t.Fatal(err)
		}
		peak = max(peak, soldier.Position.Y)
		tick++
	}
	tuning := DefaultMovementTuning()
	want := tuning.JumpSpeed * tuning.JumpSpeed / (2 * tuning.Gravity)
	if !near(peak, want, 0.1) {
		t.Errorf("jump peak %.3f m, want about %.3f m", peak, want)
	}
	if !soldier.Grounded || !near(soldier.Position.Y, 0, 0.05) {
		t.Errorf("soldier did not land: %+v grounded=%t", soldier.Position, soldier.Grounded)
	}
}

func TestCharacterControllerIsRepeatable(t *testing.T) {
	run := func() Soldier {
		controller, soldier := newTestSoldier(t)
		for tick := range Tick(240) {
			buttons := ButtonSprint
			if tick%50 == 10 {
				buttons |= ButtonJump
			}
			command := NewInputCommand(tick, 1, float32(tick%7)/7-0.5, float32(tick)*0.02, 0.1, buttons)
			if err := controller.Step(soldier, command); err != nil {
				t.Fatal(err)
			}
		}
		return *soldier
	}
	first, second := run(), run()
	if first != second {
		t.Errorf("same commands gave different soldiers:\n%+v\n%+v", first, second)
	}
}

func newTestSoldier(t *testing.T) (*CharacterController, *Soldier) {
	t.Helper()
	world, err := physics.NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = world.Close() })
	_, err = world.CreateBox(physics.BoxDesc{
		HalfExtents: physics.V(50, 0.25, 50),
		Transform:   physics.Transform{Position: physics.V(0, -0.25, 0), Rotation: physics.IdentityQuat()},
	})
	if err != nil {
		t.Fatal(err)
	}
	spawn := physics.V(0, 0.2, 0)
	controller, err := NewCharacterController(world, DefaultMovementTuning(), spawn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	return controller, &Soldier{Alive: true, Position: spawn}
}

func settle(t *testing.T, controller *CharacterController, soldier *Soldier) Tick {
	t.Helper()
	tick := Tick(0)
	for ; tick < TickRate/2; tick++ {
		if err := controller.Step(soldier, NewInputCommand(tick, 0, 0, 0, 0, 0)); err != nil {
			t.Fatal(err)
		}
	}
	if !soldier.Grounded {
		t.Fatalf("soldier did not land after spawning: %+v", soldier.Position)
	}
	return tick
}
