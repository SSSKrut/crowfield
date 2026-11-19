package simulation

import (
	"context"
	"errors"
	"math"
	"math/rand/v2"
	"slices"
	"testing"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

// With 256 dummies a client gets more than its budget allows, so the server
// has to choose. The player stares at one dummy across the map: it must be
// updated at least 15 times a second, and the traffic must keep to the budget.
// With the default budget every soldier gets at least the far rate; with a
// quarter of it the soldiers share what is left, but none is forgotten. Every
// delta must resolve to exactly the state the server had, though some
// datagrams are lost and acknowledgements take a round trip.
func TestSnapshotsKeepToTheBudgetAndFollowTheAim(t *testing.T) {
	for _, c := range []struct {
		budget int
		rarest float64 // updates per second of the least updated soldier
	}{{config.DefaultClientBandwidth, farRate}, {8 * 1024, 0.2}} {
		budget := c.budget
		server := newTestServer(t, config.Server{
			MaxPlayers: 1, SnapshotRate: 20, Dummies: 256, ClientBandwidth: budget, Seed: 1,
		})
		receiver := addReceiver(t, server, 0, 6, 0.05)
		target := farthestDummy(server, receiver.player)
		const seconds = 10
		for range seconds * game.TickRate {
			receiver.aimAt(target)
			if err := server.step(); err != nil {
				t.Fatal(err)
			}
			receiver.receive()
		}
		perSnapshot := budget / server.settings.SnapshotRate
		if receiver.bytes > budget*seconds+2*perSnapshot {
			t.Errorf("budget %d B/s: sent %d B/s", budget, receiver.bytes/seconds)
		}
		if rate := receiver.updates[target] / seconds; rate < 15 {
			t.Errorf("budget %d B/s: the dummy aimed at was updated %d times a second", budget, rate)
		}
		total, rarest := 0, math.MaxInt
		for soldier := range server.soldiers.All() {
			total += receiver.updates[soldier.ID]
			rarest = min(rarest, receiver.updates[soldier.ID])
		}
		if float64(rarest) < c.rarest*seconds {
			t.Errorf("budget %d B/s: a soldier was updated only %d times in %d s", budget, rarest, seconds)
		}
		t.Logf("budget %d B/s: %.1f KB/s, %d records/s, aimed %d Hz, average %.1f Hz, rarest %.1f Hz, deltas %.0f%%",
			budget, float64(receiver.bytes)/1024/seconds, total/seconds, receiver.updates[target]/seconds,
			float64(total)/seconds/float64(server.soldiers.Len()), float64(rarest)/seconds,
			100*float64(receiver.deltas)/float64(total))
	}
}

// A soldier that is gone is announced in every snapshot until the client
// acknowledges a datagram that carried it, and then no more.
func TestRemovalIsRepeatedUntilAcknowledged(t *testing.T) {
	server := newTestServer(t, config.Server{MaxPlayers: 2, SnapshotRate: 20})
	watcher := addReceiver(t, server, 0, 8, 0)
	leaver := addReceiver(t, server, 1, 0, 0)
	gone := leaver.player.soldier
	for range game.TickRate {
		if err := server.step(); err != nil {
			t.Fatal(err)
		}
		watcher.receive()
	}
	if watcher.updates[gone] == 0 {
		t.Fatal("the watcher never saw the other soldier")
	}
	server.leave(&session{conn: leaver.player.conn, player: leaver.player}, errors.New("test over"))
	for range game.TickRate {
		if err := server.step(); err != nil {
			t.Fatal(err)
		}
		watcher.receive()
	}
	// The acknowledgement of the first removal arrives 8 ticks later, just
	// before the fourth snapshot.
	if removals := watcher.removed[gone]; removals != 3 {
		t.Errorf("the removal came in %d snapshots, want 3", removals)
	}
	if len(watcher.player.removals) != 0 || watcher.player.views[gone.Slot()].id != 0 {
		t.Error("the server still tracks the removed soldier")
	}
}

func TestAcknowledgementsCoverOnlyRecentDatagrams(t *testing.T) {
	p := &player{}
	for range 1000 {
		p.acks[p.datagrams%ackWindow] = 0
		p.datagrams++
	}
	p.acknowledge(&protocol.InputPacket{HasAck: true, AckSequence: 999 % 65536, AckBits: 1<<31 | 1})
	for datagram, want := range map[uint64]bool{999: true, 998: true, 997: false, 967: true, 966: false} {
		if got := p.acknowledged(datagram); got != want {
			t.Errorf("datagram %d acknowledged: %t", datagram, got)
		}
	}
	// A sequence the server has not sent yet, or one older than the window.
	p.acknowledge(&protocol.InputPacket{HasAck: true, AckSequence: 1000})
	p.acknowledge(&protocol.InputPacket{HasAck: true, AckSequence: 1000 - ackWindow - 1})
	if p.acknowledged(1000-ackWindow-1) || p.acks[1000%ackWindow] != 0 {
		t.Error("an acknowledgement outside the window was taken")
	}
	// Once the window moves past a datagram, its acknowledgement is gone.
	for range ackWindow {
		p.acks[p.datagrams%ackWindow] = 0
		p.datagrams++
	}
	if p.acknowledged(999) {
		t.Error("a datagram older than the window still counts as acknowledged")
	}
}

// testReceiver plays the client for a player of a server the test steps: it
// receives the snapshot datagrams, loses some, resolves the deltas, checks them
// against the server and acknowledges what arrived after a delay.
type testReceiver struct {
	t         *testing.T
	server    *Server
	player    *player
	peer      transport.Conn
	baselines *protocol.Baselines
	random    *rand.Rand
	loss      float64
	// acks are the acknowledgements on their way, one per tick.
	acks    []protocol.InputPacket
	ack     protocol.InputPacket
	bytes   int
	deltas  int
	updates map[game.SoldierID]int
	removed map[game.SoldierID]int
}

func addReceiver(t *testing.T, server *Server, id game.PlayerID, ackDelay int, loss float64) *testReceiver {
	t.Helper()
	conn, peer := transport.NewMemoryPair()
	t.Cleanup(func() { _ = conn.Close("test over"); _ = peer.Close("test over") })
	p := server.newPlayer(id, "receiver", conn)
	p.ready = true
	if err := server.spawn(p); err != nil {
		t.Fatal(err)
	}
	server.players[id] = p
	return &testReceiver{
		t: t, server: server, player: p, peer: peer, baselines: protocol.NewBaselines(),
		random: rand.New(rand.NewPCG(uint64(id), 9)), loss: loss, acks: make([]protocol.InputPacket, ackDelay),
		updates: map[game.SoldierID]int{}, removed: map[game.SoldierID]int{},
	}
}

// aimAt queues the player's command for the coming tick: stand and look at
// the target.
func (r *testReceiver) aimAt(target game.SoldierID) {
	eye := r.server.soldiers.Get(r.player.soldier).Position.Add(physics.V(0, r.server.tuning.EyeHeight, 0))
	to := r.server.soldiers.Get(target).Position.Add(physics.V(0, r.server.tuning.CenterHeight(), 0)).Sub(eye)
	yaw := math.Atan2(float64(to.X), float64(-to.Z))
	pitch := math.Atan2(float64(to.Y), math.Hypot(float64(to.X), float64(to.Z)))
	command := game.NewInputCommand(r.server.tick, 0, 0, float32(yaw), float32(pitch), 0)
	r.player.inputs.put(command, r.server.tick)
}

func (r *testReceiver) receive() {
	t := r.t
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	for {
		data, err := r.peer.ReceiveUnreliable(ctx)
		if err != nil {
			break
		}
		r.bytes += len(data) + datagramOverhead
		if len(data) > protocol.SnapshotBudget {
			t.Fatalf("a datagram takes %d bytes", len(data))
		}
		if r.random.Float64() < r.loss {
			continue
		}
		var snapshot protocol.Snapshot
		if err := snapshot.Decode(data); err != nil {
			t.Fatal(err)
		}
		states := make([]protocol.SoldierState, 0, len(snapshot.Soldiers))
		for i := range snapshot.Soldiers {
			record := &snapshot.Soldiers[i]
			state, err := r.baselines.Resolve(snapshot.Sequence, record)
			if err != nil {
				t.Fatalf("datagram %d: %v", snapshot.Sequence, err)
			}
			if want, _ := protocol.NewSoldierState(r.server.soldiers.Get(state.ID)); state != want {
				t.Fatalf("datagram %d resolved %+v, the server has %+v", snapshot.Sequence, state, want)
			}
			if record.Base != 0 {
				r.deltas++
			}
			states = append(states, state)
		}
		for _, state := range states {
			r.baselines.Store(snapshot.Sequence, state)
			r.updates[state.ID]++
		}
		for _, id := range snapshot.Removed {
			r.removed[id]++
			r.baselines.Forget(id)
		}
		r.observe(snapshot.Sequence)
	}
	// One input packet a tick, delivered after the delay.
	r.acks = append(r.acks, r.ack)
	r.player.acknowledge(&r.acks[0])
	r.acks = r.acks[1:]
}

// observe acknowledges a datagram; here they arrive in order.
func (r *testReceiver) observe(sequence uint16) {
	if r.ack.HasAck {
		distance := uint32(sequence - r.ack.AckSequence)
		r.ack.AckBits = r.ack.AckBits<<distance | 1<<(distance-1)
	}
	r.ack.HasAck, r.ack.AckSequence = true, sequence
}

func farthestDummy(server *Server, p *player) game.SoldierID {
	from := server.soldiers.Get(p.soldier).Position
	var farthest game.SoldierID
	longest := float32(0)
	for _, d := range server.dummies.all {
		if length := distance(server.soldiers.Get(d.soldier).Position, from); length > longest {
			farthest, longest = d.soldier, length
		}
	}
	return farthest
}

func TestCandidatesSortAlwaysThenPriorityThenSlot(t *testing.T) {
	candidates := []candidate{
		newCandidate(5, false, 3), newCandidate(4095, true, 0), newCandidate(7, false, 3),
		newCandidate(0, false, 0.5), newCandidate(9, true, 1), newCandidate(2, false, 12.25),
	}
	slices.Sort(candidates)
	slices.Reverse(candidates)
	var slots []int
	for _, c := range candidates {
		slots = append(slots, c.slot())
	}
	if want := []int{9, 4095, 2, 5, 7, 0}; !slices.Equal(slots, want) {
		t.Errorf("sent in the order %v, want %v", slots, want)
	}
}
