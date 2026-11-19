package protocol

import (
	"math"
	"math/rand/v2"
	"testing"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

// Rounding loses at most half a step: the full one for humans, the coarser one
// for bots.
func TestSoldierStatePrecision(t *testing.T) {
	random := rand.New(rand.NewPCG(5, 6))
	span := func(limit float64) float32 { return float32((random.Float64()*2 - 1) * limit) }
	for i := range 2000 {
		bot := i%2 == 1
		sent := game.Soldier{
			ID: soldierID(i%game.MaxSoldiers, uint8(1+i%15)), Team: game.Team(i % 3),
			Alive: i%3 == 0, Grounded: i%5 == 0, Controller: game.PlayerController(game.PlayerID(i % game.MaxPlayers)),
			Position: physics.V(span(2047), span(511), span(2047)),
			Velocity: physics.V(span(63), span(63), span(63)),
			Yaw:      span(20), Pitch: span(math.Pi / 2),
		}
		velocityStep, yawStep, pitchStep := 1.0/VelocityUnitsPerMetre, 2*math.Pi/(1<<yawBits), math.Pi/2/511
		if bot {
			sent.Controller = game.BotController(game.BotID(i))
			sent.Velocity = physics.V(span(15.8), span(63), span(15.8))
			// The coarse pitch reaches only 87° up; bots never look steeper.
			sent.Pitch = span(1.5)
			velocityStep, yawStep, pitchStep = velocityStep*botVelocityStep, yawStep*botAngleStep, pitchStep*botAngleStep
		}
		state, err := NewSoldierState(&sent)
		if err != nil {
			t.Fatal(err)
		}
		data, err := (&Snapshot{Soldiers: []SoldierRecord{{State: state}}}).Encode(nil)
		if err != nil {
			t.Fatal(err)
		}
		var snapshot Snapshot
		if err := snapshot.Decode(data); err != nil {
			t.Fatal(err)
		}
		var received game.Soldier
		snapshot.Soldiers[0].State.Apply(&received)
		if received.ID != sent.ID || received.Team != sent.Team || received.Alive != sent.Alive ||
			received.Grounded != sent.Grounded || (received.Controller.Kind == game.ControllerBot) != bot {
			t.Fatalf("identity changed: sent %+v, received %+v", sent, received)
		}
		if d := maxAxis(received.Position.Sub(sent.Position)); d > 0.5/PositionUnitsPerMetre+1e-4 {
			t.Fatalf("position off by %.5f m: %+v vs %+v", d, received.Position, sent.Position)
		}
		if bot {
			// A bot has no vertical velocity on the wire.
			sent.Velocity.Y = 0
		}
		if d := maxAxis(received.Velocity.Sub(sent.Velocity)); float64(d) > velocityStep/2+1e-5 {
			t.Fatalf("velocity off by %.5f m/s", d)
		}
		yawError := math.Mod(math.Abs(float64(received.Yaw-sent.Yaw)), 2*math.Pi)
		if yawError = min(yawError, 2*math.Pi-yawError); yawError > yawStep/2+1e-5 {
			t.Fatalf("yaw off by %.5f rad", yawError)
		}
		if d := math.Abs(float64(received.Pitch - sent.Pitch)); d > pitchStep/2+1e-4 {
			t.Fatalf("pitch off by %.5f rad (%t)", d, bot)
		}
	}
}

func TestNewSoldierStateLimits(t *testing.T) {
	base := game.Soldier{ID: soldierID(1, 1)}
	for name, position := range map[string]physics.Vec3{
		"east of the map":  physics.V(2049, 0, 0),
		"above the map":    physics.V(0, 513, 0),
		"south of the map": physics.V(0, 0, -2049),
		"not a number":     physics.V(float32(math.NaN()), 0, 0),
	} {
		soldier := base
		soldier.Position = position
		if _, err := NewSoldierState(&soldier); err == nil {
			t.Errorf("%s: accepted %+v", name, position)
		}
	}
	fast := base
	fast.Velocity = physics.V(500, -500, 0)
	state, err := NewSoldierState(&fast)
	if err != nil {
		t.Fatal(err)
	}
	if state.Velocity[0] != 2047 || state.Velocity[1] != -2047 {
		t.Errorf("velocity not clamped to the protocol range: %v", state.Velocity)
	}
	fast.Controller = game.BotController(1)
	fast.Velocity = physics.V(-500, 3, 500)
	if state, err = NewSoldierState(&fast); err != nil {
		t.Fatal(err)
	}
	if state.Velocity != [3]int16{-508, 0, 508} {
		t.Errorf("bot velocity not clamped to its range: %v", state.Velocity)
	}
	if _, err := NewSoldierState(&game.Soldier{}); err == nil {
		t.Error("soldier with a zero ID accepted")
	}
}

func maxAxis(v physics.Vec3) float32 {
	return float32(max(math.Abs(float64(v.X)), math.Abs(float64(v.Y)), math.Abs(float64(v.Z))))
}
