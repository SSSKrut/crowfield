package game

import (
	"iter"
	"math"

	"ravenfield/internal/physics"
)

// SoldierGrid buckets soldiers by horizontal position, so that neighbour
// queries look at a few cells instead of every soldier. It is rebuilt each
// tick; the buckets keep their memory between rebuilds.
type SoldierGrid struct {
	cellSize float32
	cells    map[gridCell][]gridEntry
}

type gridCell struct {
	x, z int32
}

type gridEntry struct {
	id       SoldierID
	position physics.Vec3
}

func NewSoldierGrid(cellSize float32) *SoldierGrid {
	return &SoldierGrid{cellSize: cellSize, cells: make(map[gridCell][]gridEntry)}
}

func (g *SoldierGrid) Rebuild(soldiers *SoldierSet) {
	for cell, entries := range g.cells {
		g.cells[cell] = entries[:0]
	}
	for soldier := range soldiers.All() {
		cell := g.cell(soldier.Position)
		g.cells[cell] = append(g.cells[cell], gridEntry{id: soldier.ID, position: soldier.Position})
	}
}

// Near yields the soldiers within radius of position, measured horizontally,
// with the positions they had at the last rebuild.
func (g *SoldierGrid) Near(position physics.Vec3, radius float32) iter.Seq2[SoldierID, physics.Vec3] {
	return func(yield func(SoldierID, physics.Vec3) bool) {
		low := g.cell(position.Sub(physics.V(radius, 0, radius)))
		high := g.cell(position.Add(physics.V(radius, 0, radius)))
		for x := low.x; x <= high.x; x++ {
			for z := low.z; z <= high.z; z++ {
				for _, entry := range g.cells[gridCell{x, z}] {
					dx, dz := entry.position.X-position.X, entry.position.Z-position.Z
					if dx*dx+dz*dz <= radius*radius && !yield(entry.id, entry.position) {
						return
					}
				}
			}
		}
	}
}

func (g *SoldierGrid) cell(position physics.Vec3) gridCell {
	return gridCell{
		x: int32(math.Floor(float64(position.X / g.cellSize))),
		z: int32(math.Floor(float64(position.Z / g.cellSize))),
	}
}
