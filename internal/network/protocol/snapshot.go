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

	// SnapshotBudget is the size of the largest snapshot datagram; it leaves
	// room below the transport limit (ARCHITECTURE.md, 6.6).
	SnapshotBudget = 1100

	// PositionUnitsPerMetre gives 2 mm steps: X and Z cover ±2048 m, Y ±512 m.
	PositionUnitsPerMetre = 512
	// VelocityUnitsPerMetre gives 1/32 m/s steps up to ±64 m/s.
	VelocityUnitsPerMetre = 32

	soldierCountBits = 10
	removedCountBits = 8
	teamBits         = 2
	flagsBits        = 8
	horizontalBits   = 21
	verticalBits     = 19
	positionBits     = 2*horizontalBits + verticalBits
	velocityBits     = 12
	yawBits          = 12
	pitchBits        = 10

	// Bots are drawn but never predicted, so they get by with coarser velocity
	// and angles: steps of 1/8 m/s, 256 yaw steps and 64 pitch steps, and no
	// vertical velocity. Their values keep the units of the full fields.
	botVelocityBits = 8
	botVelocityStep = 4
	botYawBits      = 8
	botPitchBits    = 6
	botAngleStep    = 1 << (yawBits - botYawBits)
)

type SoldierFlags uint8

const (
	SoldierAlive SoldierFlags = 1 << iota
	SoldierGrounded
)

// SoldierState is a soldier as every client sees it, already quantized, so it
// encodes without loss. Health and ammo of other soldiers are not sent.
type SoldierState struct {
	ID       game.SoldierID
	Bot      bool
	Team     game.Team
	Flags    SoldierFlags
	Position [3]int32 // 1/512 m; X and Z fit 21 bits, Y 19 bits
	Velocity [3]int16 // 1/32 m/s, 12 bits each; a bot's in steps of 4, without Y
	Yaw      uint16   // 12 bits of a full turn; a bot's in steps of 16
	Pitch    int16    // 10 bits over [-π/2, π/2]; a bot's in steps of 16
	Weapon   uint8    // 4 bits
}

// NewSoldierState quantizes a soldier. It fails when the soldier is outside the
// range the protocol can represent, which means it left the map.
func NewSoldierState(soldier *game.Soldier) (SoldierState, error) {
	state := SoldierState{ID: soldier.ID, Team: soldier.Team, Bot: soldier.Controller.Kind == game.ControllerBot}
	if soldier.Alive {
		state.Flags |= SoldierAlive
	}
	if soldier.Grounded {
		state.Flags |= SoldierGrounded
	}
	position := [3]float32{soldier.Position.X, soldier.Position.Y, soldier.Position.Z}
	velocity := [3]float32{soldier.Velocity.X, soldier.Velocity.Y, soldier.Velocity.Z}
	if !finite(position) || !finite(velocity) {
		return SoldierState{}, fmt.Errorf("soldier %#04x: %w", soldier.ID, ErrInvalidFloat)
	}
	for i := range 3 {
		state.Position[i] = int32(max(math.MinInt32, min(math.MaxInt32, math.Round(float64(position[i])*PositionUnitsPerMetre))))
	}
	if state.Bot {
		state.Velocity = [3]int16{
			quantizeVelocity(velocity[0], botVelocityStep, botVelocityBits), 0,
			quantizeVelocity(velocity[2], botVelocityStep, botVelocityBits),
		}
		state.Yaw = quantizeTurn(soldier.Yaw, botYawBits)
		state.Pitch = quantizePitch(soldier.Pitch, botPitchBits)
	} else {
		for i := range 3 {
			state.Velocity[i] = quantizeVelocity(velocity[i], 1, velocityBits)
		}
		state.Yaw = quantizeTurn(soldier.Yaw, yawBits)
		state.Pitch = quantizePitch(soldier.Pitch, pitchBits)
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
	if s.Bot {
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
	case s.Yaw >= 1<<yawBits || s.Weapon >= 1<<weaponBits:
		return fmt.Errorf("soldier %#04x yaw or weapon is out of range", s.ID)
	}
	if s.Bot {
		if s.Velocity[1] != 0 || !onGrid(int32(s.Velocity[0]), botVelocityStep, botVelocityBits) ||
			!onGrid(int32(s.Velocity[2]), botVelocityStep, botVelocityBits) ||
			s.Yaw%botAngleStep != 0 || !onGrid(int32(s.Pitch), botAngleStep, botPitchBits) {
			return fmt.Errorf("bot %#04x has velocity or angles finer than a bot's", s.ID)
		}
		return nil
	}
	if !fitsSigned(int32(s.Velocity[0]), velocityBits) || !fitsSigned(int32(s.Velocity[1]), velocityBits) ||
		!fitsSigned(int32(s.Velocity[2]), velocityBits) || !fitsSigned(int32(s.Pitch), pitchBits) {
		return fmt.Errorf("soldier %#04x velocity or pitch is out of range", s.ID)
	}
	return nil
}

func (s *SoldierState) writePosition(w *BitWriter) {
	w.WriteSigned(s.Position[0], horizontalBits)
	w.WriteSigned(s.Position[1], verticalBits)
	w.WriteSigned(s.Position[2], horizontalBits)
}

func (s *SoldierState) readPosition(r *BitReader) {
	s.Position[0] = r.ReadSigned(horizontalBits)
	s.Position[1] = r.ReadSigned(verticalBits)
	s.Position[2] = r.ReadSigned(horizontalBits)
}

func (s *SoldierState) velocityBits() int {
	if s.Bot {
		return 2 * botVelocityBits
	}
	return 3 * velocityBits
}

func (s *SoldierState) writeVelocity(w *BitWriter) {
	if s.Bot {
		w.WriteSigned(int32(s.Velocity[0]/botVelocityStep), botVelocityBits)
		w.WriteSigned(int32(s.Velocity[2]/botVelocityStep), botVelocityBits)
		return
	}
	for _, v := range s.Velocity {
		w.WriteSigned(int32(v), velocityBits)
	}
}

func (s *SoldierState) readVelocity(r *BitReader) {
	if s.Bot {
		s.Velocity[0] = int16(r.ReadSigned(botVelocityBits) * botVelocityStep)
		s.Velocity[2] = int16(r.ReadSigned(botVelocityBits) * botVelocityStep)
		return
	}
	for i := range s.Velocity {
		s.Velocity[i] = int16(r.ReadSigned(velocityBits))
	}
}

func (s *SoldierState) angleBits() int {
	if s.Bot {
		return botYawBits + botPitchBits
	}
	return yawBits + pitchBits
}

func (s *SoldierState) writeAngles(w *BitWriter) {
	if s.Bot {
		w.WriteBits(uint32(s.Yaw/botAngleStep), botYawBits)
		w.WriteSigned(int32(s.Pitch/botAngleStep), botPitchBits)
		return
	}
	w.WriteBits(uint32(s.Yaw), yawBits)
	w.WriteSigned(int32(s.Pitch), pitchBits)
}

func (s *SoldierState) readAngles(r *BitReader) {
	if s.Bot {
		s.Yaw = uint16(r.ReadBits(botYawBits) * botAngleStep)
		s.Pitch = int16(r.ReadSigned(botPitchBits) * botAngleStep)
		return
	}
	s.Yaw = uint16(r.ReadBits(yawBits))
	s.Pitch = int16(r.ReadSigned(pitchBits))
}

// NoInput is the InputLead of a player whose commands have not arrived yet.
const NoInput = math.MinInt8

// PlayerState is the private part of a snapshot for the player who receives it.
// Position and velocity keep full precision for reconciliation and are only
// sent while the player has a soldier.
type PlayerState struct {
	Processed         bool
	LastProcessedTick game.Tick
	// InputLead is how many ticks the newest command the server had from the
	// player was ahead of the tick when it ran; negative when commands come
	// late, NoInput before the first. The client speeds its ticks up or slows
	// them down to keep it at 2.
	InputLead int8
	Soldier   game.SoldierID
	Position  physics.Vec3
	Velocity  physics.Vec3
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

func (p *PlayerState) bits() int {
	bits := 1 + 8 + 16
	if p.Processed {
		bits += 32
	}
	if p.Soldier != 0 {
		bits += 6 * 32
	}
	return bits
}

func (p *PlayerState) write(w *BitWriter) {
	w.WriteBool(p.Processed)
	if p.Processed {
		w.WriteBits(uint32(p.LastProcessedTick), 32)
	}
	w.WriteSigned(int32(p.InputLead), 8)
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
	p.InputLead = int8(r.ReadSigned(8))
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

// Snapshot is one server datagram. A snapshot of the world may take several,
// and a soldier missing from one is not removed: the server sends each soldier
// as often as its priority asks, and removal is explicit.
type Snapshot struct {
	// Sequence numbers every datagram; deltas name their base by it.
	Sequence   uint16
	ServerTick game.Tick
	Player     PlayerState
	// Soldiers are in ascending slot order, which keeps their identifiers
	// short. SnapshotPacker builds them so.
	Soldiers []SoldierRecord
	Removed  []game.SoldierID
}

func (*Snapshot) Type() MessageType { return MessageSnapshot }

// fixedBits is the size of everything but the soldier records.
func (m *Snapshot) fixedBits() int {
	return 8 + 16 + 32 + m.Player.bits() + soldierCountBits + removedCountBits + 16*len(m.Removed)
}

func (m *Snapshot) Encode(dst []byte) ([]byte, error) {
	if len(m.Soldiers) > MaxSnapshotSoldiers || len(m.Removed) > MaxSnapshotRemoved {
		return dst, fmt.Errorf("snapshot with %d soldiers and %d removals is too large", len(m.Soldiers), len(m.Removed))
	}
	if err := m.Player.validate(); err != nil {
		return dst, err
	}
	previous := -1
	for i := range m.Soldiers {
		if err := m.Soldiers[i].validate(); err != nil {
			return dst, err
		}
		slot := m.Soldiers[i].State.ID.Slot()
		if slot <= previous {
			return dst, errors.New("snapshot soldiers must be in ascending slot order")
		}
		previous = slot
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
	previous = -1
	for i := range m.Soldiers {
		m.Soldiers[i].write(&w, previous)
		previous = m.Soldiers[i].State.ID.Slot()
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
	if uint(count)*minRecordBits > r.Remaining() {
		r.Fail(ErrShortMessage)
	}
	previous := -1
	for range count {
		if r.Err() != nil {
			break
		}
		m.Soldiers = append(m.Soldiers, SoldierRecord{})
		record := &m.Soldiers[len(m.Soldiers)-1]
		record.read(&r, previous)
		previous = record.State.ID.Slot()
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

// onGrid reports whether value is a multiple of step whose quotient fits bits.
func onGrid(value, step int32, bits uint) bool {
	return value%step == 0 && fitsSigned(value/step, bits)
}

// quantizeTurn rounds an angle to one of 2^bits steps of a full turn, in the
// units of a full-precision yaw.
func quantizeTurn(radians float32, bits uint) uint16 {
	turns := float64(radians) / (2 * math.Pi)
	turns -= math.Floor(turns)
	return uint16(int64(math.Round(turns*float64(int64(1)<<bits)))&(1<<bits-1)) << (yawBits - bits)
}

// quantizePitch rounds a pitch to bits signed steps over [-π/2, π/2], in the
// units of a full-precision pitch.
func quantizePitch(radians float32, bits uint) int16 {
	step := float64(int32(1) << (pitchBits - bits))
	limit := float64(int32(1)<<(pitchBits-1) - 1)
	steps := math.Floor(limit / step)
	limited := max(-math.Pi/2, min(math.Pi/2, float64(radians)))
	return int16(max(-steps, min(steps, math.Round(limited/(math.Pi/2)*limit/step))) * step)
}

// quantizeVelocity rounds a velocity to steps of step/32 m/s, clamped to what
// bits signed steps hold.
func quantizeVelocity(value float32, step int32, bits uint) int16 {
	limit := float64(int32(1)<<(bits-1) - 1)
	return int16(int32(max(-limit, min(limit, math.Round(float64(value)*VelocityUnitsPerMetre/float64(step))))) * step)
}
