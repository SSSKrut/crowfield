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

// armedRoute is the route with the weapons at work: a burst of the assault
// rifle on the ramp, the pistol out for single shots on the platform, and a
// reload of it.
func armedRoute(step int, tick game.Tick) game.InputCommand {
	command := route(step, tick)
	switch {
	case step >= 10 && step < 50:
		command.Buttons |= game.ButtonFire
	case step >= 70:
		command.Weapon = 2
		if step%12 < 4 {
			command.Buttons |= game.ButtonFire | game.ButtonAim
		}
		if step == 140 {
			command.Buttons |= game.ButtonReload
		}
	}
	return command
}

// The main netcode test (ARCHITECTURE.md, 12.2): through a slow, lossy network
// the prediction of movement and weapons matches every confirmed state, so
// no correction is needed.
func TestPredictionNeedsNoCorrectionsThroughTheNetwork(t *testing.T) {
	conditions := transport.NetworkConditions{Delay: 50 * time.Millisecond, Jitter: 10 * time.Millisecond, Loss: 0.05, Seed: 11}
	session, predictor := soloWithPrediction(t, conditions)
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	step, reconciled, shots := -1, 0, 0
	highest := float32(0)
	for range 5 * game.TickRate {
		<-ticker.C
		command := game.InputCommand{}
		if step >= 0 {
			command = armedRoute(step, 0)
			step++
		}
		command, err := session.sendCommand(command)
		if err != nil {
			t.Fatal(err)
		}
		fired, err := predictor.predict(command)
		if err != nil {
			t.Fatal(err)
		}
		if fired.Events.Has(game.EventFired) {
			shots++
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
		t.Errorf("%d corrections (%d of the weapons only), the last %.4f m off",
			predictor.corrections, predictor.weaponCorrections, predictor.lastError)
	}
	// 7 rounds of the burst and 4 pistol shots before the reload, which
	// takes 4 spare rounds; how many pulls follow it depends on when the
	// route started.
	ammo := predictor.soldier.Arsenal.Ammo
	if shots < 12 || ammo[0].Magazine != 23 || ammo[2].Reserve != 44 {
		t.Errorf("%d shots predicted, ammo %+v after the route", shots, ammo)
	}
	t.Logf("%d snapshots reconciled, %d shots, %d corrections, %d clock resyncs", reconciled, shots, predictor.corrections, session.resyncs)
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
		if _, err := predictor.predict(command); err != nil {
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
	rules := game.DefaultRules()
	predictor, err := newPredictor(sceneWorld(t), rules)
	if err != nil {
		t.Fatal(err)
	}
	defer predictor.close()
	server, err := game.NewCharacterController(sceneWorld(t), rules.Movement, physics.Vec3{})
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
		if _, err := predictor.predict(command); err != nil {
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
			Position: confirmed.Position, Velocity: confirmed.Velocity, Health: game.MaxHealth,
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

// A new session may reuse the tick numbers of the last one, whose commands
// the server never saw: the prediction must not replay them.
func TestJoinForgetsTheLastSession(t *testing.T) {
	predictor, err := newPredictor(sceneWorld(t), game.DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	defer predictor.close()
	spawn := game.PrototypeScene().Spawn
	confirm := func(tick game.Tick) {
		t.Helper()
		err := predictor.reconcile(protocol.PlayerState{
			Processed: true, LastProcessedTick: tick, Soldier: 0x1000, Position: spawn, Health: game.MaxHealth,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	// The last session ran forward until tick 30.
	if _, err := predictor.predict(game.NewInputCommand(0, 1, 0, 0, 0, 0)); err != nil {
		t.Fatal(err)
	}
	confirm(0)
	for tick := game.Tick(1); tick <= 30; tick++ {
		if _, err := predictor.predict(game.NewInputCommand(tick, 1, 0, 0, 0, 0)); err != nil {
			t.Fatal(err)
		}
	}
	// In the new one the server has stood the soldier still until tick 20,
	// and the client's first command is for tick 25.
	predictor.join(7)
	if _, err := predictor.predict(game.NewInputCommand(25, 0, 0, 0, 0, 0)); err != nil {
		t.Fatal(err)
	}
	confirm(20)
	if moved := math.Hypot(float64(predictor.soldier.Position.X-spawn.X), float64(predictor.soldier.Position.Z-spawn.Z)); moved > 1e-3 {
		t.Errorf("the soldier moved %.3f m on commands of the last session", moved)
	}
}

// The dead are not predicted: the soldier stays where the server has it
// while commands go on, and a new soldier starts the prediction without a
// correction.
func TestDeathStopsThePredictionUntilANewSoldier(t *testing.T) {
	predictor, err := newPredictor(sceneWorld(t), game.DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	defer predictor.close()
	spawn := game.PrototypeScene().Spawn
	state := protocol.PlayerState{Processed: true, Soldier: 0x1000, Position: spawn, Health: game.MaxHealth}
	run := func(from, to game.Tick) {
		t.Helper()
		for tick := from; tick < to; tick++ {
			if _, err := predictor.predict(game.NewInputCommand(tick, 1, 0, 0, 0, game.ButtonFire)); err != nil {
				t.Fatal(err)
			}
		}
	}
	run(0, 1)
	if err := predictor.reconcile(state); err != nil {
		t.Fatal(err)
	}
	run(1, 10)
	state.LastProcessedTick, state.Health, state.Respawn, state.Position = 5, 0, 60, physics.V(1, 0, 3)
	if err := predictor.reconcile(state); err != nil {
		t.Fatal(err)
	}
	run(10, 40)
	if predictor.started || predictor.soldier.Position != state.Position {
		t.Errorf("the dead soldier was predicted to %+v", predictor.soldier.Position)
	}
	state = protocol.PlayerState{Processed: true, LastProcessedTick: 38, Soldier: 0x2000, Position: spawn, Health: game.MaxHealth}
	if err := predictor.reconcile(state); err != nil {
		t.Fatal(err)
	}
	if !predictor.started || predictor.corrections != 0 || predictor.soldier.ID != 0x2000 {
		t.Errorf("the new soldier: started %t, %d corrections, soldier %#04x", predictor.started, predictor.corrections, predictor.soldier.ID)
	}
}

func soloWithPrediction(t *testing.T, conditions transport.NetworkConditions) (*session, *predictor) {
	t.Helper()
	rules := game.DefaultRules()
	local, err := startLocalServer(rules, config.Client{})
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
	session, err := connect(conn, "tester", rules, [16]byte{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.close)
	predictor, err := newPredictor(sceneWorld(t), rules)
	if err != nil {
		t.Fatal(err)
	}
	predictor.join(session.welcome.MatchSeed)
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
