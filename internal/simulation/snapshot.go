package simulation

import (
	"log"
	"slices"

	"ravenfield/internal/network/protocol"
)

// sendSnapshots sends every ready player the full state of the tick. A
// snapshot that does not fit one datagram is split; every part carries the
// private state, so each decodes on its own. Removals go in the first part.
func (s *Server) sendSnapshots() {
	s.states = s.states[:0]
	for soldier := range s.soldiers.All() {
		state, err := protocol.NewSoldierState(soldier)
		if err != nil {
			log.Printf("soldier left out of the snapshot: %v", err)
			continue
		}
		s.states = append(s.states, state)
	}
	s.removed = slices.DeleteFunc(s.removed, func(r removal) bool { return r.until <= s.tick })
	s.removedID = s.removedID[:0]
	for _, r := range s.removed[:min(len(s.removed), protocol.MaxSnapshotRemoved)] {
		s.removedID = append(s.removedID, r.soldier)
	}
	for _, p := range s.players {
		if p != nil && p.ready {
			s.sendSnapshot(p)
		}
	}
}

func (s *Server) sendSnapshot(p *player) {
	private := protocol.PlayerState{
		Processed: p.processed, LastProcessedTick: p.lastProcessed, BufferedCommands: p.buffered, Soldier: p.soldier,
	}
	if soldier := s.soldiers.Get(p.soldier); soldier != nil {
		private.Position, private.Velocity = soldier.Position, soldier.Velocity
	}
	states, removed := s.states, s.removedID
	for first := true; first || len(states) > 0; first = false {
		count := min(len(states), protocol.SnapshotCapacity(protocol.SnapshotBudget, len(removed)))
		p.snapshot = protocol.Snapshot{
			Sequence: p.sequence, ServerTick: s.tick, Player: private, Soldiers: states[:count], Removed: removed,
		}
		p.sequence++
		data, err := p.snapshot.Encode(p.buffer[:0])
		if err != nil {
			log.Printf("snapshot for player %d: %v", p.id, err)
			return
		}
		p.buffer = data
		if p.conn.SendUnreliable(data) != nil {
			return
		}
		states, removed = states[count:], nil
	}
}
