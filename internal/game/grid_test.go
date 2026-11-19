package game

import (
	"math"
	"math/rand/v2"
	"testing"

	"ravenfield/internal/physics"
)

func TestSoldierGridFindsExactlyTheNeighbours(t *testing.T) {
	random := rand.New(rand.NewPCG(8, 9))
	soldiers, err := NewSoldierSet(300)
	if err != nil {
		t.Fatal(err)
	}
	for range 300 {
		position := physics.V(random.Float32()*100-50, random.Float32()*3, random.Float32()*100-50)
		if _, err := soldiers.Add(Soldier{Position: position}); err != nil {
			t.Fatal(err)
		}
	}
	grid := NewSoldierGrid(8)
	grid.Rebuild(soldiers)
	for range 200 {
		center := physics.V(random.Float32()*120-60, 0, random.Float32()*120-60)
		radius := random.Float32() * 20
		want := map[SoldierID]bool{}
		for soldier := range soldiers.All() {
			dx, dz := soldier.Position.X-center.X, soldier.Position.Z-center.Z
			if dx*dx+dz*dz <= radius*radius {
				want[soldier.ID] = true
			}
		}
		found := 0
		for id, position := range grid.Near(center, radius) {
			if !want[id] || soldiers.Get(id).Position != position {
				t.Fatalf("near %+v within %.1f: unexpected %#04x at %+v", center, radius, id, position)
			}
			found++
		}
		if found != len(want) {
			t.Fatalf("near %+v within %.1f: found %d of %d", center, radius, found, len(want))
		}
	}
}

// AlongRay finds exactly the soldiers within the margin of a ray's track,
// whatever its direction and length, including rays that start outside the
// occupied part of the grid or stand straight up.
func TestSoldierGridFindsExactlyTheSoldiersAlongARay(t *testing.T) {
	random := rand.New(rand.NewPCG(3, 4))
	soldiers, err := NewSoldierSet(300)
	if err != nil {
		t.Fatal(err)
	}
	for range 300 {
		position := physics.V(random.Float32()*100-50, random.Float32()*3, random.Float32()*100-50)
		if _, err := soldiers.Add(Soldier{Position: position}); err != nil {
			t.Fatal(err)
		}
	}
	grid := NewSoldierGrid(8)
	grid.Rebuild(soldiers)
	for i := range 500 {
		origin := physics.V(random.Float32()*200-100, 1, random.Float32()*200-100)
		direction := ViewDirection(random.Float32()*7, random.Float32()*2-1)
		if i%50 == 0 {
			direction = physics.V(0, 1, 0)
		}
		length := random.Float32() * 150
		margin := random.Float32() * 10
		want := map[SoldierID]bool{}
		flat := float32(math.Hypot(float64(direction.X), float64(direction.Z)))
		for soldier := range soldiers.All() {
			dx, dz := soldier.Position.X-origin.X, soldier.Position.Z-origin.Z
			along := float32(0)
			if flat > 1e-6 {
				along = max(0, min(length*flat, (dx*direction.X+dz*direction.Z)/flat))
				dx, dz = dx-direction.X/flat*along, dz-direction.Z/flat*along
			}
			if dx*dx+dz*dz <= margin*margin {
				want[soldier.ID] = true
			}
		}
		found := map[SoldierID]bool{}
		for id := range grid.AlongRay(origin, direction, length, margin) {
			if !want[id] || found[id] {
				t.Fatalf("ray %d: unexpected or repeated %#04x", i, id)
			}
			found[id] = true
		}
		if len(found) != len(want) {
			t.Fatalf("ray %d from %+v along %+v for %.1f within %.1f: found %d of %d",
				i, origin, direction, length, margin, len(found), len(want))
		}
	}
}
