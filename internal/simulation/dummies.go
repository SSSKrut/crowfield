package simulation

import (
	"math"
	"math/rand/v2"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

const (
	// A dummy steps over this much, like the stairs; anything taller blocks it.
	dummyStepHeight = 0.5
	dummyDropHeight = 1
	// Dummies keep this far from each other.
	dummySpacing = 1.2
)

// dummy is a bot soldier without AI: it walks to random points of the map, so
// that networking and drawing meet many soldiers before real bots exist. It has
// no physics capsule; one batched ray per dummy finds the ground under it.
type dummy struct {
	soldier game.SoldierID
	target  physics.Vec3
}

type dummies struct {
	all    []dummy
	random *rand.Rand
	speed  float32
	area   float32
	rays   []physics.Ray
	hits   []physics.RayHit
	moves  []physics.Vec3
}

func (s *Server) spawnDummies(count int) error {
	s.dummies = dummies{
		random: rand.New(rand.NewPCG(s.matchSeed, s.matchSeed^0xD0D0)),
		speed:  s.rules.Movement.WalkSpeed, area: s.scene.PlayArea,
	}
	for i := range count {
		team := game.TeamBlue
		if i%2 == 1 {
			team = game.TeamRed
		}
		position, err := s.floorPoint()
		if err != nil {
			return err
		}
		id, err := s.soldiers.Add(game.Soldier{
			Team: team, Controller: game.BotController(game.BotID(i)), Alive: true, Grounded: true,
			Position: position, Arsenal: game.NewArsenal(game.DefaultLoadout(), &s.rules.Weapons),
		})
		if err != nil {
			return err
		}
		s.dummies.all = append(s.dummies.all, dummy{soldier: id, target: s.dummies.openPoint(s.scene.Spawn)})
	}
	return nil
}

// floorPoint picks a random spawn point for a dummy on the open floor: not
// inside an obstacle and not on top of one, where it could not leave.
func (s *Server) floorPoint() (physics.Vec3, error) {
	for {
		point := s.dummies.openPoint(s.scene.Spawn)
		hit, err := s.world.RayCast(physics.Ray{
			Origin: point.Add(physics.V(0, 10, 0)), Direction: physics.V(0, -1, 0), Distance: 11,
		}, physics.Mask(physics.LayerStatic))
		if err != nil {
			return physics.Vec3{}, err
		}
		if hit.Hit && hit.Position.Y < 0.05 {
			point.Y = hit.Position.Y
			return point, nil
		}
	}
}

// openPoint picks a random point of the play area away from the spawn of the
// players. A target may lie in an obstacle: the dummy turns away when it gets there.
func (d *dummies) openPoint(spawn physics.Vec3) physics.Vec3 {
	for {
		point := physics.V((d.random.Float32()*2-1)*d.area, 0, (d.random.Float32()*2-1)*d.area)
		if dx, dz := point.X-spawn.X, point.Z-spawn.Z; dx*dx+dz*dz > 4 {
			return point
		}
	}
}

// moveDummies walks every dummy towards its target and away from its
// neighbours, then casts all ground rays in one batch. A ray that starts inside
// geometry means a wall, and no ground within the drop means a ledge: either
// way the dummy stays and picks another target.
func (s *Server) moveDummies() error {
	d := &s.dummies
	d.rays, d.moves = d.rays[:0], d.moves[:0]
	for i := range d.all {
		soldier := s.soldiers.Get(d.all[i].soldier)
		toTarget := d.all[i].target.Sub(soldier.Position)
		toTarget.Y = 0
		if length := horizontalLength(toTarget); length < 0.5 {
			d.all[i].target = d.openPoint(s.scene.Spawn)
			toTarget = d.all[i].target.Sub(soldier.Position)
			toTarget.Y = 0
		}
		direction := toTarget.Mul(1 / max(horizontalLength(toTarget), 1e-6))
		for id, position := range s.grid.Near(soldier.Position, dummySpacing) {
			away := soldier.Position.Sub(position)
			away.Y = 0
			if distance := horizontalLength(away); id != soldier.ID && distance > 1e-3 {
				direction = direction.Add(away.Mul((dummySpacing - distance) / (dummySpacing * distance)))
			}
		}
		velocity := direction.Mul(d.speed / max(horizontalLength(direction), 1e-6))
		next := soldier.Position.Add(velocity.Mul(game.TickDelta))
		next.X = max(-d.area, min(d.area, next.X))
		next.Z = max(-d.area, min(d.area, next.Z))
		d.moves = append(d.moves, next)
		d.rays = append(d.rays, physics.Ray{
			Origin: next.Add(physics.V(0, dummyStepHeight, 0)), Direction: physics.V(0, -1, 0),
			Distance: dummyStepHeight + dummyDropHeight,
		})
		soldier.Yaw = float32(math.Atan2(float64(velocity.X), float64(-velocity.Z)))
	}
	if cap(d.hits) < len(d.rays) {
		d.hits = make([]physics.RayHit, len(d.rays))
	}
	d.hits = d.hits[:len(d.rays)]
	if err := s.world.RayCastBatch(d.rays, physics.Mask(physics.LayerStatic), d.hits); err != nil {
		return err
	}
	for i := range d.all {
		soldier := s.soldiers.Get(d.all[i].soldier)
		hit := d.hits[i]
		if !hit.Hit || hit.Fraction == 0 {
			soldier.Velocity = physics.Vec3{}
			d.all[i].target = d.openPoint(s.scene.Spawn)
			continue
		}
		next := d.moves[i]
		next.Y = hit.Position.Y
		soldier.Velocity = next.Sub(soldier.Position).Mul(game.TickRate)
		soldier.Position = next
	}
	return nil
}

func horizontalLength(v physics.Vec3) float32 {
	return float32(math.Hypot(float64(v.X), float64(v.Z)))
}
