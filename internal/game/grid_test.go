package game

import (
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
