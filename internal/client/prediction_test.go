package client

import (
	"math"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

// route crosses the ramp, jumps onto the platform and walks along its edge, so
// predictions start from slopes, steps and the air.
func route(step int, tick game.Tick) game.InputCommand {
	switch {
	case step < 36:
		return game.NewInputCommand(tick, 1, 0, math.Pi/2, 0, game.ButtonSprint)
	case step < 110:
		buttons := game.ButtonSprint
		if step >= 66 && step < 84 {
			buttons |= game.ButtonJump
		}
		return game.NewInputCommand(tick, 1, 0, 0, 0.1, buttons)
	case step < 160:
		return game.NewInputCommand(tick, 1, 0.5, -math.Pi/2, 0, 0)
	}
	return game.NewInputCommand(tick, 0, 0, 0, 0, 0)
}

// The main netcode test (ARCHITECTURE.md, 12.2): through a slow, lossy network
// the prediction matches every confirmed state, so no correction is needed.
func TestPredictionNeedsNoCorrectionsThroughTheNetwork(t *testing.T) {
	conditions := transport.NetworkConditions{Delay: 50 * time.Millisecond, Jitter: 10 * time.Millisecond, Loss: 0.05, Seed: 11}
	session, predictor := soloWithPrediction(t, conditions)
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	step, reconciled := -1, 0
	highest := float32(0)
	for range 5 * game.TickRate {
		<-ticker.C
		command := game.InputCommand{}
		if step >= 0 {
			command = route(step, 0)
			step++
		}
		command, err := session.sendCommand(command)
		if err != nil {
			t.Fatal(err)
		}
		if err := predictor.predict(command); err != nil {
			t.Fatal(err)
		}
		updated, err := session.poll()
		if err != nil {
			t.Fatal(err)
		}
		if updated {
			if err := predictor.reconcile(session.player); err != nil {
				t.Fatal(err)
			}
			reconciled++
		}
		if step < 0 && predictor.started {
			step = 0
		}
		if server := session.localSoldier(); server != nil {
			highest = max(highest, server.Position.Y)
		}
	}
	if step < 160 || highest < 1.4 {
		t.Fatalf("the route did not reach the platform: step %d, highest y=%.2f", step, highest)
	}
	if predictor.corrections > 0 {
		t.Errorf("%d corrections, the last %.4f m off", predictor.corrections, predictor.lastError)
	}
	t.Logf("%d snapshots reconciled, %d corrections, %d clock resyncs", reconciled, predictor.corrections, session.resyncs)
}

// A respawn moves the soldier across the map: the prediction jumps there at
// once instead of sliding. Placed without a saved state, the capsule may in
// rare cases need a small correction more before it agrees with the server.
func TestPredictionSnapsToARespawn(t *testing.T) {
	session, predictor := soloWithPrediction(t, transport.NetworkConditions{})
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	respawned := false
	largestOffset := float32(0)
	for frame := range 3 * game.TickRate {
		<-ticker.C
		command := game.NewInputCommand(0, 1, 0, math.Pi/2, 0, game.ButtonSprint)
		if respawned {
			command = game.InputCommand{}
		}
		command, err := session.sendCommand(command)
		if err != nil {
			t.Fatal(err)
		}
		if err := predictor.predict(command); err != nil {
			t.Fatal(err)
		}
		updated, err := session.poll()
		if err != nil {
			t.Fatal(err)
		}
		if updated {
			if err := predictor.reconcile(session.player); err != nil {
				t.Fatal(err)
			}
		}
		if respawned {
			largestOffset = max(largestOffset, distance(predictor.offset, physics.Vec3{}))
		}
		if frame == game.TickRate {
			if err := session.respawn(); err != nil {
				t.Fatal(err)
			}
			respawned = true
		}
	}
	// Commands already on their way when the respawn was asked for still move
	// the soldier a few ticks from the spawn.
	spawn := game.PrototypeScene().Spawn
	if d := distance(predictor.soldier.Position, spawn); d > 1 {
		t.Errorf("predicted soldier is %.2f m from the spawn after respawning", d)
	}
	if largestOffset > 0.1 {
		t.Errorf("the respawn was smoothed: offset up to %.2f m", largestOffset)
	}
	if predictor.corrections < 1 || predictor.corrections > 3 {
		t.Errorf("%d corrections, want the respawn and at most two small ones", predictor.corrections)
	}
	t.Logf("%d corrections, the last %.4f m", predictor.corrections, predictor.lastError)
}

// Without a network: the server applies a different command at one tick and
// confirms every tick ten ticks late. The mismatch costs one correction, after
// which the prediction equals the server's own result exactly.
func TestReconcileReplaysFromTheServerState(t *testing.T) {
	tuning := game.DefaultMovementTuning()
	predictor, err := newPredictor(sceneWorld(t), tuning)
	if err != nil {
		t.Fatal(err)
	}
	defer predictor.close()
	server, err := game.NewCharacterController(sceneWorld(t), tuning, physics.Vec3{})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	var authoritative game.Soldier
	if err := server.Teleport(&authoritative, game.PrototypeScene().Spawn); err != nil {
		t.Fatal(err)
	}
	const lag, differs = 10, 40
	history := map[game.Tick]game.Soldier{}
	for tick := game.Tick(0); tick < 150; tick++ {
		command := route(int(tick), tick)
		if err := predictor.predict(command); err != nil {
			t.Fatal(err)
		}
		if tick == differs {
			command = game.NewInputCommand(tick, 1, 0, math.Pi/2, 0, game.ButtonSprint|game.ButtonJump)
		}
		if err := server.Step(&authoritative, command); err != nil {
			t.Fatal(err)
		}
		history[tick] = authoritative
		if tick < lag {
			continue
		}
		confirmed := history[tick-lag]
		err := predictor.reconcile(protocol.PlayerState{
			Processed: true, LastProcessedTick: tick - lag, Soldier: 0x1000,
			Position: confirmed.Position, Velocity: confirmed.Velocity,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if predictor.corrections != 1 {
		t.Errorf("%d corrections, want one for tick %d", predictor.corrections, differs)
	}
	if predictor.soldier.Position != authoritative.Position || predictor.soldier.Velocity != authoritative.Velocity {
		t.Errorf("prediction %+v, server %+v", predictor.soldier, authoritative)
	}
}

func soloWithPrediction(t *testing.T, conditions transport.NetworkConditions) (*session, *predictor) {
	t.Helper()
	tuning := game.DefaultMovementTuning()
	local, err := startLocalServer(tuning, config.Client{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := local.stop(); err != nil {
			t.Error(err)
		}
	})
	conn, err := local.dial()
	if err != nil {
		t.Fatal(err)
	}
	if conditions != (transport.NetworkConditions{}) {
		conn = transport.Simulate(conn, conditions)
	}
	session, err := connect(conn, "tester", tuning, [16]byte{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.close)
	predictor, err := newPredictor(sceneWorld(t), tuning)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = predictor.close() })
	return session, predictor
}

// sceneWorld holds the static prototype scene, as the client's world does for
// prediction; its props are cosmetic and never touch the soldier.
func sceneWorld(t *testing.T) *physics.World {
	t.Helper()
	world, err := physics.NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = world.Close() })
	for _, box := range game.PrototypeScene().Boxes {
		if _, err := world.CreateBox(box); err != nil {
			t.Fatal(err)
		}
	}
	return world
}
