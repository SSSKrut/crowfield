// Package protocol defines the binary encoding of every network message. Each
// message writes its fields explicitly, so changing a Go struct never changes
// the wire format by accident; any encoding change bumps ProtocolVersion.
//
// Decoding is strict: a message that decodes without error encodes back to the
// same bytes. Values that are valid on the wire but break game rules are not
// rejected here; the receiver sanitizes them (see game.InputCommand.Sanitize).
package protocol

import (
	"errors"
	"fmt"
)

const ProtocolVersion = 5

type MessageType uint8

const (
	MessageHello MessageType = iota + 1
	MessageWelcome
	MessageReject
	MessageReady
	MessageInput
	MessageSnapshot
	MessageRespawn
)

func (t MessageType) String() string {
	switch t {
	case MessageHello:
		return "hello"
	case MessageWelcome:
		return "welcome"
	case MessageReject:
		return "reject"
	case MessageReady:
		return "ready"
	case MessageInput:
		return "input"
	case MessageSnapshot:
		return "snapshot"
	case MessageRespawn:
		return "respawn"
	}
	return fmt.Sprintf("message %d", uint8(t))
}

// Message is one datagram or one message of a reliable stream. Every encoding
// starts with the message type in its first byte; framing on streams belongs
// to the transport.
type Message interface {
	Type() MessageType
	// Encode appends the message to dst.
	Encode(dst []byte) ([]byte, error)
	// Decode replaces the message with the one in data, reusing its slices.
	// After an error the content of the message is undefined.
	Decode(data []byte) error
}

var ErrUnknownMessage = errors.New("unknown message type")

func PeekType(data []byte) (MessageType, error) {
	if len(data) == 0 {
		return 0, ErrShortMessage
	}
	t := MessageType(data[0])
	if t < MessageHello || t > MessageRespawn {
		return t, ErrUnknownMessage
	}
	return t, nil
}

// New returns an empty message of the given type to decode into.
func New(t MessageType) (Message, error) {
	switch t {
	case MessageHello:
		return &Hello{}, nil
	case MessageWelcome:
		return &Welcome{}, nil
	case MessageReject:
		return &Reject{}, nil
	case MessageReady:
		return &Ready{}, nil
	case MessageInput:
		return &InputPacket{}, nil
	case MessageSnapshot:
		return &Snapshot{}, nil
	case MessageRespawn:
		return &Respawn{}, nil
	}
	return nil, ErrUnknownMessage
}

func startWriting(dst []byte, t MessageType) BitWriter {
	var w BitWriter
	w.Reset(dst)
	w.WriteBits(uint32(t), 8)
	return w
}

func startReading(data []byte, t MessageType) BitReader {
	var r BitReader
	r.Reset(data)
	if got := MessageType(r.ReadBits(8)); r.err == nil && got != t {
		r.Fail(fmt.Errorf("expected %s, got %s", t, got))
	}
	return r
}
