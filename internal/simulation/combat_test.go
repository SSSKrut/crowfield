package simulation

import (
	"math"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

// rangeTest is a server with one player, the shooter, whose assault rifle
// neither scatters nor kicks, and bots placed by hand as targets.
type rangeTest struct {
	t       *testing.T
	server  *Server
	shooter *player
	client  *testReceiver
}

func newRangeTest(t *testing.T, settings config.Server) *rangeTest {
	t.Helper()
	rules := game.DefaultRules()
	rifle := &rules.Weapons.AssaultRifle
	rifle.HipSpread, rifle.MoveSpread, rifle.Bloom, rifle.KickPitch, rifle.KickYaw = 0, 0, 0, 0, 0
	// Places of players that never join leave slots for the targets.
	settings.MaxPlayers, settings.SnapshotRate = 4, 20
	server, err := NewServer(settings, rules)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	client := addReceiver(t, server, 0, 0, 0)
	r := &rangeTest{t: t, server: server, shooter: client.player, client: client}
	r.idle(10)
	return r
}

// target puts a bot soldier of a team on the range.
func (r *rangeTest) target(team game.Team, position physics.Vec3) game.SoldierID {
	r.t.Helper()
	id, err := r.server.soldiers.Add(game.Soldier{
		Team: team, Controller: game.BotController(999), Alive: true, Grounded: true, Position: position, Health: game.MaxHealth,
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return id
}

// fire shoots once at a point and waits for the weapon to be ready again.
func (r *rangeTest) fire(at physics.Vec3) {
	r.t.Helper()
	s := r.server
	eye := s.soldiers.Get(r.shooter.soldier).Position.Add(physics.V(0, s.rules.Movement.EyeHeight, 0))
	to := at.Sub(eye)
	yaw := math.Atan2(float64(to.X), float64(-to.Z))
	pitch := math.Atan2(float64(to.Y), math.Hypot(float64(to.X), float64(to.Z)))
	r.shooter.inputs.put(game.NewInputCommand(s.tick, 0, 0, float32(yaw), float32(pitch), game.ButtonFire), s.tick)
	// The trigger is released at the next tick: without a command the server
	// repeats the last one, and an assault rifle would keep firing.
	r.shooter.inputs.put(game.NewInputCommand(s.tick+1, 0, 0, float32(yaw), float32(pitch), 0), s.tick)
	r.idle(s.rules.Weapons.AssaultRifle.FireInterval())
}

// idle runs ticks without commands: the soldiers stand.
func (r *rangeTest) idle(ticks int) {
	r.t.Helper()
	for range ticks {
		if err := r.server.step(); err != nil {
			r.t.Fatal(err)
		}
		r.client.receive()
	}
}

func (r *rangeTest) health(id game.SoldierID) int {
	return int(r.server.soldiers.Get(id).Health)
}

// Shots at the head, the body and a leg of an enemy eight metres away take
// the damage of those zones.
func TestShotsHitTheZoneAimedAt(t *testing.T) {
	r := newRangeTest(t, config.Server{})
	target := r.target(game.TeamRed, physics.V(0, 0, -1))
	r.idle(2)
	for _, c := range []struct {
		name   string
		aim    physics.Vec3
		damage int
	}{{"head", physics.V(0, 1.5, -1), 50}, {"body", physics.V(0, 0.85, -1), 25}, {"leg", physics.V(0.26, 0.3, -1), 19}} {
		before := r.health(target)
		r.fire(c.aim)
		if taken := before - r.health(target); taken != c.damage {
			t.Errorf("a shot at the %s took %d health, want %d", c.name, taken, c.damage)
		}
	}
	r.fire(physics.V(1.5, 0.85, -1))
	if r.health(target) != 100-50-25-19 {
		t.Errorf("a shot beside the target hurt it: health %d", r.health(target))
	}
}

// The column between the shooter and the target stops the shot.
func TestWallsStopShots(t *testing.T) {
	r := newRangeTest(t, config.Server{})
	hidden := r.target(game.TeamRed, physics.V(0, 0, -6))
	r.idle(2)
	r.fire(physics.V(0, 0.85, -6))
	if r.health(hidden) != game.MaxHealth {
		t.Errorf("a shot through the column took %d health", game.MaxHealth-r.health(hidden))
	}
	if r.server.profile.hits != 0 {
		t.Errorf("%d hits through a wall", r.server.profile.hits)
	}
}

// Without friendly fire a teammate takes no damage, and still stops the shot
// that would hit the enemy behind it; with it, the teammate is hurt.
func TestTeammatesShieldButAreSpared(t *testing.T) {
	for _, friendlyFire := range []bool{false, true} {
		r := newRangeTest(t, config.Server{FriendlyFire: friendlyFire})
		team := r.server.soldiers.Get(r.shooter.soldier).Team
		enemy := game.TeamRed
		if team == game.TeamRed {
			enemy = game.TeamBlue
		}
		friend := r.target(team, physics.V(0, 0, 2))
		behind := r.target(enemy, physics.V(0, 0, -1))
		r.idle(2)
		r.fire(physics.V(0, 0.85, -1))
		want := game.MaxHealth
		if friendlyFire {
			want -= 25
		}
		if r.health(friend) != want || r.health(behind) != game.MaxHealth {
			t.Errorf("friendly fire %t: the teammate has %d health, the enemy behind it %d", friendlyFire, r.health(friend), r.health(behind))
		}
	}
}

// A dead dummy stays where it fell, shots pass it, and it comes back after
// the delay as a new soldier of its team.
func TestDeadDummyComesBackAsANewSoldier(t *testing.T) {
	r := newRangeTest(t, config.Server{Dummies: 3, RespawnDelay: 500 * time.Millisecond})
	s := r.server
	d := &s.dummies.all[0]
	dead := d.soldier
	s.damage(s.soldiers.Get(dead), 60)
	if corpse := s.soldiers.Get(dead); !corpse.Alive || corpse.Health != 40 {
		t.Fatalf("after 60 damage the dummy is %+v", corpse)
	}
	s.damage(s.soldiers.Get(dead), 40)
	corpse := *s.soldiers.Get(dead)
	if corpse.Alive || corpse.Health != 0 || s.profile.kills != 1 {
		t.Fatalf("after 100 damage the dummy is %+v, %d kills", corpse, s.profile.kills)
	}
	r.idle(1)
	r.fire(corpse.Position.Add(physics.V(0, 0.85, 0)))
	r.idle(int(500*time.Millisecond/game.TickDuration) - 2 - s.rules.Weapons.AssaultRifle.FireInterval())
	if now := s.soldiers.Get(dead); now == nil || now.Position != corpse.Position || s.profile.hits != 0 {
		t.Fatalf("before the delay the dead dummy is %+v, %d hits", now, s.profile.hits)
	}
	r.idle(2)
	if s.soldiers.Get(dead) != nil {
		t.Fatal("the dead soldier is still there after the delay")
	}
	back := s.soldiers.Get(d.soldier)
	if back == nil || back.ID == dead || !back.Alive || back.Health != game.MaxHealth || back.Team != corpse.Team {
		t.Errorf("the dummy came back as %+v", back)
	}
}

// A dead player stops moving and shooting, has no capsule and is told when
// it returns; then it gets a new soldier at its team's spawn.
func TestDeadPlayerWaitsAndRespawns(t *testing.T) {
	r := newRangeTest(t, config.Server{RespawnDelay: time.Second})
	s := r.server
	p := r.shooter
	dead := p.soldier
	s.damage(s.soldiers.Get(dead), 1000)
	if p.controller != nil || s.soldiers.Get(dead).Alive {
		t.Fatal("the dead player kept its capsule")
	}
	fell := s.soldiers.Get(dead).Position
	for range game.TickRate / 2 {
		p.inputs.put(game.NewInputCommand(s.tick, 1, 0, 0, 0, game.ButtonFire|game.ButtonSprint), s.tick)
		r.idle(1)
	}
	if moved := s.soldiers.Get(dead).Position; moved != fell || s.profile.shots != 0 {
		t.Errorf("the dead moved to %+v and fired %d shots", moved, s.profile.shots)
	}
	if !p.processed || p.lastProcessed != s.tick-1 {
		t.Error("the commands of the dead no longer keep the clock")
	}
	private := r.client.private
	if private.Soldier != dead || private.Health != 0 || private.Respawn == 0 || private.Respawn > game.TickRate/2+1 {
		t.Errorf("the dead player is told health %d, respawn in %d ticks", private.Health, private.Respawn)
	}
	r.idle(game.TickRate/2 + 1)
	back := s.soldiers.Get(p.soldier)
	if back == nil || back.ID == dead || !back.Alive || back.Health != game.MaxHealth || p.controller == nil {
		t.Fatalf("the player came back as %+v", back)
	}
	if spawn := s.scene.SpawnOf(back.Team); distance(back.Position, spawn) > 0.5 {
		t.Errorf("came back at %+v, the spawn is %+v", back.Position, spawn)
	}
}

// A target walks across the line of fire. A shot made by a player who saw it
// ten ticks ago, aimed where it was then, hits; aimed where it is now, it
// misses. A player who claims to have seen it a second ago is tested at the
// rewind limit.
func TestShotsAreTestedWhereThePlayerSawTheTarget(t *testing.T) {
	r := newRangeTest(t, config.Server{MaxRewind: 300 * time.Millisecond})
	s := r.server
	// The open floor between the steps and the ramp.
	target := r.target(game.TeamRed, physics.V(-3.5, 0, 4))
	walk := func(ticks int) {
		for range ticks {
			soldier := s.soldiers.Get(target)
			soldier.Position.X += 5 * game.TickDelta
			soldier.Velocity = physics.V(5, 0, 0)
			r.idle(1)
		}
	}
	walk(game.TickRate)
	at := func(back int) physics.Vec3 {
		pose, ok := s.history.at(target, float64(s.tick)-float64(back))
		if !ok {
			t.Fatalf("no pose %d ticks back", back)
		}
		return pose.position.Add(physics.V(0, 0.85, 0))
	}
	for _, c := range []struct {
		name     string
		saw, aim int
		hit      bool
	}{
		{"where it was seen", 10, 10, true},
		{"where it is now", 10, 1, false},
		{"far in the past", 60, 60, false},
		{"at the limit", 60, 18, true},
	} {
		before := r.health(target)
		r.fireSeeing(at(c.aim), c.saw)
		if hit := r.health(target) < before; hit != c.hit {
			t.Errorf("%s: hit %t, want %t", c.name, hit, c.hit)
		}
		walk(1)
	}
}

// fireSeeing shoots once at a point, by a player who saw the world the
// given number of ticks before its command.
func (r *rangeTest) fireSeeing(at physics.Vec3, back int) {
	r.t.Helper()
	s := r.server
	eye := s.soldiers.Get(r.shooter.soldier).Position.Add(physics.V(0, s.rules.Movement.EyeHeight, 0))
	to := at.Sub(eye)
	yaw := math.Atan2(float64(to.X), float64(-to.Z))
	pitch := math.Atan2(float64(to.Y), math.Hypot(float64(to.X), float64(to.Z)))
	command := game.NewInputCommand(s.tick, 0, 0, float32(yaw), float32(pitch), game.ButtonFire)
	command.ViewDelta = uint8(back)
	r.shooter.inputs.put(command, s.tick)
	release := game.NewInputCommand(s.tick+1, 0, 0, float32(yaw), float32(pitch), 0)
	r.shooter.inputs.put(release, s.tick)
	r.idle(1)
	soldier := s.soldiers.Get(r.shooter.soldier)
	soldier.Arsenal.Cooldown = 0
}
