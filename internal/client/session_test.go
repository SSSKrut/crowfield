package client

import (
	"math"
	"strings"
	"testing"
	"time"

	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
)

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
			local, err := startLocalServer(tuning)
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
				if err := session.sendCommand(command); err != nil {
					t.Fatal(err)
				}
				if err := session.poll(); err != nil {
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

func TestConnectRefusesADifferentTuning(t *testing.T) {
	local, err := startLocalServer(game.DefaultMovementTuning())
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
