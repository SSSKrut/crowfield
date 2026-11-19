package client

import (
	"math"
	"math/rand/v2"
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
			t.Logf("moved %.2f m, %d snapshots, %d jumps, lead %d", moved, session.received, session.resyncs,
				session.player.InputLead)
		})
	}
}

// With 256 dummies the client learns every soldier within a second, although
// its budget lets the server send only some of them in each snapshot, and
// every delta finds its base.
func TestClientLearnsEverySoldierWithinTheBudget(t *testing.T) {
	session, stop := soloSession(t, config.Client{Dummies: 256}, transport.NetworkConditions{})
	defer stop()
	play(t, session, game.TickRate)
	if len(session.soldiers) != 257 || remotes(session) != 256 {
		t.Errorf("client knows %d soldiers and %d remotes, want 257 and 256", len(session.soldiers), remotes(session))
	}
	bots := 0
	for _, known := range session.soldiers {
		if known.soldier.Controller.Kind == game.ControllerBot {
			bots++
		}
	}
	if bots != 256 || session.unresolved != 0 {
		t.Errorf("%d soldiers are marked as bots, want 256; %d datagrams did not resolve", bots, session.unresolved)
	}
}

// Deltas hold up under loss, duplicates and reordering: no datagram misses its
// base, and every soldier keeps being updated.
func TestDeltasSurviveABadNetwork(t *testing.T) {
	conditions := transport.NetworkConditions{
		Delay: 30 * time.Millisecond, Jitter: 20 * time.Millisecond, Loss: 0.1, Duplicate: 0.05, Seed: 7,
	}
	session, stop := soloSession(t, config.Client{Dummies: 64}, conditions)
	defer stop()
	play(t, session, 3*game.TickRate)
	if session.unresolved != 0 || len(session.soldiers) != 65 {
		t.Fatalf("%d datagrams did not resolve; %d soldiers known", session.unresolved, len(session.soldiers))
	}
	for _, known := range session.soldiers {
		if behind := int32(session.serverTick - known.tick); behind > game.TickRate/2 {
			t.Errorf("soldier %#04x was last updated %d ticks ago", known.soldier.ID, behind)
		}
	}
	t.Logf("%d datagrams, %.1f KB/s", session.received, float64(session.bytes.Load())/1024/3)
}

// soloSession connects to an embedded server, through a simulated network if
// conditions are given.
func soloSession(t *testing.T, settings config.Client, conditions transport.NetworkConditions) (*session, func()) {
	t.Helper()
	tuning := game.DefaultMovementTuning()
	local, err := startLocalServer(tuning, settings)
	if err != nil {
		t.Fatal(err)
	}
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
	return session, func() {
		session.close()
		if err := local.stop(); err != nil {
			t.Error(err)
		}
	}
}

// play runs the client loop with idle commands for the given number of ticks.
func play(t *testing.T, session *session, ticks int) {
	t.Helper()
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	for range ticks {
		<-ticker.C
		if _, err := session.sendCommand(game.InputCommand{}); err != nil {
			t.Fatal(err)
		}
		if _, err := session.poll(); err != nil {
			t.Fatal(err)
		}
		session.clock.advance(game.TickDelta)
	}
}

// remotes counts the soldiers the client draws: all but its own.
func remotes(s *session) int {
	count := 0
	for _, known := range s.soldiers {
		if known.soldier.ID != s.player.Soldier {
			count++
		}
	}
	return count
}

// Snapshots that were on their way when the clock jumped still report late
// commands. One stalled frame may apply a burst of them before the client sends
// anything under the new clock; that burst must not make the clock jump again.
func TestStaleSnapshotsDoNotJumpAgain(t *testing.T) {
	s := newTestSession(t)
	snapshot := func(tick game.Tick, lead int8) *protocol.Snapshot {
		return &protocol.Snapshot{ServerTick: tick, Player: protocol.PlayerState{
			Processed: true, LastProcessedTick: tick, InputLead: lead, Soldier: 0x1000,
		}}
	}
	s.setClock(100, 0)
	s.tick = 110
	s.apply(snapshot(105, -40))
	if s.resyncs != 1 || s.tick != 152 {
		t.Fatalf("%d jumps to tick %d for commands 40 ticks late, want 1 to 152", s.resyncs, s.tick)
	}
	for tick := game.Tick(108); tick <= 150; tick += 3 {
		s.apply(snapshot(tick, -40))
	}
	if s.resyncs != 1 {
		t.Errorf("%d jumps after a burst of stale snapshots, want still 1", s.resyncs)
	}
	for tick := game.Tick(153); tick <= 190; tick += 3 {
		s.tick += 3
		s.apply(snapshot(tick, 2))
	}
	if s.resyncs != 1 || s.dilation != 0 {
		t.Errorf("%d jumps and dilation %.3f once commands arrive in time", s.resyncs, s.dilation)
	}
}

// The client keeps its commands arriving two ticks before the server needs
// them by stretching its ticks, over a network with 40 ms of delay and up to
// 10 ms of jitter. Started early or late it settles without a jump; far off it
// jumps once. Once settled, no command comes late.
func TestClockKeepsTheLead(t *testing.T) {
	for _, c := range []struct {
		name   string
		offset int
		jumps  int
	}{{"early", 8, 0}, {"late", -6, 0}, {"far off", 40, 1}} {
		t.Run(c.name, func(t *testing.T) {
			s := newTestSession(t)
			random := rand.New(rand.NewPCG(3, uint64(c.offset+100)))
			oneWay := func() time.Duration {
				return 40*time.Millisecond + time.Duration(random.Int64N(int64(10*time.Millisecond)))
			}
			type sent struct {
				tick    game.Tick
				arrives time.Duration
			}
			type delivery struct {
				arrives  time.Duration
				snapshot protocol.Snapshot
			}
			var commands []sent
			var snapshots []delivery
			const start, duration = game.Tick(1000), 20 * time.Second
			s.setClock(start, 80*time.Millisecond)
			s.tick += game.Tick(c.offset)
			serverTick, newest, hasInput, late := start, game.Tick(0), false, 0
			accumulator, settled := float32(0), time.Duration(0)
			for now := time.Duration(0); now < duration; now += time.Millisecond {
				for accumulator += 0.001; accumulator >= s.tickDuration(); {
					accumulator -= s.tickDuration()
					commands = append(commands, sent{tick: s.tick, arrives: now + oneWay()})
					s.tick++
				}
				for time.Duration(serverTick-start)*game.TickDuration <= now {
					// The lead counts from the command that arrived last.
					kept, latest := commands[:0], time.Duration(-1)
					for _, command := range commands {
						if command.arrives > now {
							kept = append(kept, command)
						} else if command.arrives > latest {
							newest, hasInput, latest = command.tick, true, command.arrives
						}
					}
					commands = kept
					lead := int8(protocol.NoInput)
					if hasInput {
						lead = int8(max(-127, min(127, int32(newest-serverTick))))
					}
					if lead < 0 && now > duration/2 {
						late++
					}
					if serverTick%3 == 0 {
						snapshots = append(snapshots, delivery{arrives: now + oneWay(), snapshot: protocol.Snapshot{
							ServerTick: serverTick,
							Player:     protocol.PlayerState{Processed: true, LastProcessedTick: serverTick, InputLead: lead, Soldier: 0x1000},
						}})
					}
					serverTick++
				}
				kept := snapshots[:0]
				for _, d := range snapshots {
					if d.arrives > now {
						kept = append(kept, d)
					} else {
						s.apply(&d.snapshot)
					}
				}
				snapshots = kept
				if math.Abs(s.lead-commandLead) > 0.5 || !s.hasLead {
					settled = now
				}
			}
			if s.resyncs != c.jumps || late > 0 || math.Abs(s.lead-commandLead) > 1 {
				t.Errorf("%d jumps, %d late commands in the second half, lead %.2f; want %d jumps, none late, lead near %d",
					s.resyncs, late, s.lead, c.jumps, commandLead)
			}
			t.Logf("lead %.2f within half a tick after %.1f s, dilation %+.2f%%, %d jumps", s.lead, settled.Seconds(), 100*s.dilation, s.resyncs)
		})
	}
}

func newTestSession(t *testing.T) *session {
	conn, peer := transport.NewMemoryPair()
	t.Cleanup(func() { _ = conn.Close("done"); _ = peer.Close("done") })
	return &session{
		conn: conn, soldiers: map[int]*knownSoldier{}, baselines: protocol.NewBaselines(),
		buried: map[game.SoldierID]game.Tick{}, clock: newInterpolationClock(20),
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
