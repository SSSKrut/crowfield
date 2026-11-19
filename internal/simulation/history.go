package simulation

import (
	"math"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

// historyTicks keeps a second of poses: more than the 200 ms limit of lag
// compensation and the reaction delay of bots, which both look into the past.
const historyTicks = game.TickRate

// pose is what a hit test needs of a soldier at one tick.
type pose struct {
	tick     game.Tick
	soldier  game.SoldierID
	position physics.Vec3
	yaw      float32
	pitch    float32
	alive    bool
}

// poseHistory records every soldier at the end of every tick, by slot.
type poseHistory struct {
	slots [][historyTicks]pose
}

func newPoseHistory(capacity int) *poseHistory {
	return &poseHistory{slots: make([][historyTicks]pose, capacity)}
}

func (h *poseHistory) record(tick game.Tick, soldiers *game.SoldierSet) {
	for soldier := range soldiers.All() {
		h.slots[soldier.ID.Slot()][tick%historyTicks] = pose{
			tick: tick, soldier: soldier.ID, position: soldier.Position,
			yaw: soldier.Yaw, pitch: soldier.Pitch, alive: soldier.Alive,
		}
	}
}

// at returns a soldier's pose at a fractional tick, between the two recorded
// ticks around it. It fails for times not recorded, or recorded for another
// soldier that had the same slot.
func (h *poseHistory) at(id game.SoldierID, tick float64) (pose, bool) {
	whole := game.Tick(math.Floor(tick))
	earlier, ok := h.recorded(id, whole)
	if !ok {
		return pose{}, false
	}
	fraction := float32(tick - math.Floor(tick))
	if fraction == 0 {
		return earlier, true
	}
	later, ok := h.recorded(id, whole+1)
	if !ok {
		return pose{}, false
	}
	earlier.position = earlier.position.Add(later.position.Sub(earlier.position).Mul(fraction))
	earlier.yaw += float32(math.Remainder(float64(later.yaw-earlier.yaw), 2*math.Pi)) * fraction
	earlier.pitch += (later.pitch - earlier.pitch) * fraction
	return earlier, true
}

func (h *poseHistory) recorded(id game.SoldierID, tick game.Tick) (pose, bool) {
	if id.Slot() >= len(h.slots) {
		return pose{}, false
	}
	recorded := h.slots[id.Slot()][tick%historyTicks]
	return recorded, recorded.soldier == id && recorded.tick == tick
}
