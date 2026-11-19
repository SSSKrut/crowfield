package protocol

import (
	"errors"
	"fmt"

	"ravenfield/internal/game"
)

// MaxCommandsPerInput limits how many recent commands one datagram repeats.
const MaxCommandsPerInput = 8

const (
	commandCountBits = 4
	weaponBits       = 4
)

// InputPacket is the client's datagram for one tick. It repeats the newest
// commands, so a lost datagram is covered by the next one, and acknowledges
// the snapshot datagrams received so far.
type InputPacket struct {
	HasAck      bool
	AckSequence uint16 // newest snapshot datagram received
	AckBits     uint32 // bit i is set when AckSequence-1-i was received too
	Commands    []game.InputCommand
}

func (*InputPacket) Type() MessageType { return MessageInput }

// Encode requires consecutive command ticks, oldest first. AckSequence and
// AckBits are not sent without HasAck.
func (m *InputPacket) Encode(dst []byte) ([]byte, error) {
	if len(m.Commands) > MaxCommandsPerInput {
		return dst, fmt.Errorf("%d commands in one input, at most %d", len(m.Commands), MaxCommandsPerInput)
	}
	for i, command := range m.Commands {
		if command.Tick != m.Commands[0].Tick+game.Tick(i) {
			return dst, errors.New("input commands must have consecutive ticks")
		}
		if command.Weapon >= 1<<weaponBits {
			return dst, fmt.Errorf("weapon slot %d is out of range", command.Weapon)
		}
	}
	w := startWriting(dst, MessageInput)
	w.WriteBool(m.HasAck)
	if m.HasAck {
		w.WriteBits(uint32(m.AckSequence), 16)
		w.WriteBits(m.AckBits, 32)
	}
	w.WriteBits(uint32(len(m.Commands)), commandCountBits)
	if len(m.Commands) > 0 {
		w.WriteBits(uint32(m.Commands[0].Tick), 32)
	}
	for _, command := range m.Commands {
		w.WriteSigned(int32(command.MoveForward), 8)
		w.WriteSigned(int32(command.MoveRight), 8)
		w.WriteBits(uint32(command.Yaw), 16)
		w.WriteSigned(int32(command.Pitch), 16)
		w.WriteBits(uint32(command.Buttons), 16)
		w.WriteBits(uint32(command.Weapon), weaponBits)
		w.WriteBits(uint32(command.ViewDelta), 8)
		w.WriteBits(uint32(command.ViewFrac), 8)
	}
	return w.Bytes(), nil
}

func (m *InputPacket) Decode(data []byte) error {
	r := startReading(data, MessageInput)
	m.HasAck = r.ReadBool()
	m.AckSequence, m.AckBits = 0, 0
	if m.HasAck {
		m.AckSequence = uint16(r.ReadBits(16))
		m.AckBits = r.ReadBits(32)
	}
	count := int(r.ReadBits(commandCountBits))
	if count > MaxCommandsPerInput {
		r.Fail(fmt.Errorf("%d commands in one input, at most %d", count, MaxCommandsPerInput))
	}
	m.Commands = m.Commands[:0]
	if count == 0 || r.Err() != nil {
		return r.Finish()
	}
	first := game.Tick(r.ReadBits(32))
	for i := range count {
		var command game.InputCommand
		command.Tick = first + game.Tick(i)
		command.MoveForward = int8(r.ReadSigned(8))
		command.MoveRight = int8(r.ReadSigned(8))
		command.Yaw = uint16(r.ReadBits(16))
		command.Pitch = int16(r.ReadSigned(16))
		command.Buttons = game.Buttons(r.ReadBits(16))
		command.Weapon = uint8(r.ReadBits(weaponBits))
		command.ViewDelta = uint8(r.ReadBits(8))
		command.ViewFrac = uint8(r.ReadBits(8))
		m.Commands = append(m.Commands, command)
	}
	return r.Finish()
}
