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
	// low and high bound the occupied cells; visited serves AlongRay.
	low, high gridCell
	occupied  bool
	visited   map[gridCell]struct{}
}

type gridCell struct {
	x, z int32
}

type gridEntry struct {
	id       SoldierID
	position physics.Vec3
}

func NewSoldierGrid(cellSize float32) *SoldierGrid {
	return &SoldierGrid{cellSize: cellSize, cells: make(map[gridCell][]gridEntry), visited: make(map[gridCell]struct{})}
}

func (g *SoldierGrid) Rebuild(soldiers *SoldierSet) {
	for cell, entries := range g.cells {
		g.cells[cell] = entries[:0]
	}
	g.occupied = false
	for soldier := range soldiers.All() {
		cell := g.cell(soldier.Position)
		g.cells[cell] = append(g.cells[cell], gridEntry{id: soldier.ID, position: soldier.Position})
		if !g.occupied {
			g.low, g.high, g.occupied = cell, cell, true
		}
		g.low = gridCell{min(g.low.x, cell.x), min(g.low.z, cell.z)}
		g.high = gridCell{max(g.high.x, cell.x), max(g.high.z, cell.z)}
	}
}

// AlongRay yields the soldiers whose positions at the last rebuild lie
// within margin of the horizontal track of a ray from origin along the unit
// direction, as far as length; the margin must not exceed half a cell. It
// walks the cells along the track, half a cell at a time, and only through
// the occupied part of the grid.
func (g *SoldierGrid) AlongRay(origin, direction physics.Vec3, length, margin float32) iter.Seq2[SoldierID, physics.Vec3] {
	return func(yield func(SoldierID, physics.Vec3) bool) {
		flat := float32(math.Hypot(float64(direction.X), float64(direction.Z)))
		if !g.occupied {
			return
		}
		if flat < 1e-6 {
			for id, position := range g.Near(origin, margin) {
				if !yield(id, position) {
					return
				}
			}
			return
		}
		ux, uz := direction.X/flat, direction.Z/flat
		reach := length * flat
		// Clip the track to the occupied cells, widened by the margin.
		start, end := float32(0), reach
		for axis, from := range [2]float32{origin.X, origin.Z} {
			u := [2]float32{ux, uz}[axis]
			lowEdge := float32([2]int32{g.low.x, g.low.z}[axis])*g.cellSize - margin
			highEdge := float32([2]int32{g.high.x, g.high.z}[axis]+1)*g.cellSize + margin
			if math.Abs(float64(u)) < 1e-9 {
				if from < lowEdge || from > highEdge {
					return
				}
				continue
			}
			first, second := (lowEdge-from)/u, (highEdge-from)/u
			start, end = max(start, min(first, second)), min(end, max(first, second))
		}
		if start > end {
			return
		}
		clear(g.visited)
		step := g.cellSize / 2
		box := margin + step/2
		for along := start; ; along += step {
			along = min(along, end)
			x, z := origin.X+ux*along, origin.Z+uz*along
			low := g.cell(physics.V(x-box, 0, z-box))
			high := g.cell(physics.V(x+box, 0, z+box))
			for cx := low.x; cx <= high.x; cx++ {
				for cz := low.z; cz <= high.z; cz++ {
					cell := gridCell{cx, cz}
					if _, seen := g.visited[cell]; seen {
						continue
					}
					g.visited[cell] = struct{}{}
					for _, entry := range g.cells[cell] {
						// The distance from the track, clamped to its ends.
						dx, dz := entry.position.X-origin.X, entry.position.Z-origin.Z
						t := max(0, min(reach, dx*ux+dz*uz))
						ex, ez := dx-ux*t, dz-uz*t
						if ex*ex+ez*ez <= margin*margin && !yield(entry.id, entry.position) {
							return
						}
					}
				}
			}
			if along >= end {
				return
			}
		}
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
