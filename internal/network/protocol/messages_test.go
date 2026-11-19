package protocol

import (
	"bytes"
	"errors"
	"math"
	"reflect"
	"strings"
	"testing"

	"ravenfield/internal/game"
	"ravenfield/internal/physics"
)

func sampleMessages() []Message {
	return []Message{
		&Hello{ProtocolVersion: ProtocolVersion, Build: 0x0123456789ABCDEF, Name: "Ворон", Password: "secret"},
		&Hello{},
		&Welcome{
			Player: game.MaxPlayers - 1, SessionToken: [16]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
			TickRate: game.TickRate, SnapshotRate: 20, ServerTick: 123456, Map: "prototype",
			MapHash: 0xFEEDFACECAFEBEEF, TuningHash: 42, MatchSeed: math.MaxUint64,
		},
		&Reject{Reason: RejectFull, Message: "сервер заполнен"},
		&Ready{},
		&Respawn{},
		&InputPacket{},
		&InputPacket{HasAck: true, AckSequence: math.MaxUint16, AckBits: 0xDEADBEEF, Commands: sampleCommands(MaxCommandsPerInput, math.MaxUint32-3)},
		sampleSnapshot(3),
		&Snapshot{Sequence: 1, ServerTick: 2, Player: PlayerState{BufferedCommands: -3}},
	}
}

// sampleCommands wraps the tick counter on purpose and mixes extreme values.
func sampleCommands(count int, first game.Tick) []game.InputCommand {
	commands := make([]game.InputCommand, count)
	for i := range commands {
		tick := first + game.Tick(i)
		commands[i] = game.NewInputCommand(tick, float32(i)/4-1, 0.5, float32(i), float32(i)/5-0.7, game.ButtonSprint|game.ButtonFire)
		commands[i].Weapon = uint8(i)
		commands[i].ViewDelta = uint8(20 + i)
		commands[i].ViewFrac = uint8(i * 30)
	}
	commands[0].MoveForward, commands[0].Pitch, commands[0].Buttons = -128, -32768, math.MaxUint16
	commands[0].Weapon, commands[0].ViewDelta = 15, 255
	return commands
}

func sampleSnapshot(soldiers int) *Snapshot {
	snapshot := &Snapshot{
		Sequence: 777, ServerTick: 99999,
		Player: PlayerState{
			Processed: true, LastProcessedTick: 99990, BufferedCommands: 2, Soldier: soldierID(3, 2),
			Position: physics.V(1.25, 0.002, -7.75), Velocity: physics.V(0, -0.5, -8),
		},
		Removed: []game.SoldierID{soldierID(9, 15), soldierID(4095, 1)},
	}
	for i := range soldiers {
		snapshot.Soldiers = append(snapshot.Soldiers, SoldierState{
			ID: soldierID(i, uint8(1+i%15)), Team: game.Team(i % 3), Flags: SoldierFlags(i * 37),
			Position: [3]int32{-1 << 20, (1 << 18) - 1 - int32(i), int32(i * 1000)},
			Velocity: [3]int16{-2048, 2047, int16(i)},
			Yaw:      4095 - uint16(i), Pitch: int16(-512 + i), Weapon: uint8(i % 16),
		})
	}
	return snapshot
}

func soldierID(slot int, generation uint8) game.SoldierID {
	return game.SoldierID(slot) | game.SoldierID(generation)<<12
}

func TestMessagesRoundTrip(t *testing.T) {
	for _, message := range sampleMessages() {
		data, err := message.Encode(nil)
		if err != nil {
			t.Fatalf("%s: %v", message.Type(), err)
		}
		messageType, err := PeekType(data)
		if err != nil || messageType != message.Type() {
			t.Fatalf("%s: peeked %s, %v", message.Type(), messageType, err)
		}
		decoded, err := New(messageType)
		if err != nil {
			t.Fatal(err)
		}
		if err := decoded.Decode(data); err != nil {
			t.Fatalf("%s: %v", message.Type(), err)
		}
		if !reflect.DeepEqual(decoded, message) {
			t.Errorf("%s changed in a round trip:\n%+v\n%+v", message.Type(), decoded, message)
		}
		again, err := decoded.Encode(nil)
		if err != nil || !bytes.Equal(again, data) {
			t.Errorf("%s encodes differently after decoding: %v", message.Type(), err)
		}
	}
}

func TestDecodeReplacesPreviousContent(t *testing.T) {
	large, err := sampleSnapshot(20).Encode(nil)
	if err != nil {
		t.Fatal(err)
	}
	small := &Snapshot{Sequence: 5, Player: PlayerState{Processed: true, LastProcessedTick: 3}}
	smallData, err := small.Encode(nil)
	if err != nil {
		t.Fatal(err)
	}
	var reused Snapshot
	if err := reused.Decode(large); err != nil {
		t.Fatal(err)
	}
	if err := reused.Decode(smallData); err != nil {
		t.Fatal(err)
	}
	if reused.Sequence != 5 || len(reused.Soldiers) != 0 || len(reused.Removed) != 0 || reused.Player != small.Player {
		t.Errorf("old content survived: %+v", reused)
	}
}

func TestDecodeRejectsDamagedMessages(t *testing.T) {
	for _, message := range sampleMessages() {
		data, err := message.Encode(nil)
		if err != nil {
			t.Fatal(err)
		}
		for length := range data {
			if err := message.Decode(data[:length]); err == nil {
				t.Errorf("%s: %d of %d bytes decoded", message.Type(), length, len(data))
			}
		}
		if err := message.Decode(append(bytes.Clone(data), 0)); !errors.Is(err, ErrTrailingData) {
			t.Errorf("%s: trailing byte gave %v", message.Type(), err)
		}
	}
	ready, _ := (&Ready{}).Encode(nil)
	if err := (&Hello{}).Decode(ready); err == nil {
		t.Error("hello decoded a ready message")
	}
	for _, data := range [][]byte{{0}, {byte(MessageRespawn) + 1}} {
		if _, err := PeekType(data); !errors.Is(err, ErrUnknownMessage) {
			t.Errorf("type %d: %v", data[0], err)
		}
	}
	if _, err := New(0); !errors.Is(err, ErrUnknownMessage) {
		t.Error("New accepted type 0")
	}
}

func TestDecodeRejectsInvalidFields(t *testing.T) {
	cases := map[string]func(w *BitWriter){
		"nine commands": func(w *BitWriter) {
			w.WriteBool(false)
			w.WriteBits(MaxCommandsPerInput+1, commandCountBits)
		},
		"soldier without generation": func(w *BitWriter) {
			writeSnapshotHeader(w, 1)
			state := sampleSnapshot(1).Soldiers[0]
			state.ID = 5
			state.write(w)
			w.WriteBits(0, removedCountBits)
		},
		"unknown team": func(w *BitWriter) {
			writeSnapshotHeader(w, 1)
			state := sampleSnapshot(1).Soldiers[0]
			state.Team = 3
			state.write(w)
			w.WriteBits(0, removedCountBits)
		},
		"nan player position": func(w *BitWriter) {
			w.WriteBits(1, 16)
			w.WriteBits(1, 32)
			w.WriteBool(false)
			w.WriteSigned(0, 8)
			w.WriteBits(uint32(soldierID(1, 1)), 16)
			w.WriteFloat32(float32(math.NaN()))
			for range 5 {
				w.WriteFloat32(0)
			}
			w.WriteBits(0, soldierCountBits)
			w.WriteBits(0, removedCountBits)
		},
		"more soldiers than bytes": func(w *BitWriter) {
			writeSnapshotHeader(w, MaxSnapshotSoldiers)
		},
		"removed without generation": func(w *BitWriter) {
			writeSnapshotHeader(w, 0)
			w.WriteBits(1, removedCountBits)
			w.WriteBits(7, 16)
		},
	}
	for name, write := range cases {
		messageType := MessageSnapshot
		if name == "nine commands" {
			messageType = MessageInput
		}
		w := startWriting(nil, messageType)
		write(&w)
		message, _ := New(messageType)
		if err := message.Decode(w.Bytes()); err == nil {
			t.Errorf("%s: decoded", name)
		}
	}
}

func writeSnapshotHeader(w *BitWriter, soldiers int) {
	w.WriteBits(1, 16)
	w.WriteBits(1, 32)
	(&PlayerState{}).write(w)
	w.WriteBits(uint32(soldiers), soldierCountBits)
}

func TestEncodeRejectsInvalidMessages(t *testing.T) {
	outside := sampleSnapshot(1)
	outside.Soldiers[0].Position[1] = 1 << 18
	noGeneration := sampleSnapshot(1)
	noGeneration.Soldiers[0].ID = 12
	removed := sampleSnapshot(0)
	removed.Removed = []game.SoldierID{3}
	player := sampleSnapshot(0)
	player.Player.Soldier = 9
	nan := sampleSnapshot(0)
	nan.Player.Velocity.Y = float32(math.Inf(1))
	gap := sampleCommands(3, 10)
	gap[2].Tick++
	weapon := sampleCommands(1, 10)
	weapon[0].Weapon = 16
	for name, message := range map[string]Message{
		"long name":           &Hello{Name: strings.Repeat("я", MaxNameBytes)},
		"bad utf-8 password":  &Hello{Password: "\xff"},
		"player out of range": &Welcome{Player: game.MaxPlayers},
		"long map":            &Welcome{Map: strings.Repeat("m", MaxMapBytes+1)},
		"long reject":         &Reject{Message: strings.Repeat("r", MaxRejectMessageBytes+1)},
		"too many commands":   &InputPacket{Commands: sampleCommands(MaxCommandsPerInput+1, 0)},
		"tick gap":            &InputPacket{Commands: gap},
		"weapon out of range": &InputPacket{Commands: weapon},
		"soldier outside map": outside,
		"soldier no gen":      noGeneration,
		"removed no gen":      removed,
		"player no gen":       player,
		"infinite velocity":   nan,
		"too many soldiers":   &Snapshot{Soldiers: make([]SoldierState, MaxSnapshotSoldiers+1)},
	} {
		if data, err := message.Encode([]byte{1, 2}); err == nil || len(data) != 2 {
			t.Errorf("%s: encoded to %d bytes, err %v", name, len(data), err)
		}
	}
}

func TestDecodeAndEncodeDoNotAllocate(t *testing.T) {
	input := &InputPacket{HasAck: true, Commands: sampleCommands(MaxCommandsPerInput, 100)}
	snapshot := sampleSnapshot(50)
	for _, message := range []Message{input, snapshot} {
		data, err := message.Encode(nil)
		if err != nil {
			t.Fatal(err)
		}
		buffer := make([]byte, 0, 2*len(data))
		decoded, _ := New(message.Type())
		if err := decoded.Decode(data); err != nil {
			t.Fatal(err)
		}
		if allocs := testing.AllocsPerRun(100, func() { _ = decoded.Decode(data) }); allocs != 0 {
			t.Errorf("%s: decoding into a used message allocates %.0f times", message.Type(), allocs)
		}
		if allocs := testing.AllocsPerRun(100, func() { _, _ = message.Encode(buffer[:0]) }); allocs != 0 {
			t.Errorf("%s: encoding into a large buffer allocates %.0f times", message.Type(), allocs)
		}
	}
}

// SnapshotCapacity must be exact: the server fills datagrams up to it.
func TestSnapshotCapacity(t *testing.T) {
	if got := SnapshotCapacity(SnapshotBudget, 0); got != 56 {
		t.Errorf("a %d-byte datagram holds %d soldiers, want 56", SnapshotBudget, got)
	}
	for _, removed := range []int{0, 1, 2, 10, 60} {
		capacity := SnapshotCapacity(SnapshotBudget, removed)
		for _, c := range []struct {
			soldiers int
			fits     bool
		}{{capacity, true}, {capacity + 1, false}} {
			snapshot := sampleSnapshot(c.soldiers)
			snapshot.Removed = make([]game.SoldierID, removed)
			for i := range snapshot.Removed {
				snapshot.Removed[i] = soldierID(i, 1)
			}
			data, err := snapshot.Encode(nil)
			if err != nil {
				t.Fatal(err)
			}
			if fits := len(data) <= SnapshotBudget; fits != c.fits {
				t.Errorf("%d soldiers and %d removals take %d bytes", c.soldiers, removed, len(data))
			}
		}
	}
	if SnapshotCapacity(10, 0) != 0 {
		t.Error("a tiny budget holds soldiers")
	}
}
