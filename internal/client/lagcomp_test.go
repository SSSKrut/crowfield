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

// The player aims at the body of an enemy dummy where it is drawn, between
// snapshots in the past, and fires single rounds of a rifle that neither
// scatters nor kicks. Every round that leaves the barrel with a clear line
// must hit.
func TestShotsAtDrawnDummiesHit(t *testing.T) {
	for _, conditions := range []transport.NetworkConditions{
		{},
		{Delay: 100 * time.Millisecond, Jitter: 15 * time.Millisecond, Loss: 0.03, Seed: 5},
	} {
		rules := game.DefaultRules()
		rifle := &rules.Weapons.Rifle
		rifle.HipSpread, rifle.AimSpread, rifle.MoveSpread, rifle.AirSpread, rifle.Bloom, rifle.KickPitch, rifle.KickYaw = 0, 0, 0, 0, 0, 0, 0
		local, err := startLocalServer(rules, config.Client{Dummies: 48})
		if err != nil {
			t.Fatal(err)
		}
		conn, err := local.dial()
		if err != nil {
			t.Fatal(err)
		}
		if conditions != (transport.NetworkConditions{}) {
			conn = transport.Simulate(conn, conditions)
		}
		player := &testPlayer{t: t}
		if player.session, err = connect(conn, "aimer", rules, [16]byte{}); err != nil {
			t.Fatal(err)
		}
		if player.predictor, err = newPredictor(sceneWorld(t), rules); err != nil {
			t.Fatal(err)
		}
		player.predictor.join(player.session.welcome.MatchSeed)
		world := sceneWorld(t)
		ticker := time.NewTicker(game.TickDuration)
		shots, clear := 0, 0
		reach := float32(0)
		for tick := range 12 * game.TickRate {
			<-ticker.C
			command := game.InputCommand{Weapon: 1}
			if eye, target, ok := player.enemyInView(rules); ok && tick > game.TickRate {
				reach = distance(eye, target)
				to := target.Sub(eye)
				yaw := math.Atan2(float64(to.X), float64(-to.Z))
				pitch := math.Atan2(float64(to.Y), math.Hypot(float64(to.X), float64(to.Z)))
				buttons := game.Buttons(0)
				if tick%10 == 0 {
					buttons = game.ButtonFire
				}
				command = game.NewInputCommand(0, 0, 0, float32(yaw), float32(pitch), buttons)
				command.Weapon = 1
			}
			fired := player.tickReporting(command)
			if fired != nil {
				shots++
				if hit, _ := world.RayCast(physics.Ray{Origin: fired.Origin, Direction: fired.Direction, Distance: reach},
					physics.Mask(physics.LayerStatic)); !hit.Hit {
					clear++
				}
			}
		}
		ticker.Stop()
		player.session.close()
		_ = player.predictor.close()
		if err := local.stop(); err != nil {
			t.Error(err)
		}
		hits := int(local.server.Hits())
		t.Logf("%s: %d shots, %d with a clear line, %d hits", conditions, shots, clear, hits)
		// A lost snapshot leaves the target drawn by its velocity for a moment,
		// while it may turn: a shot now and then misses on a lossy network.
		if shots < 20 || hits < clear*9/10 {
			t.Errorf("%s: %d hits of %d shots with a clear line", conditions, hits, clear)
		}
	}
}

// enemyInView is the eye and the body of the nearest enemy dummy within 25 m
// where the client draws it now.
func (p *testPlayer) enemyInView(rules game.Rules) (physics.Vec3, physics.Vec3, bool) {
	own := p.session.localSoldier()
	if own == nil || !p.predictor.started {
		return physics.Vec3{}, physics.Vec3{}, false
	}
	eye := p.predictor.soldier.Position.Add(physics.V(0, rules.Movement.EyeHeight, 0))
	best, found := float32(25), physics.Vec3{}
	for _, known := range p.session.soldiers {
		if known.soldier.ID == own.ID || known.soldier.Team == own.Team || known.remote.count == 0 {
			continue
		}
		drawn := known.remote.at(p.session.clock.renderTick)
		if !drawn.Alive {
			continue
		}
		if d := distance(drawn.Position, p.predictor.soldier.Position); d < best && d > 3 {
			best, found = d, drawn.Position.Add(physics.V(0, 0.85, 0))
		}
	}
	return eye, found, found != physics.Vec3{}
}

// tickReporting plays a tick like tick and returns the shot it fired.
func (p *testPlayer) tickReporting(command game.InputCommand) *game.Shot {
	command, err := p.session.sendCommand(command)
	if err != nil {
		p.t.Fatal(err)
	}
	step, err := p.predictor.predict(command)
	if err != nil {
		p.t.Fatal(err)
	}
	if updated, err := p.session.poll(); err != nil {
		p.t.Fatal(err)
	} else if updated {
		if err := p.predictor.reconcile(p.session.player); err != nil {
			p.t.Fatal(err)
		}
	}
	p.session.clock.advance(game.TickDelta)
	if step.Events.Has(game.EventFired) {
		return &step.Shot
	}
	return nil
}
