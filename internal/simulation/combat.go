package simulation

import (
	"fmt"
	"log"
	"math"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

// pendingShot is a shot fired this tick, resolved once every soldier has
// acted: a soldier killed in a tick still fires its shot of that tick, so
// two soldiers can kill each other. view is the moment, as a fractional
// tick, whose poses the shot is tested against.
type pendingShot struct {
	shooter game.SoldierID
	team    game.Team
	shot    game.Shot
	view    float64
}

// viewTime is the moment a human's shot is tested at (ARCHITECTURE.md, 6.9):
// what the player saw when it fired, no further back than the rewind limit,
// and the latest recorded tick for a player that says it saw now. The
// shooter itself is not moved back.
func (s *Server) viewTime(command game.InputCommand) float64 {
	latest := float64(s.tick) - 1
	view, ok := command.ViewTime()
	if !ok {
		return latest
	}
	oldest := float64(s.tick) - float64(s.settings.MaxRewind)/float64(game.TickDuration)
	return max(oldest, min(latest, view))
}

// hit is where a shot struck a soldier: which hitbox, how far away.
type hit struct {
	soldier  game.SoldierID
	box      int
	distance float32
}

// resolveShots tests every shot of the tick against the world and the
// soldiers, applies the damage and tells the people involved.
func (s *Server) resolveShots() error {
	for _, pending := range s.shots {
		struck, ok, err := s.hitscan(pending)
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		s.profile.hits++
		s.totalHits++
		victim := s.soldiers.Get(struck.soldier)
		if victim == nil || !victim.Alive || (victim.Team == pending.team && !s.settings.FriendlyFire) {
			continue
		}
		zone := game.HitboxZone(struck.box)
		direction := pending.shot.Direction
		victim.LastHit = game.HitMark{
			Count: victim.LastHit.Count + 1, Box: uint8(struck.box),
			Yaw: float32(math.Atan2(float64(direction.X), float64(-direction.Z))),
		}
		tuning := s.rules.Weapons.Get(pending.shot.Weapon)
		taken, killed := s.damage(victim, tuning.HitDamage(zone, struck.distance))
		s.tellHit(pending, victim, zone, taken, killed)
	}
	s.shots = s.shots[:0]
	return nil
}

// tellHit sends the events of a hit: the shooter learns it hit, the victim
// where from, and everyone a death a human took part in.
func (s *Server) tellHit(pending pendingShot, victim *game.Soldier, zone game.HitZone, taken int, killed bool) {
	shooter := s.soldiers.Get(pending.shooter)
	if p := s.playerOf(shooter); p != nil {
		s.sendEvent(p, &protocol.HitConfirm{Tick: s.tick, Victim: victim.ID, Zone: zone, Damage: uint8(min(taken, math.MaxUint8)), Killed: killed})
	}
	victimPlayer := s.playerOf(victim)
	if victimPlayer != nil {
		yaw := math.Atan2(float64(pending.shot.Direction.X), float64(-pending.shot.Direction.Z)) / (2 * math.Pi)
		s.sendEvent(victimPlayer, &protocol.Damage{
			Tick: s.tick, Attacker: pending.shooter, Yaw: uint8(int(math.Round(yaw*256)) & 0xFF),
			Zone: zone, Damage: uint8(min(taken, math.MaxUint8)),
		})
	}
	if !killed || (victimPlayer == nil && s.playerOf(shooter) == nil) {
		return
	}
	death := &protocol.Death{
		Tick: s.tick, Victim: victim.ID, Killer: pending.shooter, VictimTeam: victim.Team, KillerTeam: pending.team,
		VictimName: s.nameOf(victim), KillerName: s.nameOf(shooter), Weapon: pending.shot.Weapon, Zone: zone,
	}
	for _, p := range s.players {
		if p != nil && p.ready {
			s.sendEvent(p, death)
		}
	}
}

// playerOf is the player of a human soldier, or nil.
func (s *Server) playerOf(soldier *game.Soldier) *player {
	if soldier == nil || soldier.Controller.Kind != game.ControllerPlayer {
		return nil
	}
	if p := s.players[soldier.Controller.Player]; p != nil && p.soldier == soldier.ID {
		return p
	}
	return nil
}

// nameOf is how the kill feed calls a soldier.
func (s *Server) nameOf(soldier *game.Soldier) string {
	switch {
	case soldier == nil:
		return "?"
	case soldier.Controller.Kind == game.ControllerBot:
		return fmt.Sprintf("Dummy %d", soldier.Controller.Bot)
	}
	if p := s.players[soldier.Controller.Player]; p != nil {
		return p.name
	}
	return fmt.Sprintf("Player %d", soldier.Controller.Player)
}

// sendEvent sends an event on the reliable channel. A player who does not
// read its events is dropped: its queue is full.
func (s *Server) sendEvent(p *player, message protocol.Message) {
	data, err := message.Encode(nil)
	if err == nil {
		err = p.conn.SendReliable(transport.ChannelEvents, data)
	}
	if err != nil {
		log.Printf("player %d: event %s: %v", p.id, message.Type(), err)
		_ = p.conn.Close("events not delivered")
	}
}

// hitscan finds the soldier a shot strikes first, if any (ARCHITECTURE.md,
// 6.9): a ray through the static world and vehicles limits its reach, the
// grid gives the soldiers near its track, with a margin for how far they
// can have moved since the moment of the shot, and their hitboxes are
// tested where the pose history has them at that moment. A soldier that did
// not exist then cannot be hit: the player could not see it. A teammate
// stops a shot even without friendly fire.
func (s *Server) hitscan(pending pendingShot) (hit, bool, error) {
	shot := pending.shot
	reach := s.rules.Weapons.Get(shot.Weapon).Range
	wall, err := s.world.RayCast(physics.Ray{Origin: shot.Origin, Direction: shot.Direction, Distance: reach},
		physics.Mask(physics.LayerStatic, physics.LayerVehicle))
	if err != nil {
		return hit{}, false, err
	}
	if wall.Hit {
		reach *= wall.Fraction
	}
	// The grid has the soldiers at the end of the last tick; since the
	// moment of the shot they moved at most at a sprint, or a fall.
	since := float32(float64(s.tick)-pending.view) / game.TickRate
	margin := game.HitboxReach + 2*s.rules.Movement.SprintSpeed*since
	var struck hit
	for id := range s.grid.AlongRay(shot.Origin, shot.Direction, reach, margin) {
		target := s.soldiers.Get(id)
		if id == pending.shooter || target == nil || !target.Alive {
			continue
		}
		pose, ok := s.history.at(id, pending.view)
		if !ok || !pose.alive {
			continue
		}
		if distance, box, ok := game.RayHitboxes(shot.Origin, shot.Direction, reach, pose.position, pose.yaw); ok {
			reach, struck = distance, hit{soldier: id, box: box, distance: distance}
		}
	}
	return struck, struck.soldier != 0, nil
}

// damage takes health from a soldier; at zero it dies. A dead soldier stays
// where it fell until it comes back as a new soldier, so that every client
// sees it die. A dead human loses its capsule and its commands are ignored.
// It returns the health taken and whether the soldier died.
func (s *Server) damage(victim *game.Soldier, amount int) (int, bool) {
	if int(victim.Health) > amount {
		victim.Health -= uint8(amount)
		return amount, false
	}
	taken := int(victim.Health)
	victim.Health, victim.Alive, victim.Velocity = 0, false, physics.Vec3{}
	s.profile.kills++
	back := s.tick + game.Tick(s.settings.RespawnDelay/game.TickDuration)
	switch victim.Controller.Kind {
	case game.ControllerPlayer:
		if p := s.players[victim.Controller.Player]; p != nil && p.soldier == victim.ID {
			if p.controller != nil {
				_ = p.controller.Close()
				p.controller = nil
			}
			p.respawnAt = back
		}
	case game.ControllerBot:
		if bot := int(victim.Controller.Bot); bot < len(s.dummies.all) {
			s.dummies.all[bot].respawnAt = back
		}
	}
	return taken, true
}

// respawnDead brings back the soldiers whose time has come: each as a new
// soldier, whom clients do not mistake for the one that died.
func (s *Server) respawnDead() error {
	for _, p := range s.players {
		if p == nil || p.soldier == 0 {
			continue
		}
		if soldier := s.soldiers.Get(p.soldier); soldier.Alive || int32(s.tick-p.respawnAt) < 0 {
			continue
		}
		s.soldiers.Remove(p.soldier)
		p.soldier = 0
		if err := s.spawn(p); err != nil {
			return err
		}
	}
	for i := range s.dummies.all {
		d := &s.dummies.all[i]
		if soldier := s.soldiers.Get(d.soldier); soldier.Alive || int32(s.tick-d.respawnAt) < 0 {
			continue
		}
		team := s.soldiers.Get(d.soldier).Team
		s.soldiers.Remove(d.soldier)
		if err := s.spawnDummy(i, team); err != nil {
			return err
		}
	}
	return nil
}
