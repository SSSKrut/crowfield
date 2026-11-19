package game

import (
	"math"
	"testing"

	"ravenfield/internal/physics"
)

// replayRoute is a scripted walk through the prototype scene. The routes touch
// a ramp, stairs, a wall and a jump, so replays start from every kind of contact.
type replayRoute struct {
	name    string
	start   physics.Vec3
	ticks   int
	command func(tick Tick) InputCommand
}

var replayRoutes = []replayRoute{
	{"ramp and platform jump", physics.V(0, 0, 7), 150, func(tick Tick) InputCommand {
		switch {
		case tick < 36:
			return NewInputCommand(tick, 1, 0, math.Pi/2, 0, ButtonSprint)
		case tick < 132:
			buttons := ButtonSprint
			if tick >= 66 && tick < 84 {
				buttons |= ButtonJump
			}
			return NewInputCommand(tick, 1, 0, 0, 0, buttons)
		}
		return NewInputCommand(tick, 0, 0, 0, 0, 0)
	}},
	{"stairs", physics.V(-5, 0, 5), 150, func(tick Tick) InputCommand {
		return NewInputCommand(tick, 1, 0, 0, 0, 0)
	}},
	{"slide along a wall", physics.V(-3.5, 0, 0), 120, func(tick Tick) InputCommand {
		return NewInputCommand(tick, 1, 0.8, 0, 0, ButtonSprint)
	}},
	{"jump at a pillar", physics.V(0, 0, -1), 150, func(tick Tick) InputCommand {
		buttons := ButtonSprint
		if tick%40 == 5 {
			buttons |= ButtonJump
		}
		return NewInputCommand(tick, 1, float32(tick%9)/9-0.4, float32(tick)*0.01, 0, buttons)
	}},
}

// This is the client reconciliation path: restore a tick, replay the later
// commands and arrive exactly where the original run arrived.
func TestCharacterControllerReplaysFromAnyTick(t *testing.T) {
	for _, route := range replayRoutes {
		t.Run(route.name, func(t *testing.T) {
			controller := newSceneController(t, route.start)
			soldier := Soldier{Alive: true, Position: route.start}
			if err := controller.Teleport(&soldier, route.start); err != nil {
				t.Fatal(err)
			}
			commands := make([]InputCommand, route.ticks)
			history := make([]Soldier, route.ticks)
			states := make([]MovementState, route.ticks)
			for i := range commands {
				commands[i] = route.command(Tick(i))
				if err := controller.Step(&soldier, commands[i]); err != nil {
					t.Fatal(err)
				}
				history[i] = soldier
				if err := controller.SaveState(&states[i]); err != nil {
					t.Fatal(err)
				}
			}
			final := history[len(history)-1]
			if distance(final.Position, route.start) < 1 {
				t.Fatalf("route did not move the soldier: %+v", final.Position)
			}
			for from := range history {
				replayed := history[from]
				if err := controller.Restore(&replayed, &states[from]); err != nil {
					t.Fatal(err)
				}
				if replayed != history[from] {
					t.Fatalf("tick %d: restore changed the soldier: %+v, recorded %+v", from, replayed, history[from])
				}
				for _, command := range commands[from+1:] {
					if err := controller.Step(&replayed, command); err != nil {
						t.Fatal(err)
					}
				}
				if replayed != final {
					t.Fatalf("replay from tick %d ended at %+v, original %+v (off by %.2g m)",
						from, replayed, final, distance(replayed.Position, final.Position))
				}
			}
		})
	}
}

func TestTeleportRefreshesGroundState(t *testing.T) {
	controller := newSceneController(t, physics.V(0, 0, 7))
	soldier := Soldier{Alive: true}
	if err := controller.Teleport(&soldier, physics.V(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if !soldier.Grounded {
		t.Error("soldier teleported onto the floor is not grounded")
	}
	if err := controller.Teleport(&soldier, physics.V(0, 5, 7)); err != nil {
		t.Fatal(err)
	}
	if soldier.Grounded {
		t.Error("soldier teleported into the air is still grounded")
	}
}

// newSceneController builds the static part of the prototype scene. Dynamic
// bodies are left out: they are not rolled back, and on clients they will be
// kinematic copies of the server state.
func newSceneController(t *testing.T, feet physics.Vec3) *CharacterController {
	t.Helper()
	world, err := physics.NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = world.Close() })
	for _, box := range PrototypeScene().Boxes {
		if _, err := world.CreateBox(box); err != nil {
			t.Fatal(err)
		}
	}
	controller, err := NewCharacterController(world, DefaultMovementTuning(), feet)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = controller.Close() })
	return controller
}

func distance(first, second physics.Vec3) float32 {
	d := first.Sub(second)
	return float32Sqrt(d.X*d.X + d.Y*d.Y + d.Z*d.Z)
}
