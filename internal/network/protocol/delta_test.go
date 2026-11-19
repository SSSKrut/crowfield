package protocol

import (
	"errors"
	"math/rand/v2"
	"testing"

	"ravenfield/internal/game"
)

// The sizes the bandwidth budget is planned with (ARCHITECTURE.md, 6.6).
func TestRecordSizes(t *testing.T) {
	human := SoldierState{ID: soldierID(1, 1), Team: game.TeamBlue, Flags: SoldierAlive}
	bot := human
	bot.Bot = true
	walked := bot
	walked.Position[0] += PositionUnitsPerMetre // a metre since the base
	turned := walked
	turned.Velocity[2], turned.Yaw = 160, 512
	fired := turned
	fired.Shots, fired.HitCount, fired.HitBox = 3, 1, 1
	for _, c := range []struct {
		name  string
		state SoldierState
		base  *SoldierState
		bits  int
	}{
		{"full human", human, nil, 166},
		{"full bot", bot, nil, 138},
		{"bot that stood still", bot, &bot, 25},
		{"bot that walked a metre", walked, &bot, 62},
		{"bot that walked and turned", turned, &bot, 92},
		{"bot that also fired and was hit", fired, &bot, 108},
	} {
		record := NewSoldierRecord(c.state, c.base, 3)
		// After a record in the previous slot, as a full datagram mostly has.
		if bits := slotBits(0) + record.bodyBits(); bits != c.bits {
			t.Errorf("%s takes %d bits, want %d", c.name, bits, c.bits)
		}
	}
}

// The packer must know the encoded size exactly, whatever order the records
// come in, and fill the datagram up to the limit.
func TestSnapshotPacker(t *testing.T) {
	random := rand.New(rand.NewPCG(1, 2))
	var packer SnapshotPacker
	snapshot := sampleSnapshot(0)
	for round := range 200 {
		limit := 100 + random.IntN(SnapshotBudget)
		snapshot.Removed = snapshot.Removed[:random.IntN(3)]
		packer.Reset(snapshot, limit)
		refused := 0
		for _, slot := range random.Perm(game.MaxSoldiers)[:300] {
			state := SoldierState{ID: soldierID(slot, 1), Bot: random.IntN(2) == 0, Position: [3]int32{int32(slot), 0, 0}}
			moved := state
			moved.Position[2] += int32(random.IntN(1 << random.IntN(16)))
			record := NewSoldierRecord(moved, &state, 1+random.IntN(MaxBaseAge))
			if random.IntN(4) == 0 {
				record = NewSoldierRecord(moved, nil, 0)
			}
			if !packer.Add(&record) {
				refused++
			}
		}
		size := packer.Finish()
		data, err := snapshot.Encode(nil)
		if err != nil {
			t.Fatal(err)
		}
		if size != len(data) || size > limit {
			t.Fatalf("round %d: the packer counted %d bytes, the snapshot takes %d, limit %d", round, size, len(data), limit)
		}
		// Every refused record was larger than the room left then, and no
		// record takes more than 22 bytes with the change to its neighbour.
		if refused > 0 && len(data)+22 < limit {
			t.Fatalf("round %d: %d of %d bytes used with records left", round, len(data), limit)
		}
	}
}

// Deltas over a lossy network: the server bases each one on the newest state
// the client acknowledged, the client resolves it against what it kept, and
// the result is always exactly the state the server sent.
func TestDeltasResolveToTheSentState(t *testing.T) {
	random := rand.New(rand.NewPCG(3, 4))
	const soldiers = 40
	type send struct {
		datagram int
		state    SoldierState
	}
	states := make([]SoldierState, soldiers)
	sends := make([][]send, soldiers)
	for i := range states {
		states[i] = SoldierState{ID: soldierID(i*3, 1), Bot: i%2 == 0, Team: game.TeamRed}
	}
	acked := map[int]bool{}
	baselines := NewBaselines()
	var packer SnapshotPacker
	var snapshot, received Snapshot
	deltas := 0
	for datagram := range 3000 {
		for i := range states {
			s := &states[i]
			s.Position[0] += int32(random.IntN(2000)) - 1000
			if random.IntN(50) == 0 {
				s.Position[1] += 1 << 17 // too far for a move
			}
			if random.IntN(3) == 0 {
				s.Yaw = uint16(random.IntN(256) * botAngleStep)
			}
			if random.IntN(7) == 0 {
				s.Flags ^= SoldierAlive
			}
			if s.Position[1] >= 1<<18 {
				s.Position[1] = 0
			}
		}
		snapshot = Snapshot{Sequence: uint16(datagram)}
		packer.Reset(&snapshot, SnapshotBudget)
		for i := range states {
			if random.IntN(3) > 0 {
				continue
			}
			var base *SoldierState
			age := 0
			for _, sent := range sends[i] {
				if acked[sent.datagram] && (base == nil || datagram-sent.datagram < age) {
					base, age = &sent.state, datagram-sent.datagram
				}
			}
			record := NewSoldierRecord(states[i], base, age)
			if record.Base != 0 {
				deltas++
			}
			if packer.Add(&record) {
				sends[i] = append(sends[i], send{datagram: datagram, state: states[i]})
				if len(sends[i]) > BaseHistory {
					sends[i] = sends[i][1:]
				}
			}
		}
		packer.Finish()
		data, err := snapshot.Encode(nil)
		if err != nil {
			t.Fatal(err)
		}
		// A fifth of the datagrams is lost; the rest arrive, and the client
		// acknowledges them before the next datagram is built.
		if random.IntN(5) == 0 {
			continue
		}
		if err := received.Decode(data); err != nil {
			t.Fatal(err)
		}
		resolved := make([]SoldierState, 0, len(received.Soldiers))
		for i := range received.Soldiers {
			state, err := baselines.Resolve(received.Sequence, &received.Soldiers[i])
			if err != nil {
				t.Fatalf("datagram %d: %v", datagram, err)
			}
			resolved = append(resolved, state)
		}
		for i, state := range resolved {
			if want := states[state.ID.Slot()/3]; state != want {
				t.Fatalf("datagram %d record %d: resolved %+v, sent %+v", datagram, i, state, want)
			}
			baselines.Store(received.Sequence, state)
		}
		acked[datagram] = true
	}
	if deltas < 10000 {
		t.Errorf("only %d deltas were tested", deltas)
	}
}

func TestBaselinesKeepTheNewestStates(t *testing.T) {
	baselines := NewBaselines()
	id := soldierID(7, 2)
	state := func(x int32) SoldierState { return SoldierState{ID: id, Position: [3]int32{x, 0, 0}} }
	// Sequences wrap around and arrive out of order.
	for _, sequence := range []uint16{65530, 65533, 65531, 2, 0, 65535, 1, 3, 65532, 4} {
		baselines.Store(sequence, state(int32(sequence)))
	}
	resolve := func(sequence uint16) error {
		record := NewSoldierRecord(state(9), &SoldierState{ID: id}, 1)
		record.Base = uint8(5 - sequence)
		_, err := baselines.Resolve(5, &record)
		return err
	}
	for _, kept := range []uint16{65532, 65533, 65535, 0, 1, 2, 3, 4} {
		if err := resolve(kept); err != nil {
			t.Errorf("state of %d was dropped: %v", kept, err)
		}
	}
	for _, dropped := range []uint16{65530, 65531} {
		if err := resolve(dropped); !errors.Is(err, ErrMissingBase) {
			t.Errorf("state of %d is still kept", dropped)
		}
	}
	baselines.Store(65529, state(1))
	if err := resolve(65529); err == nil {
		t.Error("a state older than every kept one was stored")
	}
	baselines.Forget(id)
	if err := resolve(4); !errors.Is(err, ErrMissingBase) {
		t.Error("a forgotten soldier still resolves")
	}
}
