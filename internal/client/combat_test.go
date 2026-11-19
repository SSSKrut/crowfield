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

// testPlayer is a client driven by the test: a session and its prediction,
// and what it heard and did.
type testPlayer struct {
	t         *testing.T
	session   *session
	predictor *predictor
	events    []protocol.Message
	shots     int
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
	step, err := p.predictor.predict(command)
	if err != nil {
		p.t.Fatal(err)
	}
	if step.Events.Has(game.EventFired) {
		p.shots++
	}
	updated, err := p.session.poll()
	if err != nil {
		p.t.Fatal(err)
	}
	p.events = append(p.events, p.session.news...)
	if updated {
		if err := p.predictor.reconcile(p.session.player); err != nil {
			p.t.Fatal(err)
		}
	}
	p.session.clock.advance(game.TickDelta)
}

// sees is the other player's soldier as this one knows it, or nil.
func (p *testPlayer) sees(other *testPlayer) *knownSoldier {
	id := other.session.player.Soldier
	if known := p.session.soldiers[id.Slot()]; id != 0 && known != nil && known.soldier.ID == id {
		return known
	}
	return nil
}

// edge is how far left the players of the combat test walk: nothing stands
// between their spawns there.
const edge = -10

// toTheEdge walks a player left until it stands at the edge.
func toTheEdge(p *testPlayer) game.InputCommand {
	if p.predictor.started && p.predictor.soldier.Position.X > edge {
		return game.NewInputCommand(0, 0, -1, 0, 0, 0)
	}
	return game.InputCommand{}
}

// aimAt fires single rounds of the assault rifle at the body of the other
// player where it is drawn, every twelfth tick.
func aimAt(p, other *testPlayer, tick int) game.InputCommand {
	eye := p.predictor.soldier.Position.Add(physics.V(0, game.DefaultMovementTuning().EyeHeight, 0))
	target := p.sees(other).remote.at(p.session.clock.renderTick).Position
	to := target.Add(physics.V(0, 0.85, 0)).Sub(eye)
	yaw := math.Atan2(float64(to.X), float64(-to.Z))
	pitch := math.Atan2(float64(to.Y), math.Hypot(float64(to.X), float64(to.Z)))
	buttons := game.ButtonAim
	if tick%12 == 0 {
		buttons |= game.ButtonFire
	}
	return game.NewInputCommand(0, 0, 0, float32(yaw), float32(pitch), buttons)
}

// The main test of combat over the network: two players on QUIC kill each
// other in turn at the open left edge of the map. The shooter's hits are
// confirmed and add up to the victim's health, the victim learns where they
// came from, both see the death in the feed with their names, the shots and
// the weapon of the shooter, and the hits on the victim. The dead one is not
// predicted, comes back as a new soldier at its spawn, and the other sees
// it come back. No prediction needs a correction.
func TestPlayersKillEachOtherAndComeBackOverQUIC(t *testing.T) {
	address := startTestServer(t, config.Server{MaxPlayers: 2, SnapshotRate: 20, RespawnDelay: 500 * time.Millisecond})
	players := [2]*testPlayer{newTestPlayer(t, address, "Alice"), newTestPlayer(t, address, "Bob")}
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	for round := range 2 {
		shooter, victim := players[round], players[1-round]
		play := func(what string, limit time.Duration, shoot func(tick int) game.InputCommand, done func() bool) {
			t.Helper()
			for tick, deadline := 0, time.Now().Add(limit); !done(); tick++ {
				if time.Now().After(deadline) {
					t.Fatalf("round %d: %s did not happen within %s", round, what, limit)
				}
				<-ticker.C
				shooter.tick(shoot(tick))
				victim.tick(toTheEdge(victim))
			}
		}
		walk := func(int) game.InputCommand { return toTheEdge(shooter) }
		play("standing at the edge", 4*time.Second, walk, func() bool {
			known := shooter.sees(victim)
			return shooter.predictor.started && shooter.predictor.soldier.Position.X <= edge && victim.sees(shooter) != nil &&
				known != nil && known.soldier.Position.X <= edge && horizontalSpeed(known.soldier.Velocity) == 0
		})
		shooter.events, victim.events, shooter.shots = nil, nil, 0
		dead := victim.session.player.Soldier
		victimTeam := shooter.sees(victim).soldier.Team
		play("the kill", 5*time.Second, func(tick int) game.InputCommand { return aimAt(shooter, victim, tick) },
			func() bool { return victim.session.player.Health == 0 })
		play("the news of it", time.Second, walk, func() bool { return len(deaths(shooter.events)) > 0 && len(deaths(victim.events)) > 0 })
		if victim.predictor.started {
			t.Errorf("round %d: the dead victim is still predicted", round)
		}
		dealt, hits, killed := 0, 0, false
		for _, event := range shooter.events {
			if hit, ok := event.(*protocol.HitConfirm); ok && hit.Victim == dead {
				dealt, hits, killed = dealt+int(hit.Damage), hits+1, hit.Killed
			}
		}
		if dealt != game.MaxHealth || !killed {
			t.Errorf("round %d: confirmed hits dealt %d, the last killed: %t", round, dealt, killed)
		}
		wounds := 0
		toShooter := shooter.predictor.soldier.Position.Sub(victim.session.localSoldier().Position)
		bearing := math.Atan2(float64(toShooter.X), float64(-toShooter.Z))
		for _, event := range victim.events {
			if damage, ok := event.(*protocol.Damage); ok {
				wounds++
				// The hit came from the shooter: against the shot's travel.
				from := float64(damage.Yaw)*2*math.Pi/256 + math.Pi
				if damage.Attacker != shooter.session.player.Soldier || math.Abs(math.Remainder(from-bearing, 2*math.Pi)) > 0.1 {
					t.Errorf("round %d: damage from %#04x towards %.2f rad, the shooter is at %.2f", round, damage.Attacker, from, bearing)
				}
			}
		}
		if wounds != hits {
			t.Errorf("round %d: %d hits confirmed, %d damages told", round, hits, wounds)
		}
		for i, heard := range [2][]protocol.Message{shooter.events, victim.events} {
			death := deaths(heard)
			if len(death) != 1 || death[0].Victim != dead || death[0].VictimName != players[1-round].session.name ||
				death[0].KillerName != players[round].session.name || death[0].Weapon != game.WeaponAssaultRifle ||
				death[0].VictimTeam != victimTeam {
				t.Errorf("round %d: player %d heard of deaths %+v", round, i, death)
			}
		}
		seen := victim.sees(shooter)
		if seen.soldier.Arsenal.Weapon() != game.WeaponAssaultRifle || int(seen.soldier.Shots) != shooter.shots&15 {
			t.Errorf("round %d: the victim saw %d shots of a %s, %d were fired", round, seen.soldier.Shots, seen.soldier.Arsenal.Weapon(), shooter.shots)
		}
		if known := shooter.session.soldiers[dead.Slot()]; known != nil && known.soldier.ID == dead &&
			(int(known.soldier.LastHit.Count) != hits&7 || game.HitboxZone(int(known.soldier.LastHit.Box)) != game.ZoneTorso) {
			t.Errorf("round %d: the shooter saw the last of %d hits as %+v", round, hits, known.soldier.LastHit)
		}
		play("the return", 2*time.Second, walk, func() bool {
			player := victim.session.player
			return player.Soldier != dead && player.Health == game.MaxHealth && victim.predictor.started
		})
		back := victim.predictor.soldier.Position
		if spawn := game.PrototypeScene().SpawnOf(victimTeam); math.Hypot(float64(back.X-spawn.X), float64(back.Z-spawn.Z)) > 1 {
			t.Errorf("round %d: the victim came back at %+v, its spawn is %+v", round, back, spawn)
		}
		play("the shooter seeing the return", time.Second, walk, func() bool { return shooter.sees(victim) != nil })
		if old := shooter.session.soldiers[dead.Slot()]; old != nil && old.soldier.ID == dead {
			t.Errorf("round %d: the shooter still knows the dead soldier", round)
		}
	}
	for i, p := range players {
		if p.predictor.corrections > 0 {
			t.Errorf("player %d had %d corrections", i, p.predictor.corrections)
		}
	}
}

func deaths(events []protocol.Message) []*protocol.Death {
	var all []*protocol.Death
	for _, event := range events {
		if death, ok := event.(*protocol.Death); ok {
			all = append(all, death)
		}
	}
	return all
}
