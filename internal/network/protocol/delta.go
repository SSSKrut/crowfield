package protocol

import (
	"cmp"
	"slices"

	"ravenfield/internal/game"
)

// SnapshotPacker fills a snapshot datagram with records up to a size limit.
// Records are taken in any order and sorted by slot at the end; the packer
// knows the exact encoded size all along, although the size of a slot depends
// on its neighbours.
type SnapshotPacker struct {
	snapshot *Snapshot
	slots    []int // slots of the records added, ascending
	bits     int
	limit    int
}

// Reset starts packing into snapshot, whose header, player state and removals
// are set already. Its records are cleared.
func (p *SnapshotPacker) Reset(snapshot *Snapshot, limitBytes int) {
	snapshot.Soldiers = snapshot.Soldiers[:0]
	p.snapshot, p.slots = snapshot, p.slots[:0]
	p.bits, p.limit = snapshot.fixedBits(), limitBytes*8
}

// Add appends the record if the datagram still fits the limit with it. Each
// slot may be added once.
func (p *SnapshotPacker) Add(record *SoldierRecord) bool {
	if len(p.slots) == MaxSnapshotSoldiers {
		return false
	}
	slot := record.State.ID.Slot()
	i, found := slices.BinarySearch(p.slots, slot)
	if found {
		return false
	}
	previous := -1
	if i > 0 {
		previous = p.slots[i-1]
	}
	added := slotBits(slot-previous-1) + record.bodyBits()
	if i < len(p.slots) {
		next := p.slots[i]
		added += slotBits(next-slot-1) - slotBits(next-previous-1)
	}
	if p.bits+added > p.limit {
		return false
	}
	p.slots = slices.Insert(p.slots, i, slot)
	p.snapshot.Soldiers = append(p.snapshot.Soldiers, *record)
	p.bits += added
	return true
}

// Finish puts the records in slot order, as Encode requires, and returns the
// size the snapshot will encode to.
func (p *SnapshotPacker) Finish() int {
	slices.SortFunc(p.snapshot.Soldiers, func(first, second SoldierRecord) int {
		return cmp.Compare(first.State.ID.Slot(), second.State.ID.Slot())
	})
	return (p.bits + 7) / 8
}

// Baselines keeps what a client received of each soldier, the BaseHistory
// newest states by datagram sequence, and resolves deltas against them.
type Baselines struct {
	soldiers map[game.SoldierID]*receivedStates
}

type receivedStates struct {
	count     int
	sequences [BaseHistory]uint16
	states    [BaseHistory]SoldierState
}

func NewBaselines() *Baselines {
	return &Baselines{soldiers: make(map[game.SoldierID]*receivedStates)}
}

// Resolve returns the full state that a record of the datagram with the given
// sequence describes.
func (b *Baselines) Resolve(sequence uint16, record *SoldierRecord) (SoldierState, error) {
	if record.Base == 0 {
		return record.Resolve(nil)
	}
	var base *SoldierState
	if received := b.soldiers[record.State.ID]; received != nil {
		want := sequence - uint16(record.Base)
		for i := range received.count {
			if received.sequences[i] == want {
				base = &received.states[i]
				break
			}
		}
	}
	return record.Resolve(base)
}

// Store keeps a state received in the datagram with the given sequence as a
// possible base, unless BaseHistory newer states of the soldier are kept.
func (b *Baselines) Store(sequence uint16, state SoldierState) {
	received := b.soldiers[state.ID]
	if received == nil {
		received = &receivedStates{}
		b.soldiers[state.ID] = received
	}
	for i := range received.count {
		if received.sequences[i] == sequence {
			received.states[i] = state
			return
		}
	}
	slot := received.count
	if slot < BaseHistory {
		received.count++
	} else {
		slot = 0
		for i := 1; i < BaseHistory; i++ {
			if int16(received.sequences[i]-received.sequences[slot]) < 0 {
				slot = i
			}
		}
		if int16(sequence-received.sequences[slot]) < 0 {
			return
		}
	}
	received.sequences[slot], received.states[slot] = sequence, state
}

// Forget drops what was received of a soldier that is gone.
func (b *Baselines) Forget(id game.SoldierID) {
	delete(b.soldiers, id)
}
