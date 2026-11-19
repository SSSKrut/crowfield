package protocol

import (
	"errors"
	"fmt"
	"unicode/utf8"

	"ravenfield/internal/game"
)

const (
	MaxNameBytes          = 32
	MaxPasswordBytes      = 64
	MaxMapBytes           = 64
	MaxRejectMessageBytes = 255

	nameLengthBits     = 6
	passwordLengthBits = 7
	mapLengthBits      = 7
	rejectLengthBits   = 8
	playerBits         = 4
)

// Hello is the first message of a client on the control stream.
type Hello struct {
	ProtocolVersion uint16
	Build           uint64
	Name            string
	Password        string
	// Token is the session token of a player returning after a lost
	// connection; zero for a new player.
	Token [16]byte
}

// QuitReason closes the connection of a player who leaves on purpose: the
// server frees the place at once instead of keeping it for a return.
const QuitReason = "player quit"

func (*Hello) Type() MessageType { return MessageHello }

func (m *Hello) Encode(dst []byte) ([]byte, error) {
	if err := checkText("name", m.Name, MaxNameBytes); err != nil {
		return dst, err
	}
	if err := checkText("password", m.Password, MaxPasswordBytes); err != nil {
		return dst, err
	}
	w := startWriting(dst, MessageHello)
	w.WriteBits(uint32(m.ProtocolVersion), 16)
	w.WriteUint64(m.Build)
	w.WriteString(m.Name, nameLengthBits)
	w.WriteString(m.Password, passwordLengthBits)
	w.WriteBool(m.Token != [16]byte{})
	if m.Token != [16]byte{} {
		w.WriteBytes(m.Token[:])
	}
	return w.Bytes(), nil
}

func (m *Hello) Decode(data []byte) error {
	r := startReading(data, MessageHello)
	m.ProtocolVersion = uint16(r.ReadBits(16))
	m.Build = r.ReadUint64()
	m.Name = r.ReadString(nameLengthBits, MaxNameBytes)
	m.Password = r.ReadString(passwordLengthBits, MaxPasswordBytes)
	m.Token = [16]byte{}
	if r.ReadBool() {
		r.ReadBytes(m.Token[:])
		if r.Err() == nil && m.Token == [16]byte{} {
			r.Fail(errors.New("a zero token is written as none"))
		}
	}
	return r.Finish()
}

// Welcome accepts a client. The client must refuse to play when the tick rate,
// map hash or tuning hash differ from its own: its prediction would not match.
type Welcome struct {
	Player       game.PlayerID
	SessionToken [16]byte
	TickRate     uint8
	// SnapshotRate tells the client how far apart snapshots are, which sets
	// its interpolation delay.
	SnapshotRate uint8
	ServerTick   game.Tick
	Map          string
	MapHash      uint64
	TuningHash   uint64
	MatchSeed    uint64
}

func (*Welcome) Type() MessageType { return MessageWelcome }

func (m *Welcome) Encode(dst []byte) ([]byte, error) {
	if m.Player >= game.MaxPlayers {
		return dst, fmt.Errorf("player %d is out of range", m.Player)
	}
	if err := checkText("map", m.Map, MaxMapBytes); err != nil {
		return dst, err
	}
	w := startWriting(dst, MessageWelcome)
	w.WriteBits(uint32(m.Player), playerBits)
	w.WriteBytes(m.SessionToken[:])
	w.WriteBits(uint32(m.TickRate), 8)
	w.WriteBits(uint32(m.SnapshotRate), 8)
	w.WriteBits(uint32(m.ServerTick), 32)
	w.WriteString(m.Map, mapLengthBits)
	w.WriteUint64(m.MapHash)
	w.WriteUint64(m.TuningHash)
	w.WriteUint64(m.MatchSeed)
	return w.Bytes(), nil
}

func (m *Welcome) Decode(data []byte) error {
	r := startReading(data, MessageWelcome)
	m.Player = game.PlayerID(r.ReadBits(playerBits))
	r.ReadBytes(m.SessionToken[:])
	m.TickRate = uint8(r.ReadBits(8))
	m.SnapshotRate = uint8(r.ReadBits(8))
	m.ServerTick = game.Tick(r.ReadBits(32))
	m.Map = r.ReadString(mapLengthBits, MaxMapBytes)
	m.MapHash = r.ReadUint64()
	m.TuningHash = r.ReadUint64()
	m.MatchSeed = r.ReadUint64()
	return r.Finish()
}

type RejectReason uint8

const (
	RejectVersion RejectReason = iota + 1
	RejectFull
	RejectPassword
	RejectBadRequest
)

func (r RejectReason) String() string {
	switch r {
	case RejectVersion:
		return "incompatible version"
	case RejectFull:
		return "server is full"
	case RejectPassword:
		return "wrong password"
	case RejectBadRequest:
		return "bad request"
	}
	return fmt.Sprintf("reject reason %d", uint8(r))
}

// Reject refuses a client; Message is shown to the player.
type Reject struct {
	Reason  RejectReason
	Message string
}

func (*Reject) Type() MessageType { return MessageReject }

func (m *Reject) Encode(dst []byte) ([]byte, error) {
	if err := checkText("reject message", m.Message, MaxRejectMessageBytes); err != nil {
		return dst, err
	}
	w := startWriting(dst, MessageReject)
	w.WriteBits(uint32(m.Reason), 8)
	w.WriteString(m.Message, rejectLengthBits)
	return w.Bytes(), nil
}

func (m *Reject) Decode(data []byte) error {
	r := startReading(data, MessageReject)
	m.Reason = RejectReason(r.ReadBits(8))
	m.Message = r.ReadString(rejectLengthBits, MaxRejectMessageBytes)
	return r.Finish()
}

// Ready tells the server that the client has loaded the map and can spawn.
type Ready struct{}

func (*Ready) Type() MessageType { return MessageReady }

func (m *Ready) Encode(dst []byte) ([]byte, error) {
	w := startWriting(dst, MessageReady)
	return w.Bytes(), nil
}

func (m *Ready) Decode(data []byte) error {
	r := startReading(data, MessageReady)
	return r.Finish()
}

// Respawn asks the server to place the player's soldier at a spawn point again.
type Respawn struct{}

func (*Respawn) Type() MessageType { return MessageRespawn }

func (m *Respawn) Encode(dst []byte) ([]byte, error) {
	w := startWriting(dst, MessageRespawn)
	return w.Bytes(), nil
}

func (m *Respawn) Decode(data []byte) error {
	r := startReading(data, MessageRespawn)
	return r.Finish()
}

func checkText(field, value string, maxBytes int) error {
	if len(value) > maxBytes || !utf8.ValidString(value) {
		return fmt.Errorf("%s must be UTF-8 of at most %d bytes", field, maxBytes)
	}
	return nil
}
