package client

import (
	"math"
	"strings"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/protocol"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/physics"
)

// The model must look where the soldier moves.
func TestFacingLooksAlongMovement(t *testing.T) {
	for _, yaw := range []float32{0, 0.7, math.Pi / 2, math.Pi, -2} {
		looks := physics.QuatRotate(facing(yaw), physics.V(0, 0, 1))
		moves := physics.V(float32(math.Sin(float64(yaw))), 0, -float32(math.Cos(float64(yaw))))
		if distance(looks, moves) > 1e-5 {
			t.Errorf("yaw %.2f: the model looks along %+v but moves along %+v", yaw, looks, moves)
		}
	}
}

func TestAckTracker(t *testing.T) {
	var acks ackTracker
	for _, sequence := range []uint16{10, 11, 13, 12, 9} {
		acks.observe(sequence)
	}
	// Newest 13; 12, 11, 10 and 9 were received too.
	if !acks.has || acks.latest != 13 || acks.bits != 0b1111 {
		t.Errorf("latest %d bits %b", acks.latest, acks.bits)
	}
	acks.observe(13 + 32)
	if acks.latest != 45 || acks.bits != 1<<31 {
		t.Errorf("after a jump of 32: latest %d bits %b", acks.latest, acks.bits)
	}
	acks.observe(45 + 33)
	if acks.latest != 78 || acks.bits != 0 {
		t.Errorf("after a jump of 33: latest %d bits %b", acks.latest, acks.bits)
	}
	acks = ackTracker{}
	acks.observe(65535)
	acks.observe(1)
	if acks.latest != 1 || acks.bits != 0b10 {
		t.Errorf("across the wrap: latest %d bits %b", acks.latest, acks.bits)
	}
}

// Solo play goes through the embedded server, with and without a simulated
// network. The soldier walks east, where the prototype scene is open.
func TestSoloSessionThroughTheEmbeddedServer(t *testing.T) {
	for name, conditions := range map[string]transport.NetworkConditions{
		"direct":       {},
		"slow network": {Delay: 40 * time.Millisecond, Jitter: 10 * time.Millisecond, Loss: 0.02, Seed: 4},
	} {
		t.Run(name, func(t *testing.T) {
			tuning := game.DefaultMovementTuning()
			local, err := startLocalServer(tuning, config.Client{})
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				if err := local.stop(); err != nil {
					t.Error(err)
				}
			}()
			conn, err := local.dial()
			if err != nil {
				t.Fatal(err)
			}
			if conditions != (transport.NetworkConditions{}) {
				conn = transport.Simulate(conn, conditions)
			}
			session, err := connect(conn, "tester", tuning)
			if err != nil {
				t.Fatal(err)
			}
			defer session.close()

			ticker := time.NewTicker(game.TickDuration)
			defer ticker.Stop()
			var start *game.Soldier
			for range 2 * game.TickRate {
				<-ticker.C
				command := game.InputCommand{}
				if start != nil {
					command = game.NewInputCommand(0, 1, 0, math.Pi/2, 0, 0)
				}
				if _, err := session.sendCommand(command); err != nil {
					t.Fatal(err)
				}
				if _, err := session.poll(); err != nil {
					t.Fatal(err)
				}
				if soldier := session.localSoldier(); start == nil && soldier != nil && soldier.Grounded {
					copied := *soldier
					start = &copied
				}
			}
			if start == nil {
				t.Fatal("the soldier never spawned")
			}
			moved := session.localSoldier().Position.X - start.Position.X
			// Under 2 s of walking at 5 m/s, minus spawning and the commands still on their way.
			if moved < 7 || moved > 10 {
				t.Errorf("the soldier moved %.2f m", moved)
			}
			// The handshake measures the network, so the clock holds from the start.
			if session.resyncs > 0 {
				t.Errorf("%d clock resyncs", session.resyncs)
			}
			t.Logf("moved %.2f m, %d snapshots, %d resyncs, buffered %d", moved, session.received, session.resyncs,
				session.player.BufferedCommands)
		})
	}
}

// With dummies a snapshot no longer fits one datagram; the client still gets
// every soldier, from the parts.
func TestClientReceivesEverySoldierOfASplitSnapshot(t *testing.T) {
	tuning := game.DefaultMovementTuning()
	local, err := startLocalServer(tuning, config.Client{Dummies: 256})
	if err != nil {
		t.Fatal(err)
	}
	defer local.stop()
	conn, err := local.dial()
	if err != nil {
		t.Fatal(err)
	}
	session, err := connect(conn, "tester", tuning)
	if err != nil {
		t.Fatal(err)
	}
	defer session.close()
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	for range game.TickRate {
		<-ticker.C
		if _, err := session.sendCommand(game.InputCommand{}); err != nil {
			t.Fatal(err)
		}
		if _, err := session.poll(); err != nil {
			t.Fatal(err)
		}
	}
	if len(session.soldiers) != 257 || len(session.remotes) != 256 {
		t.Errorf("client knows %d soldiers and %d remotes, want 257 and 256", len(session.soldiers), len(session.remotes))
	}
	bots := 0
	for _, soldier := range session.soldiers {
		if soldier.Controller.Kind == game.ControllerBot {
			bots++
		}
	}
	if bots != 256 {
		t.Errorf("%d soldiers are marked as bots, want 256", bots)
	}
}

// Snapshots that were on their way when the clock jumped still report late
// commands. One stalled frame may apply a burst of them before the client sends
// anything under the new clock; that burst must not make the clock jump again.
func TestStaleSnapshotsDoNotResyncAgain(t *testing.T) {
	conn, peer := transport.NewMemoryPair()
	defer conn.Close("done")
	defer peer.Close("done")
	s := &session{
		conn: conn, soldiers: map[game.SoldierID]*game.Soldier{}, remotes: map[game.SoldierID]*remoteSoldier{},
		clock: newInterpolationClock(20),
	}
	snapshot := func(tick game.Tick, buffered int8) *protocol.Snapshot {
		return &protocol.Snapshot{ServerTick: tick, Player: protocol.PlayerState{
			Processed: true, LastProcessedTick: tick, BufferedCommands: buffered, Soldier: 0x1000,
		}}
	}
	s.setClock(100, 0)
	s.tick = 110
	s.apply(snapshot(105, -1))
	if s.resyncs != 1 {
		t.Fatalf("%d resyncs for a late command, want 1", s.resyncs)
	}
	for tick := game.Tick(108); tick <= 120; tick += 3 {
		s.apply(snapshot(tick, -1))
	}
	if s.resyncs != 1 {
		t.Errorf("%d resyncs after a burst of stale snapshots, want still 1", s.resyncs)
	}
	for tick := game.Tick(123); tick <= 160; tick += 3 {
		s.tick += 3
		s.apply(snapshot(tick, 2))
	}
	if s.resyncs != 1 {
		t.Errorf("%d resyncs once commands arrive in time", s.resyncs)
	}
}

func TestConnectRefusesADifferentTuning(t *testing.T) {
	local, err := startLocalServer(game.DefaultMovementTuning(), config.Client{})
	if err != nil {
		t.Fatal(err)
	}
	defer local.stop()
	conn, err := local.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close("test over")
	other := game.DefaultMovementTuning()
	other.SprintSpeed++
	if _, err := connect(conn, "tester", other); err == nil || !strings.Contains(err.Error(), "tuning") {
		t.Errorf("connect with another tuning: %v", err)
	}
}
