package client

import (
	"math"
	"testing"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

func TestHermiteFollowsSteadyMotionExactly(t *testing.T) {
	var remote remoteSoldier
	velocity := physics.V(3, 0, -4)
	for tick := game.Tick(100); tick <= 130; tick += 3 {
		elapsed := float32(tick-100) / game.TickRate
		remote.add(tick, game.Soldier{Position: velocity.Mul(elapsed), Velocity: velocity})
	}
	for _, renderTick := range []float64{100, 101.5, 107.25, 119.9, 130} {
		want := velocity.Mul(float32((renderTick - 100) / game.TickRate))
		if got := remote.at(renderTick).Position; distance(got, want) > 1e-4 {
			t.Errorf("at %.2f: %+v, want %+v", renderTick, got, want)
		}
	}
}

func TestRemoteSoldierPastTheNewestState(t *testing.T) {
	var remote remoteSoldier
	remote.add(10, game.Soldier{Position: physics.V(0, 0, 0), Velocity: physics.V(6, 0, 0)})
	remote.add(13, game.Soldier{Position: physics.V(0.3, 0, 0), Velocity: physics.V(6, 0, 0)})
	if got := remote.at(16).Position.X; math.Abs(float64(got)-0.6) > 1e-4 {
		t.Errorf("three ticks past the newest state x=%.3f, want 0.6", got)
	}
	limit := 0.3 + 6*float64(maxExtrapolation)/game.TickRate
	if got := remote.at(1000).Position.X; math.Abs(float64(got)-limit) > 1e-4 {
		t.Errorf("long past the newest state x=%.3f, want it to stop at %.3f", got, limit)
	}
	if got := remote.at(5).Position; got != (physics.Vec3{}) {
		t.Errorf("before the oldest state %+v, want the oldest", got)
	}
	remote.add(12, game.Soldier{Position: physics.V(9, 9, 9)})
	if got := remote.at(12).Position; got.Y != 0 {
		t.Errorf("a late older state was used: %+v", got)
	}
}

func TestRemoteSoldierStaysOnTheFloorAndTurnsTheShortWay(t *testing.T) {
	var remote remoteSoldier
	remote.add(0, game.Soldier{Grounded: true, Velocity: physics.V(0, -0.5, 0), Yaw: 2*math.Pi - 0.1})
	remote.add(6, game.Soldier{Grounded: true, Velocity: physics.V(0, -0.5, 0), Yaw: 0.1})
	middle := remote.at(3)
	if middle.Position.Y != 0 {
		t.Errorf("a grounded soldier dipped to y=%.4f", middle.Position.Y)
	}
	if yaw := math.Remainder(float64(middle.Yaw), 2*math.Pi); math.Abs(yaw) > 1e-4 {
		t.Errorf("turned the long way: yaw %.3f", middle.Yaw)
	}
	if got := remote.at(100).Position.Y; got != 0 {
		t.Errorf("extrapolation sank a grounded soldier to y=%.3f", got)
	}
}

func TestInterpolationClockFollowsSnapshots(t *testing.T) {
	clock := newInterpolationClock(20)
	if clock.delay != 7 {
		t.Fatalf("delay %.1f ticks at 20 snapshots per second, want 7", clock.delay)
	}
	clock.observe(100)
	if clock.renderTick != 93 {
		t.Fatalf("started at %.2f, want 93", clock.renderTick)
	}
	// The frame clock runs a little fast; snapshots pull it back.
	for tick := game.Tick(103); tick <= 400; tick += 3 {
		clock.advance(3.3 / game.TickRate)
		clock.observe(tick)
	}
	if lag := 400 - clock.delay - clock.renderTick; math.Abs(lag) > 3 {
		t.Errorf("clock is %.2f ticks off its target", lag)
	}
	clock.observe(1000)
	if clock.renderTick != 1000-clock.delay {
		t.Errorf("a big jump was smoothed instead of taken: %.2f", clock.renderTick)
	}
}
