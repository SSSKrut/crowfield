package client

import (
	"math"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

// testPlayer is a client driven by the test: a session and its prediction.
type testPlayer struct {
	t         *testing.T
	session   *session
	predictor *predictor
}

func newTestPlayer(t *testing.T, address, name string) *testPlayer {
	t.Helper()
	rules := game.DefaultRules()
	session, err := connect(dialTestServer(t, address, transport.QUICOptions{}), name, rules, [16]byte{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(session.close)
	predictor, err := newPredictor(sceneWorld(t), rules)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = predictor.close() })
	predictor.join(session.welcome.MatchSeed)
	return &testPlayer{t: t, session: session, predictor: predictor}
}

// tick plays a command and takes in what the server sent.
func (p *testPlayer) tick(command game.InputCommand) {
	p.t.Helper()
	command, err := p.session.sendCommand(command)
	if err != nil {
		p.t.Fatal(err)
	}
	if _, err := p.predictor.predict(command); err != nil {
		p.t.Fatal(err)
	}
	updated, err := p.session.poll()
	if err != nil {
		p.t.Fatal(err)
	}
	if updated {
		if err := p.predictor.reconcile(p.session.player); err != nil {
			p.t.Fatal(err)
		}
	}
	p.session.clock.advance(game.TickDelta)
}

// edge is how far left the players of the combat test walk.
const edge = -10

// toTheEdge walks a player left until it stands at the edge.
func toTheEdge(p *testPlayer) game.InputCommand {
	if p.predictor.started && p.predictor.soldier.Position.X > edge {
		return game.NewInputCommand(0, 0, -1, 0, 0, 0)
	}
	return game.InputCommand{}
}

// The main test of combat over the network: both players walk to the open
// left edge of the map, where nothing stands between their spawns, and one
// aims at the other's body and fires single rounds of the assault rifle
// until it dies. Both learn of the death from
// the server, the dead one stops being predicted, and after the delay it
// comes back as a new soldier at its spawn, which the shooter sees too.
func TestPlayersKillAndComeBackOverQUIC(t *testing.T) {
	address := startTestServer(t, config.Server{MaxPlayers: 2, SnapshotRate: 20, RespawnDelay: 500 * time.Millisecond})
	shooter := newTestPlayer(t, address, "shooter")
	victim := newTestPlayer(t, address, "victim")
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	play := func(what string, limit time.Duration, shoot func(tick int) game.InputCommand, done func() bool) {
		t.Helper()
		for tick, deadline := 0, time.Now().Add(limit); !done(); tick++ {
			if time.Now().After(deadline) {
				t.Fatalf("%s did not happen within %s", what, limit)
			}
			<-ticker.C
			shooter.tick(shoot(tick))
			victim.tick(toTheEdge(victim))
		}
	}
	idle := func(int) game.InputCommand { return toTheEdge(shooter) }
	target := func() *knownSoldier {
		id := victim.session.player.Soldier
		if known := shooter.session.soldiers[id.Slot()]; id != 0 && known != nil && known.soldier.ID == id {
			return known
		}
		return nil
	}
	play("stepping out", 3*time.Second, idle, func() bool {
		known := target()
		return shooter.predictor.started && shooter.predictor.soldier.Position.X <= edge &&
			known != nil && known.soldier.Position.X <= edge && horizontalSpeed(known.soldier.Velocity) == 0
	})
	victimTeam := target().soldier.Team
	dead := victim.session.player.Soldier
	aim := func(tick int) game.InputCommand {
		eye := shooter.predictor.soldier.Position.Add(physics.V(0, game.DefaultMovementTuning().EyeHeight, 0))
		to := target().soldier.Position.Add(physics.V(0, 0.85, 0)).Sub(eye)
		yaw := math.Atan2(float64(to.X), float64(-to.Z))
		pitch := math.Atan2(float64(to.Y), math.Hypot(float64(to.X), float64(to.Z)))
		buttons := game.ButtonAim
		if tick%12 == 0 {
			buttons |= game.ButtonFire
		}
		return game.NewInputCommand(0, 0, 0, float32(yaw), float32(pitch), buttons)
	}
	play("the kill", 5*time.Second, aim, func() bool { return victim.session.player.Health == 0 })
	if victim.session.player.Soldier != dead || victim.session.player.Respawn == 0 {
		t.Fatalf("the victim is told %+v", victim.session.player)
	}
	play("the shooter seeing the death", time.Second, idle, func() bool {
		known := shooter.session.soldiers[dead.Slot()]
		return known == nil || known.soldier.ID != dead || !known.soldier.Alive
	})
	if victim.predictor.started {
		t.Error("the dead victim is still predicted")
	}
	play("the return", 2*time.Second, idle, func() bool {
		player := victim.session.player
		return player.Soldier != dead && player.Health == game.MaxHealth && victim.predictor.started
	})
	back := victim.predictor.soldier.Position
	if spawn := game.PrototypeScene().SpawnOf(victimTeam); math.Hypot(float64(back.X-spawn.X), float64(back.Z-spawn.Z)) > 1 {
		t.Errorf("the victim came back at %+v, its spawn is %+v", back, spawn)
	}
	play("the shooter seeing the return", time.Second, idle, func() bool { return target() != nil })
	if old := shooter.session.soldiers[dead.Slot()]; old != nil && old.soldier.ID == dead {
		t.Error("the shooter still knows the dead soldier")
	}
	if shooter.predictor.corrections+victim.predictor.corrections > 0 {
		t.Errorf("%d and %d corrections", shooter.predictor.corrections, victim.predictor.corrections)
	}
	if shooter.session.player.Health != game.MaxHealth {
		t.Errorf("the shooter was hurt: health %d", shooter.session.player.Health)
	}
}
