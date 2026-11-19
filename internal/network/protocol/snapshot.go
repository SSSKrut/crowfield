package protocol

import (
	"errors"
	"fmt"
	"math"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

const (
	MaxSnapshotSoldiers = 1023
	MaxSnapshotRemoved  = 255

	// PositionUnitsPerMetre gives 2 mm steps: X and Z cover ±2048 m, Y ±512 m.
	PositionUnitsPerMetre = 512
	// VelocityUnitsPerMetre gives 1/32 m/s steps up to ±64 m/s.
	VelocityUnitsPerMetre = 32

	soldierCountBits = 10
	removedCountBits = 8
	teamBits         = 2
	horizontalBits   = 21
	verticalBits     = 19
	velocityBits     = 12
	yawBits          = 12
	pitchBits        = 10
	soldierStateBits = 16 + teamBits + 8 + 2*horizontalBits + verticalBits + 3*velocityBits + yawBits + pitchBits + weaponBits
)

type SoldierFlags uint8

const (
	SoldierAlive SoldierFlags = 1 << iota
	SoldierGrounded
	SoldierBot
)

// SoldierState is a soldier as every client sees it, already quantized, so it
// encodes without loss. Health and ammo of other soldiers are not sent.
type SoldierState struct {
	ID       game.SoldierID
	Team     game.Team
	Flags    SoldierFlags
	Position [3]int32 // 1/512 m; X and Z fit 21 bits, Y 19 bits
	Velocity [3]int16 // 1/32 m/s, 12 bits each
	Yaw      uint16   // 12 bits of a full turn
	Pitch    int16    // 10 bits over [-π/2, π/2]
	Weapon   uint8    // 4 bits
}

// NewSoldierState quantizes a soldier. It fails when the soldier is outside the
// range the protocol can represent, which means it left the map.
func NewSoldierState(soldier *game.Soldier) (SoldierState, error) {
	state := SoldierState{
		ID: soldier.ID, Team: soldier.Team,
		Yaw: quantizeTurn(soldier.Yaw), Pitch: quantizePitch(soldier.Pitch),
	}
	if soldier.Alive {
		state.Flags |= SoldierAlive
	}
	if soldier.Grounded {
		state.Flags |= SoldierGrounded
	}
	if soldier.Controller.Kind == game.ControllerBot {
		state.Flags |= SoldierBot
	}
	position := [3]float32{soldier.Position.X, soldier.Position.Y, soldier.Position.Z}
	velocity := [3]float32{soldier.Velocity.X, soldier.Velocity.Y, soldier.Velocity.Z}
	if !finite(position) || !finite(velocity) {
		return SoldierState{}, fmt.Errorf("soldier %#04x: %w", soldier.ID, ErrInvalidFloat)
	}
	limit := float64(int32(1)<<(velocityBits-1) - 1)
	for i := range 3 {
		state.Position[i] = int32(max(math.MinInt32, min(math.MaxInt32, math.Round(float64(position[i])*PositionUnitsPerMetre))))
		state.Velocity[i] = int16(max(-limit, min(limit, math.Round(float64(velocity[i])*VelocityUnitsPerMetre))))
	}
	return state, state.validate()
}

// Apply writes the received state into a client-side soldier. The client only
// learns whether a soldier is a bot, not which player or bot drives it.
func (s SoldierState) Apply(soldier *game.Soldier) {
	soldier.ID = s.ID
	soldier.Team = s.Team
	soldier.Alive = s.Flags&SoldierAlive != 0
	soldier.Grounded = s.Flags&SoldierGrounded != 0
	soldier.Controller = game.Controller{Kind: game.ControllerPlayer}
	if s.Flags&SoldierBot != 0 {
		soldier.Controller.Kind = game.ControllerBot
	}
	soldier.Position = physics.V(
		float32(s.Position[0])/PositionUnitsPerMetre,
		float32(s.Position[1])/PositionUnitsPerMetre,
		float32(s.Position[2])/PositionUnitsPerMetre,
	)
	soldier.Velocity = physics.V(
		float32(s.Velocity[0])/VelocityUnitsPerMetre,
		float32(s.Velocity[1])/VelocityUnitsPerMetre,
		float32(s.Velocity[2])/VelocityUnitsPerMetre,
	)
	soldier.Yaw = float32(s.Yaw) * (2 * math.Pi / (1 << yawBits))
	pitchLimit := int32(1)<<(pitchBits-1) - 1
	soldier.Pitch = float32(max(-pitchLimit, int32(s.Pitch))) * (math.Pi / 2 / float32(pitchLimit))
}

func (s *SoldierState) validate() error {
	switch {
	case s.ID.Generation() == 0:
		return fmt.Errorf("soldier %#04x has no generation", s.ID)
	case s.Team > game.TeamRed:
		return fmt.Errorf("soldier %#04x has unknown team %d", s.ID, s.Team)
	case !fitsSigned(s.Position[0], horizontalBits) || !fitsSigned(s.Position[1], verticalBits) ||
		!fitsSigned(s.Position[2], horizontalBits):
		return fmt.Errorf("soldier %#04x is outside the map range", s.ID)
	case !fitsSigned(int32(s.Velocity[0]), velocityBits) || !fitsSigned(int32(s.Velocity[1]), velocityBits) ||
		!fitsSigned(int32(s.Velocity[2]), velocityBits):
		return fmt.Errorf("soldier %#04x velocity is out of range", s.ID)
	case s.Yaw >= 1<<yawBits || !fitsSigned(int32(s.Pitch), pitchBits) || s.Weapon >= 1<<weaponBits:
		return fmt.Errorf("soldier %#04x angles or weapon are out of range", s.ID)
	}
	return nil
}

func (s *SoldierState) write(w *BitWriter) {
	w.WriteBits(uint32(s.ID), 16)
	w.WriteBits(uint32(s.Team), teamBits)
	w.WriteBits(uint32(s.Flags), 8)
	w.WriteSigned(s.Position[0], horizontalBits)
	w.WriteSigned(s.Position[1], verticalBits)
	w.WriteSigned(s.Position[2], horizontalBits)
	for _, v := range s.Velocity {
		w.WriteSigned(int32(v), velocityBits)
	}
	w.WriteBits(uint32(s.Yaw), yawBits)
	w.WriteSigned(int32(s.Pitch), pitchBits)
	w.WriteBits(uint32(s.Weapon), weaponBits)
}

func (s *SoldierState) read(r *BitReader) {
	s.ID = game.SoldierID(r.ReadBits(16))
	s.Team = game.Team(r.ReadBits(teamBits))
	s.Flags = SoldierFlags(r.ReadBits(8))
	s.Position[0] = r.ReadSigned(horizontalBits)
	s.Position[1] = r.ReadSigned(verticalBits)
	s.Position[2] = r.ReadSigned(horizontalBits)
	for i := range s.Velocity {
		s.Velocity[i] = int16(r.ReadSigned(velocityBits))
	}
	s.Yaw = uint16(r.ReadBits(yawBits))
	s.Pitch = int16(r.ReadSigned(pitchBits))
	s.Weapon = uint8(r.ReadBits(weaponBits))
	if r.Err() == nil {
		if err := s.validate(); err != nil {
			r.Fail(err)
		}
	}
}

// PlayerState is the private part of a snapshot for the player who receives it.
// Position and velocity keep full precision for reconciliation and are only
// sent while the player has a soldier.
type PlayerState struct {
	Processed         bool
	LastProcessedTick game.Tick
	// BufferedCommands is how many of the player's commands waited in the server
	// queue when the tick ran; the client speeds up or slows down to keep it at 2.
	BufferedCommands int8
	Soldier          game.SoldierID
	Position         physics.Vec3
	Velocity         physics.Vec3
}

func (p *PlayerState) validate() error {
	if p.Soldier != 0 && p.Soldier.Generation() == 0 {
		return fmt.Errorf("player soldier %#04x has no generation", p.Soldier)
	}
	if !finite([3]float32{p.Position.X, p.Position.Y, p.Position.Z}) || !finite([3]float32{p.Velocity.X, p.Velocity.Y, p.Velocity.Z}) {
		return ErrInvalidFloat
	}
	return nil
}

func (p *PlayerState) write(w *BitWriter) {
	w.WriteBool(p.Processed)
	if p.Processed {
		w.WriteBits(uint32(p.LastProcessedTick), 32)
	}
	w.WriteSigned(int32(p.BufferedCommands), 8)
	w.WriteBits(uint32(p.Soldier), 16)
	if p.Soldier != 0 {
		for _, value := range [6]float32{p.Position.X, p.Position.Y, p.Position.Z, p.Velocity.X, p.Velocity.Y, p.Velocity.Z} {
			w.WriteFloat32(value)
		}
	}
}

func (p *PlayerState) read(r *BitReader) {
	*p = PlayerState{Processed: r.ReadBool()}
	if p.Processed {
		p.LastProcessedTick = game.Tick(r.ReadBits(32))
	}
	p.BufferedCommands = int8(r.ReadSigned(8))
	p.Soldier = game.SoldierID(r.ReadBits(16))
	if p.Soldier == 0 {
		return
	}
	if p.Soldier.Generation() == 0 {
		r.Fail(fmt.Errorf("player soldier %#04x has no generation", p.Soldier))
	}
	p.Position = physics.V(r.ReadFloat32(), r.ReadFloat32(), r.ReadFloat32())
	p.Velocity = physics.V(r.ReadFloat32(), r.ReadFloat32(), r.ReadFloat32())
}

// Snapshot is one server datagram. Soldiers missing from it are not removed:
// removal is explicit, because a snapshot may carry only some soldiers.
type Snapshot struct {
	Sequence   uint16
	ServerTick game.Tick
	Player     PlayerState
	Soldiers   []SoldierState
	Removed    []game.SoldierID
}

func (*Snapshot) Type() MessageType { return MessageSnapshot }

func (m *Snapshot) Encode(dst []byte) ([]byte, error) {
	if len(m.Soldiers) > MaxSnapshotSoldiers || len(m.Removed) > MaxSnapshotRemoved {
		return dst, fmt.Errorf("snapshot with %d soldiers and %d removals is too large", len(m.Soldiers), len(m.Removed))
	}
	if err := m.Player.validate(); err != nil {
		return dst, err
	}
	for i := range m.Soldiers {
		if err := m.Soldiers[i].validate(); err != nil {
			return dst, err
		}
	}
	for _, id := range m.Removed {
		if id.Generation() == 0 {
			return dst, fmt.Errorf("removed soldier %#04x has no generation", id)
		}
	}
	w := startWriting(dst, MessageSnapshot)
	w.WriteBits(uint32(m.Sequence), 16)
	w.WriteBits(uint32(m.ServerTick), 32)
	m.Player.write(&w)
	w.WriteBits(uint32(len(m.Soldiers)), soldierCountBits)
	for i := range m.Soldiers {
		m.Soldiers[i].write(&w)
	}
	w.WriteBits(uint32(len(m.Removed)), removedCountBits)
	for _, id := range m.Removed {
		w.WriteBits(uint32(id), 16)
	}
	return w.Bytes(), nil
}

func (m *Snapshot) Decode(data []byte) error {
	r := startReading(data, MessageSnapshot)
	m.Sequence = uint16(r.ReadBits(16))
	m.ServerTick = game.Tick(r.ReadBits(32))
	m.Player.read(&r)
	m.Soldiers = m.Soldiers[:0]
	m.Removed = m.Removed[:0]
	count := int(r.ReadBits(soldierCountBits))
	if uint(count)*soldierStateBits > r.Remaining() {
		r.Fail(ErrShortMessage)
	}
	for range count {
		if r.Err() != nil {
			break
		}
		m.Soldiers = append(m.Soldiers, SoldierState{})
		m.Soldiers[len(m.Soldiers)-1].read(&r)
	}
	removed := int(r.ReadBits(removedCountBits))
	for range removed {
		id := game.SoldierID(r.ReadBits(16))
		if r.Err() != nil {
			break
		}
		if id.Generation() == 0 {
			r.Fail(errors.New("removed soldier has no generation"))
		}
		m.Removed = append(m.Removed, id)
	}
	return r.Finish()
}

func finite(values [3]float32) bool {
	for _, value := range values {
		if math.IsNaN(float64(value)) || math.IsInf(float64(value), 0) {
			return false
		}
	}
	return true
}

func fitsSigned(value int32, bits uint) bool {
	limit := int32(1) << (bits - 1)
	return value >= -limit && value < limit
}

func quantizeTurn(radians float32) uint16 {
	turns := float64(radians) / (2 * math.Pi)
	turns -= math.Floor(turns)
	return uint16(int64(math.Round(turns*(1<<yawBits))) & (1<<yawBits - 1))
}

func quantizePitch(radians float32) int16 {
	limit := float64(int32(1)<<(pitchBits-1) - 1)
	limited := max(-math.Pi/2, min(math.Pi/2, float64(radians)))
	return int16(math.Round(limited / (math.Pi / 2) * limit))
}
