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
		&Hello{Name: "back", Token: [16]byte{0: 1, 15: 0xFF}},
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
		&Snapshot{Sequence: 1, ServerTick: 2, Player: PlayerState{InputLead: -3}},
		&Snapshot{Sequence: 3, ServerTick: 4, Player: PlayerState{Soldier: soldierID(1, 1), Health: game.MaxHealth, Arsenal: readyArsenal()}},
		&Snapshot{Sequence: 5, ServerTick: 6, Player: PlayerState{Soldier: soldierID(2, 3), Respawn: 299, Arsenal: readyArsenal()}},
	}
}

// busyArsenal reloads its second weapon and has an empty slot.
func busyArsenal() game.Arsenal {
	return game.Arsenal{
		Weapons: game.Loadout{game.WeaponPistol, game.WeaponAssaultRifle},
		Ammo:    [game.MaxLoadout]game.Ammo{{Magazine: 255, Reserve: 1023}, {Magazine: 3, Reserve: 0}},
		Current: 1, Action: game.WeaponReloading, ActionTicks: 255, Cooldown: 6, Trigger: true,
		Bloom: 0.01, KickPitch: 0.2, KickYaw: -0.05,
	}
}

func readyArsenal() game.Arsenal {
	weapons := game.DefaultWeapons()
	return game.NewArsenal(game.DefaultLoadout(), &weapons)
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

// sampleSnapshot mixes full records of humans and bots with every kind of
// delta, and short and long slot gaps.
func sampleSnapshot(soldiers int) *Snapshot {
	snapshot := &Snapshot{
		Sequence: 777, ServerTick: 99999,
		Player: PlayerState{
			Processed: true, LastProcessedTick: 99990, InputLead: 2, Soldier: soldierID(3, 2),
			Position: physics.V(1.25, 0.002, -7.75), Velocity: physics.V(0, -0.5, -8), Health: 73, Arsenal: busyArsenal(),
		},
		Removed: []game.SoldierID{soldierID(9, 15), soldierID(4095, 1)},
	}
	slot := -1
	for i := range soldiers {
		slot += 1 + i*5%11
		state := SoldierState{
			ID: soldierID(slot, uint8(1+i%15)), Bot: i%2 == 1, Team: game.Team(i % 3), Flags: SoldierFlags(i * 37),
			Position: [3]int32{-1 << 20, (1 << 18) - 1 - int32(i), int32(i * 1000)}, Weapon: uint8(i % 16),
		}
		if state.Bot {
			state.Velocity, state.Yaw, state.Pitch = [3]int16{-512, 0, int16(4 * i)}, uint16(4080-16*i), int16(-512+16*i)
		} else {
			state.Velocity, state.Yaw, state.Pitch = [3]int16{-2048, 2047, int16(i)}, 4095-uint16(i), int16(-512+i)
		}
		record := SoldierRecord{State: state}
		switch i % 4 {
		case 1:
			record = delta(state, uint8(1+i), FieldMove|FieldAngles)
			record.Move = [3]int32{int32(i) - 30, 0, 1 << 14}
		case 2:
			record = delta(state, MaxBaseAge, FieldPosition|FieldVelocity|FieldFlags|FieldWeapon)
		case 3:
			record = delta(state, uint8(i), 0)
		}
		snapshot.Soldiers = append(snapshot.Soldiers, record)
	}
	return snapshot
}

// delta makes a delta record that carries the given fields of a state, with
// the other fields zero, as decoding leaves them.
func delta(state SoldierState, base uint8, fields RecordFields) SoldierRecord {
	carried := SoldierState{ID: state.ID, Bot: state.Bot}
	if fields&FieldPosition != 0 {
		carried.Position = state.Position
	}
	if fields&FieldVelocity != 0 {
		carried.Velocity = state.Velocity
	}
	if fields&FieldAngles != 0 {
		carried.Yaw, carried.Pitch = state.Yaw, state.Pitch
	}
	if fields&FieldFlags != 0 {
		carried.Flags = state.Flags
	}
	if fields&FieldWeapon != 0 {
		carried.Weapon = state.Weapon
	}
	return SoldierRecord{State: carried, Base: base, Fields: fields}
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
	full := sampleSnapshot(1).Soldiers[0]
	// body writes a record after a slot gap written by hand.
	body := func(w *BitWriter, long bool, gap uint32, record SoldierRecord) {
		w.WriteBool(long)
		if long {
			w.WriteBits(gap, longGapBits)
		} else {
			w.WriteBits(gap, shortGapBits)
		}
		record.writeBody(w)
	}
	cases := map[string]func(w *BitWriter){
		"nine commands": func(w *BitWriter) {
			w.WriteBool(false)
			w.WriteBits(MaxCommandsPerInput+1, commandCountBits)
		},
		"zero token": func(w *BitWriter) {
			w.WriteBits(ProtocolVersion, 16)
			w.WriteUint64(0)
			w.WriteString("", nameLengthBits)
			w.WriteString("", passwordLengthBits)
			w.WriteBool(true)
			w.WriteBytes(make([]byte, 16))
		},
		"soldier without generation": func(w *BitWriter) {
			writeSnapshotHeader(w, 1)
			record := full
			record.State.ID = 5
			record.write(w, -1)
			w.WriteBits(0, removedCountBits)
		},
		"unknown team": func(w *BitWriter) {
			writeSnapshotHeader(w, 1)
			record := full
			record.State.Team = 3
			record.write(w, -1)
			w.WriteBits(0, removedCountBits)
		},
		"short gap written long": func(w *BitWriter) {
			writeSnapshotHeader(w, 1)
			body(w, true, 7, full)
			w.WriteBits(0, removedCountBits)
		},
		"slot beyond the range": func(w *BitWriter) {
			writeSnapshotHeader(w, 2)
			last := full
			last.State.ID = soldierID(game.MaxSoldiers-1, 1)
			last.write(w, -1)
			body(w, false, 0, full)
			w.WriteBits(0, removedCountBits)
		},
		"unknown position mode": func(w *BitWriter) {
			writeDeltaHead(w)
			w.WriteBits(3, 2)
			w.WriteBits(0, 4)
			w.WriteBits(0, removedCountBits)
		},
		"move wider than needed": func(w *BitWriter) {
			writeMove(w, 10, 1, -2, 3)
		},
		"empty move": func(w *BitWriter) {
			writeMove(w, 1, 0, 0, 0)
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
		"unknown weapon":    arsenalCase(func(a *game.Arsenal) { a.Weapons[2] = 15 }),
		"slot out of range": arsenalCase(func(a *game.Arsenal) { a.Current = 3 }),
		"unknown action":    arsenalCase(func(a *game.Arsenal) { a.Action = 3 }),
		"busy without time": arsenalCase(func(a *game.Arsenal) { a.ActionTicks = 0 }),
		"infinite kick":     arsenalCase(func(a *game.Arsenal) { a.KickYaw = float32(math.Inf(-1)) }),
		"too healthy":       healthCase(game.MaxHealth+1, 0),
		"dead for ever":     healthCase(0, 0),
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
		switch name {
		case "nine commands":
			messageType = MessageInput
		case "zero token":
			messageType = MessageHello
		}
		w := startWriting(nil, messageType)
		write(&w)
		message, _ := New(messageType)
		if err := message.Decode(w.Bytes()); err == nil {
			t.Errorf("%s: decoded", name)
		}
	}
}

// arsenalCase writes a snapshot whose player has a busy arsenal changed by
// spoil, without the checks of encoding.
func arsenalCase(spoil func(*game.Arsenal)) func(w *BitWriter) {
	return func(w *BitWriter) {
		player := PlayerState{Soldier: soldierID(1, 1), Health: 1, Arsenal: busyArsenal()}
		spoil(&player.Arsenal)
		w.WriteBits(1, 16)
		w.WriteBits(1, 32)
		player.write(w)
		w.WriteBits(0, soldierCountBits)
		w.WriteBits(0, removedCountBits)
	}
}

// healthCase writes a snapshot whose player has the given health and time
// to respawn, without the checks of encoding.
func healthCase(health uint8, respawn uint16) func(w *BitWriter) {
	return func(w *BitWriter) {
		w.WriteBits(1, 16)
		w.WriteBits(1, 32)
		w.WriteBool(false)
		w.WriteSigned(0, 8)
		w.WriteBits(uint32(soldierID(1, 1)), 16)
		for range 6 {
			w.WriteFloat32(0)
		}
		w.WriteBits(uint32(health), healthBits)
		if health == 0 {
			w.WriteBits(uint32(respawn), respawnBits)
		}
		arsenal := readyArsenal()
		writeArsenal(w, &arsenal)
		w.WriteBits(0, soldierCountBits)
		w.WriteBits(0, removedCountBits)
	}
}

// writeDeltaHead starts a snapshot with one delta record, up to its position mode.
func writeDeltaHead(w *BitWriter) {
	writeSnapshotHeader(w, 1)
	w.WriteBool(false)
	w.WriteBits(0, shortGapBits)
	w.WriteBits(1, generationBits)
	w.WriteBool(false)
	w.WriteBits(1, baseBits)
}

// writeMove writes a snapshot with one delta that only moves, in the given width.
func writeMove(w *BitWriter, width uint, values ...int32) {
	writeDeltaHead(w)
	w.WriteBits(positionMoved, 2)
	w.WriteBits(uint32(width-1), moveWidthBits)
	for _, v := range values {
		w.WriteSigned(v, width)
	}
	w.WriteBits(0, 4)
	w.WriteBits(0, removedCountBits)
}

func writeSnapshotHeader(w *BitWriter, soldiers int) {
	w.WriteBits(1, 16)
	w.WriteBits(1, 32)
	(&PlayerState{}).write(w)
	w.WriteBits(uint32(soldiers), soldierCountBits)
}

func TestEncodeRejectsInvalidMessages(t *testing.T) {
	outside := sampleSnapshot(1)
	outside.Soldiers[0].State.Position[1] = 1 << 18
	noGeneration := sampleSnapshot(1)
	noGeneration.Soldiers[0].State.ID = 12
	unordered := sampleSnapshot(2)
	unordered.Soldiers[0], unordered.Soldiers[1] = unordered.Soldiers[1], unordered.Soldiers[0]
	twice := sampleSnapshot(2)
	twice.Soldiers[1].State.ID = soldierID(twice.Soldiers[0].State.ID.Slot(), 3)
	fineBot := sampleSnapshot(2)
	fineBot.Soldiers[1].State.Velocity[0]++
	bothPositions := sampleSnapshot(2)
	bothPositions.Soldiers[1].Fields |= FieldPosition
	emptyMove := sampleSnapshot(2)
	emptyMove.Soldiers[1].Move = [3]int32{}
	longMove := sampleSnapshot(2)
	longMove.Soldiers[1].Move[0] = 1 << 15
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
	armedNobody := sampleSnapshot(0)
	armedNobody.Player.Soldier, armedNobody.Player.Processed = 0, false
	ammoInEmptySlot := sampleSnapshot(0)
	ammoInEmptySlot.Player.Arsenal.Ammo[2].Magazine = 1
	reserve := sampleSnapshot(0)
	reserve.Player.Arsenal.Ammo[0].Reserve = 1024
	idleWithTime := sampleSnapshot(0)
	idleWithTime.Player.Arsenal.Action = game.WeaponReady
	aliveWaiting := sampleSnapshot(0)
	aliveWaiting.Player.Respawn = 5
	healthOfNobody := sampleSnapshot(0)
	healthOfNobody.Player = PlayerState{Health: 50}
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
		"arsenal of nobody":   armedNobody,
		"ammo in empty slot":  ammoInEmptySlot,
		"reserve too large":   reserve,
		"idle with time left": idleWithTime,
		"alive and waiting":   aliveWaiting,
		"health of nobody":    healthOfNobody,
		"too many soldiers":   &Snapshot{Soldiers: make([]SoldierRecord, MaxSnapshotSoldiers+1)},
		"unordered soldiers":  unordered,
		"same slot twice":     twice,
		"fine bot velocity":   fineBot,
		"position and move":   bothPositions,
		"empty move":          emptyMove,
		"move too long":       longMove,
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
