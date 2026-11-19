package protocol

import (
	"errors"
	"fmt"

	"ravenfield/internal/game"
)

const (
	// BaseHistory is how many recent states of a soldier both ends keep for
	// deltas. The server builds a delta only on one of the last BaseHistory
	// states it sent of a soldier, and the client keeps the BaseHistory newest
	// it received, so a base the client acknowledged is always still there.
	BaseHistory = 8
	// MaxBaseAge is the oldest base a delta can name, in datagrams.
	MaxBaseAge = 1<<baseBits - 1

	baseBits = 8
	// A slot is written as the gap after the previous record's slot: short
	// gaps, the usual case, take 3 bits, the rest 12.
	shortGapBits   = 3
	longGapBits    = 12
	generationBits = 4
	// A position difference is written with the fewest bits that hold all
	// three components, up to maxMoveBits each.
	moveWidthBits = 4
	maxMoveBits   = 1 << moveWidthBits
	// minRecordBits is the smallest record: a delta that changes nothing.
	minRecordBits = 1 + shortGapBits + generationBits + 1 + baseBits + 2 + 4
)

// Position modes of a delta record.
const (
	positionKept = iota
	positionMoved
	positionFull
)

// RecordFields lists what a delta record carries.
type RecordFields uint8

const (
	// FieldPosition carries the whole position and FieldMove its difference
	// from the base; a delta has at most one of them.
	FieldPosition RecordFields = 1 << iota
	FieldMove
	FieldVelocity
	FieldAngles
	FieldFlags
	FieldWeapon
	knownFields = FieldWeapon<<1 - 1
)

var ErrMissingBase = errors.New("the base of a delta is missing")

// SoldierRecord is a soldier in a snapshot datagram: its full state, or a
// delta that carries only what changed since a base the client acknowledged.
type SoldierRecord struct {
	// State has the identity of the soldier and the values of the fields the
	// record carries; a decoded delta leaves the other fields zero.
	State SoldierState
	// Base is how many datagrams before this one the base was sent. Zero makes
	// a full record, which needs no base.
	Base   uint8
	Fields RecordFields
	// Move is the position minus the base position, with FieldMove.
	Move [3]int32
}

// NewSoldierRecord describes state as a delta from base, which was sent age
// datagrams earlier, or in full when there is no usable base.
func NewSoldierRecord(state SoldierState, base *SoldierState, age int) SoldierRecord {
	record := SoldierRecord{State: state}
	if base == nil || age < 1 || age > MaxBaseAge || base.ID != state.ID || base.Bot != state.Bot || base.Team != state.Team {
		return record
	}
	record.Base = uint8(age)
	if state.Position != base.Position {
		record.Fields |= FieldMove
		for i := range record.Move {
			record.Move[i] = state.Position[i] - base.Position[i]
		}
		if moveWidth(record.Move) > maxMoveBits {
			record.Fields, record.Move = FieldPosition, [3]int32{}
		}
	}
	if state.Velocity != base.Velocity {
		record.Fields |= FieldVelocity
	}
	if state.Yaw != base.Yaw || state.Pitch != base.Pitch {
		record.Fields |= FieldAngles
	}
	if state.Flags != base.Flags {
		record.Fields |= FieldFlags
	}
	if state.Weapon != base.Weapon {
		record.Fields |= FieldWeapon
	}
	return record
}

// Resolve returns the state the record describes: its own for a full record,
// or the base with the carried fields replaced.
func (r *SoldierRecord) Resolve(base *SoldierState) (SoldierState, error) {
	if r.Base == 0 {
		return r.State, nil
	}
	if base == nil || base.ID != r.State.ID || base.Bot != r.State.Bot {
		return SoldierState{}, fmt.Errorf("soldier %#04x: %w", r.State.ID, ErrMissingBase)
	}
	state := *base
	if r.Fields&FieldPosition != 0 {
		state.Position = r.State.Position
	}
	if r.Fields&FieldMove != 0 {
		for i := range state.Position {
			state.Position[i] += r.Move[i]
		}
	}
	if r.Fields&FieldVelocity != 0 {
		state.Velocity = r.State.Velocity
	}
	if r.Fields&FieldAngles != 0 {
		state.Yaw, state.Pitch = r.State.Yaw, r.State.Pitch
	}
	if r.Fields&FieldFlags != 0 {
		state.Flags = r.State.Flags
	}
	if r.Fields&FieldWeapon != 0 {
		state.Weapon = r.State.Weapon
	}
	return state, state.validate()
}

func (r *SoldierRecord) validate() error {
	if err := r.State.validate(); err != nil {
		return err
	}
	switch {
	case r.Base == 0:
		return nil
	case r.Fields&^knownFields != 0:
		return fmt.Errorf("soldier %#04x: unknown record fields %#x", r.State.ID, r.Fields)
	case r.Fields&FieldPosition != 0 && r.Fields&FieldMove != 0:
		return fmt.Errorf("soldier %#04x: a delta has both a position and a move", r.State.ID)
	case r.Fields&FieldMove != 0 && (r.Move == [3]int32{} || moveWidth(r.Move) > maxMoveBits):
		return fmt.Errorf("soldier %#04x: move %v is empty or too long", r.State.ID, r.Move)
	}
	return nil
}

// bodyBits is the size of the record after its slot gap.
func (r *SoldierRecord) bodyBits() int {
	s := &r.State
	bits := generationBits + 1 + baseBits
	if r.Base == 0 {
		return bits + teamBits + flagsBits + positionBits + s.velocityBits() + s.angleBits() + weaponBits
	}
	bits += 2 + 4
	switch {
	case r.Fields&FieldPosition != 0:
		bits += positionBits
	case r.Fields&FieldMove != 0:
		bits += moveWidthBits + 3*int(moveWidth(r.Move))
	}
	if r.Fields&FieldVelocity != 0 {
		bits += s.velocityBits()
	}
	if r.Fields&FieldAngles != 0 {
		bits += s.angleBits()
	}
	if r.Fields&FieldFlags != 0 {
		bits += flagsBits
	}
	if r.Fields&FieldWeapon != 0 {
		bits += weaponBits
	}
	return bits
}

// write writes the record after one for slot previous, or first with -1.
func (r *SoldierRecord) write(w *BitWriter, previous int) {
	gap := r.State.ID.Slot() - previous - 1
	w.WriteBool(gap >= 1<<shortGapBits)
	if gap >= 1<<shortGapBits {
		w.WriteBits(uint32(gap), longGapBits)
	} else {
		w.WriteBits(uint32(gap), shortGapBits)
	}
	r.writeBody(w)
}

func (r *SoldierRecord) writeBody(w *BitWriter) {
	s := &r.State
	w.WriteBits(uint32(s.ID.Generation()), generationBits)
	w.WriteBool(s.Bot)
	w.WriteBits(uint32(r.Base), baseBits)
	if r.Base == 0 {
		w.WriteBits(uint32(s.Team), teamBits)
		w.WriteBits(uint32(s.Flags), flagsBits)
		s.writePosition(w)
		s.writeVelocity(w)
		s.writeAngles(w)
		w.WriteBits(uint32(s.Weapon), weaponBits)
		return
	}
	switch {
	case r.Fields&FieldPosition != 0:
		w.WriteBits(positionFull, 2)
		s.writePosition(w)
	case r.Fields&FieldMove != 0:
		w.WriteBits(positionMoved, 2)
		width := moveWidth(r.Move)
		w.WriteBits(uint32(width-1), moveWidthBits)
		for _, v := range r.Move {
			w.WriteSigned(v, width)
		}
	default:
		w.WriteBits(positionKept, 2)
	}
	w.WriteBool(r.Fields&FieldVelocity != 0)
	if r.Fields&FieldVelocity != 0 {
		s.writeVelocity(w)
	}
	w.WriteBool(r.Fields&FieldAngles != 0)
	if r.Fields&FieldAngles != 0 {
		s.writeAngles(w)
	}
	w.WriteBool(r.Fields&FieldFlags != 0)
	if r.Fields&FieldFlags != 0 {
		w.WriteBits(uint32(s.Flags), flagsBits)
	}
	w.WriteBool(r.Fields&FieldWeapon != 0)
	if r.Fields&FieldWeapon != 0 {
		w.WriteBits(uint32(s.Weapon), weaponBits)
	}
}

// read reads a record into a zero one. Every value has one encoding: a long
// gap that would fit the short form and a move wider than needed are rejected.
func (r *SoldierRecord) read(reader *BitReader, previous int) {
	s := &r.State
	long := reader.ReadBool()
	var gap int
	if long {
		if gap = int(reader.ReadBits(longGapBits)); gap < 1<<shortGapBits {
			reader.Fail(errors.New("a short slot gap is written long"))
		}
	} else {
		gap = int(reader.ReadBits(shortGapBits))
	}
	slot := previous + 1 + gap
	if slot >= game.MaxSoldiers {
		reader.Fail(fmt.Errorf("slot %d is out of range", slot))
	}
	s.ID = game.NewSoldierID(slot&(game.MaxSoldiers-1), uint8(reader.ReadBits(generationBits)))
	s.Bot = reader.ReadBool()
	r.Base = uint8(reader.ReadBits(baseBits))
	if r.Base == 0 {
		s.Team = game.Team(reader.ReadBits(teamBits))
		s.Flags = SoldierFlags(reader.ReadBits(flagsBits))
		s.readPosition(reader)
		s.readVelocity(reader)
		s.readAngles(reader)
		s.Weapon = uint8(reader.ReadBits(weaponBits))
	} else {
		switch reader.ReadBits(2) {
		case positionKept:
		case positionMoved:
			r.Fields |= FieldMove
			width := uint(reader.ReadBits(moveWidthBits)) + 1
			for i := range r.Move {
				r.Move[i] = reader.ReadSigned(width)
			}
			if reader.Err() == nil && moveWidth(r.Move) != width {
				reader.Fail(errors.New("a move is written wider than needed"))
			}
		case positionFull:
			r.Fields |= FieldPosition
			s.readPosition(reader)
		default:
			reader.Fail(errors.New("unknown position mode"))
		}
		if reader.ReadBool() {
			r.Fields |= FieldVelocity
			s.readVelocity(reader)
		}
		if reader.ReadBool() {
			r.Fields |= FieldAngles
			s.readAngles(reader)
		}
		if reader.ReadBool() {
			r.Fields |= FieldFlags
			s.Flags = SoldierFlags(reader.ReadBits(flagsBits))
		}
		if reader.ReadBool() {
			r.Fields |= FieldWeapon
			s.Weapon = uint8(reader.ReadBits(weaponBits))
		}
	}
	if reader.Err() == nil {
		if err := r.validate(); err != nil {
			reader.Fail(err)
		}
	}
}

func slotBits(gap int) int {
	if gap < 1<<shortGapBits {
		return 1 + shortGapBits
	}
	return 1 + longGapBits
}

// moveWidth is the fewest bits that hold every component as a signed value.
func moveWidth(move [3]int32) uint {
	width := uint(1)
	for _, v := range move {
		for width < 32 && !fitsSigned(v, width) {
			width++
		}
	}
	return width
}
