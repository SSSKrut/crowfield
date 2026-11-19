package simulation

import (
	"log"
	"math"
	"slices"

	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/physics"
)

const (
	// datagramOverhead estimates what a snapshot datagram costs on the wire
	// besides its payload: IPv4 and UDP headers (28 bytes), the QUIC short
	// header (about 7), the DATAGRAM frame (3) and the AEAD tag (16). The
	// budget of a client counts it.
	datagramOverhead = 55
	// A further datagram of a snapshot is sent only with this much room.
	minDatagramRoom = 200
	// ackWindow is how many recent datagrams the server remembers
	// acknowledgements of; it covers the oldest base a delta can name.
	ackWindow = protocol.MaxBaseAge + 1
)

// Some soldiers go into every snapshot, ahead of all others: the player's
// own, the other humans (at most 15) and those near the crosshair, since lag
// compensation is only fair when what the player shoots at was drawn by
// interpolation (ARCHITECTURE.md, 6.9).
//
// The others share what is left of the budget by priority. Every snapshot, a
// soldier's priority grows by its update rate, in updates per second, times
// the snapshot interval; the highest go first, and sending one resets it.
// When the budget is short, soldiers are updated in proportion to their rates.
const (
	// Bots within nearDistance get nearRate; farther ones less, down to
	// farRate. In the wide cone around the line of sight they get coneRate.
	nearRate     = 10
	nearDistance = 20
	farRate      = 1
	coneRate     = 40
	coneAngle    = 10 * math.Pi / 180
	// crosshairAngle is the narrow cone of soldiers sent every snapshot. In
	// a crowd the wide cone holds dozens of soldiers.
	crosshairAngle = 2 * math.Pi / 180
	// Both cones are widened by this much at the soldier's distance: a soldier
	// counts while any part of it is near the line.
	coneMargin = 0.5
)

// entityView is what a client has been told about one soldier slot.
type entityView struct {
	// id is the soldier the client is being told about; zero for none.
	id       game.SoldierID
	priority float32
	// sends are the newest states sent, the possible bases of a delta.
	sends [protocol.BaseHistory]sentState
	next  int
}

type sentState struct {
	datagram uint64
	sent     bool
	state    protocol.SoldierState
}

// pendingRemoval is a soldier the client knows of and that is gone. It is
// repeated in every snapshot until a datagram carrying it is acknowledged.
type pendingRemoval struct {
	id    game.SoldierID
	sends [protocol.BaseHistory]uint64 // datagram numbers plus one; zero for none
	next  int
}

// candidate is a soldier to send, packed so that sorting the keys in
// descending order puts the ones sent every snapshot first, then the highest
// priority, then the lowest slot.
type candidate uint64

func newCandidate(slot int, always bool, priority float32) candidate {
	key := uint64(math.Float32bits(priority))<<12 | uint64(game.MaxSoldiers-1-slot)
	if always {
		key |= 1 << 63
	}
	return candidate(key)
}

func (c candidate) slot() int {
	return game.MaxSoldiers - 1 - int(c&(game.MaxSoldiers-1))
}

// viewpoint is where a player looks from, for the priorities of its snapshots.
type viewpoint struct {
	eye, forward physics.Vec3
	center       float32
	ok           bool
}

// sendSnapshots quantizes every soldier once and sends each ready player its
// snapshot of the tick.
func (s *Server) sendSnapshots() {
	if len(s.states) != s.soldiers.Slots() {
		s.states = make([]protocol.SoldierState, s.soldiers.Slots())
	}
	for slot := range s.states {
		s.states[slot] = protocol.SoldierState{}
		soldier := s.soldiers.At(slot)
		if soldier == nil {
			continue
		}
		state, err := protocol.NewSoldierState(soldier)
		if err != nil {
			log.Printf("soldier left out of the snapshot: %v", err)
			continue
		}
		s.states[slot] = state
	}
	for _, p := range s.players {
		if p != nil && p.ready {
			s.sendSnapshot(p)
		}
	}
}

// sendSnapshot sends a player the soldiers it needs most, within its budget.
// Every datagram carries the private state, so each one is useful alone, and
// the first carries the removals.
func (s *Server) sendSnapshot(p *player) {
	private := protocol.PlayerState{
		Processed: p.processed, LastProcessedTick: p.lastProcessed, BufferedCommands: p.buffered, Soldier: p.soldier,
	}
	if soldier := s.soldiers.Get(p.soldier); soldier != nil {
		private.Position, private.Velocity = soldier.Position, soldier.Velocity
	}
	s.prioritize(p)
	p.removals = slices.DeleteFunc(p.removals, func(r pendingRemoval) bool { return p.removalDelivered(&r) })
	perSnapshot := float64(s.settings.ClientBandwidth) / float64(s.settings.SnapshotRate)
	p.allowance = min(p.allowance+perSnapshot, 2*perSnapshot)
	next := 0
	for first := true; first || next < len(p.candidates); first = false {
		room := min(protocol.SnapshotBudget, int(p.allowance)-datagramOverhead)
		if !first && room < minDatagramRoom {
			break
		}
		var removed []game.SoldierID
		if first {
			p.removedIDs = p.removedIDs[:0]
			for _, r := range p.removals[:min(len(p.removals), protocol.MaxSnapshotRemoved)] {
				p.removedIDs = append(p.removedIDs, r.id)
			}
			removed = p.removedIDs
		}
		p.snapshot = protocol.Snapshot{
			Sequence: uint16(p.datagrams), ServerTick: s.tick, Player: private,
			Soldiers: p.snapshot.Soldiers, Removed: removed,
		}
		p.packer.Reset(&p.snapshot, max(0, room))
		from := next
		for ; next < len(p.candidates); next++ {
			slot := p.candidates[next].slot()
			record := p.views[slot].record(p, s.states[slot])
			if !p.packer.Add(&record) {
				break
			}
		}
		p.packer.Finish()
		data, err := p.snapshot.Encode(p.buffer[:0])
		if err != nil {
			log.Printf("snapshot for player %d: %v", p.id, err)
			return
		}
		p.buffer = data
		for _, c := range p.candidates[from:next] {
			p.views[c.slot()].sent(p.datagrams, s.states[c.slot()])
		}
		for i := range removed {
			p.removals[i].sent(p.datagrams)
		}
		p.acks[p.datagrams%ackWindow] = 0
		p.datagrams++
		p.allowance -= float64(len(data) + datagramOverhead)
		s.profile.snapshotBytes += uint64(len(data) + datagramOverhead)
		if p.conn.SendUnreliable(data) != nil || (next == from && !first) {
			return
		}
	}
}

// prioritize notices soldiers that left the player's view, raises the
// priority of the others and orders them, the most urgent first.
func (s *Server) prioritize(p *player) {
	view := s.viewpoint(p)
	interval := 1 / float32(s.settings.SnapshotRate)
	p.candidates = p.candidates[:0]
	for slot := range p.views {
		v := &p.views[slot]
		soldier := s.soldiers.At(slot)
		var id game.SoldierID
		if soldier != nil {
			id = soldier.ID
		}
		if v.id != id {
			if v.sends[0].sent {
				p.removals = append(p.removals, pendingRemoval{id: v.id})
			}
			*v = entityView{id: id}
		}
		if soldier == nil || s.states[slot].ID == 0 {
			continue
		}
		rate, always := view.rate(soldier, p.soldier)
		v.priority += rate * interval
		p.candidates = append(p.candidates, newCandidate(slot, always, v.priority))
	}
	slices.Sort(p.candidates)
	slices.Reverse(p.candidates)
}

func (s *Server) viewpoint(p *player) viewpoint {
	soldier := s.soldiers.Get(p.soldier)
	if soldier == nil {
		return viewpoint{}
	}
	yaw, pitch := float64(p.last.YawRadians()), float64(p.last.PitchRadians())
	view := viewpoint{
		eye: soldier.Position.Add(physics.V(0, s.tuning.EyeHeight, 0)),
		forward: physics.V(
			float32(math.Sin(yaw)*math.Cos(pitch)), float32(math.Sin(pitch)), -float32(math.Cos(yaw)*math.Cos(pitch)),
		),
		center: s.tuning.CenterHeight(), ok: true,
	}
	return view
}

// rate is how many updates per second a soldier deserves from this
// viewpoint, or always for one that goes into every snapshot. Rates of those
// still order them, should they not fit.
func (v *viewpoint) rate(soldier *game.Soldier, own game.SoldierID) (float32, bool) {
	if soldier.ID == own || soldier.Controller.Kind == game.ControllerPlayer || !v.ok {
		return nearRate, true
	}
	to := soldier.Position.Add(physics.V(0, v.center, 0)).Sub(v.eye)
	length := float32(math.Sqrt(float64(to.Dot(to))))
	if length < coneMargin {
		return coneRate, true
	}
	// The soldier is within a cone when the angle to it, less the angle its
	// margin takes, is within the cone's: compared as cosines.
	cosine := v.forward.Dot(to) / length
	marginSine := coneMargin / length
	marginCosine := float32(math.Sqrt(float64(1 - marginSine*marginSine)))
	switch {
	case cosine >= crosshairCosine*marginCosine-crosshairSine*marginSine:
		return coneRate, true
	case cosine >= coneCosine*marginCosine-coneSine*marginSine:
		return coneRate, false
	}
	return max(farRate, nearRate*min(1, nearDistance/length)), false
}

var (
	coneCosine, coneSine           = float32(math.Cos(coneAngle)), float32(math.Sin(coneAngle))
	crosshairCosine, crosshairSine = float32(math.Cos(crosshairAngle)), float32(math.Sin(crosshairAngle))
)

// record describes a soldier as a delta from the newest state the client
// acknowledged, or in full without one.
func (v *entityView) record(p *player, state protocol.SoldierState) protocol.SoldierRecord {
	var base *protocol.SoldierState
	age := uint64(0)
	for i := range v.sends {
		sent := &v.sends[i]
		if sent.sent && p.acknowledged(sent.datagram) && (base == nil || p.datagrams-sent.datagram < age) {
			base, age = &sent.state, p.datagrams-sent.datagram
		}
	}
	return protocol.NewSoldierRecord(state, base, int(min(age, protocol.MaxBaseAge+1)))
}

func (v *entityView) sent(datagram uint64, state protocol.SoldierState) {
	v.sends[v.next] = sentState{datagram: datagram, sent: true, state: state}
	v.next = (v.next + 1) % len(v.sends)
	v.priority = 0
}

func (r *pendingRemoval) sent(datagram uint64) {
	r.sends[r.next] = datagram + 1
	r.next = (r.next + 1) % len(r.sends)
}

func (p *player) removalDelivered(r *pendingRemoval) bool {
	for _, sent := range r.sends {
		if sent != 0 && p.acknowledged(sent-1) {
			return true
		}
	}
	return false
}

// acknowledge records the snapshot datagrams an input packet confirms.
func (p *player) acknowledge(packet *protocol.InputPacket) {
	if !packet.HasAck || p.datagrams == 0 {
		return
	}
	p.ack(packet.AckSequence)
	for i := range 32 {
		if packet.AckBits&(1<<i) != 0 {
			p.ack(packet.AckSequence - 1 - uint16(i))
		}
	}
}

// ack marks a datagram by its sequence, if it is among the recent ones sent.
func (p *player) ack(sequence uint16) {
	latest := p.datagrams - 1
	back := uint64(uint16(latest) - sequence)
	if back >= ackWindow || back > latest {
		return
	}
	datagram := latest - back
	p.acks[datagram%ackWindow] = datagram + 1
}

func (p *player) acknowledged(datagram uint64) bool {
	return p.datagrams-datagram <= ackWindow && p.acks[datagram%ackWindow] == datagram+1
}
