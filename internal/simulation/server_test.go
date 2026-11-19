package simulation

import (
	"context"
	"errors"
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

func TestInputBuffer(t *testing.T) {
	var buffer inputBuffer
	command := func(tick game.Tick) game.InputCommand {
		return game.InputCommand{Tick: tick, MoveForward: int8(tick % 100)}
	}
	for _, c := range []struct {
		tick game.Tick
		ok   bool
	}{{99, false}, {100, true}, {101, true}, {103, true}, {100 + inputWindow - 1, true}, {100 + inputWindow, false}} {
		if ok := buffer.put(command(c.tick), 100); ok != c.ok {
			t.Errorf("put tick %d at 100: %t", c.tick, ok)
		}
	}
	if got, ok := buffer.take(100); !ok || got != command(100) {
		t.Errorf("take 100: %+v %t", got, ok)
	}
	if _, ok := buffer.take(100); ok {
		t.Error("a command was taken twice")
	}
	if _, ok := buffer.take(102); ok {
		t.Error("a missing command was found")
	}
	// The slot of tick 103 also serves tick 103+window; an old command must not answer for it.
	if _, ok := buffer.take(103 + inputWindow); ok {
		t.Error("a command from a previous window was used")
	}
}

// The full network path must not change movement or weapons: the server
// applies the commands at their ticks, and the result matches the controller
// and the arsenal run directly.
func TestServerMovesSoldierExactlyLikeTheController(t *testing.T) {
	server, listener := startServer(t, config.Server{MaxPlayers: 2, SnapshotRate: game.TickRate})
	client := join(t, listener, "runner")
	first := client.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	spawnTick := first.ServerTick
	start := spawnTick + 5
	const ticks = 150
	var movement func(tick game.Tick) game.InputCommand
	route := func(tick game.Tick) game.InputCommand {
		command := movement(tick)
		// The assault rifle fires a burst on the run; the rifle comes out on
		// the ramp, fires single shots and reloads.
		switch step := tick - start; {
		case step < 30:
			command.Buttons |= game.ButtonFire
		case step >= 40:
			command.Weapon = 1
			if step%20 < 3 {
				command.Buttons |= game.ButtonFire
			}
			if step == 120 {
				command.Buttons |= game.ButtonReload
			}
		}
		return command
	}
	movement = func(tick game.Tick) game.InputCommand {
		step := tick - start
		switch {
		case step < 36:
			return game.NewInputCommand(tick, 1, 0, math.Pi/2, 0, game.ButtonSprint)
		case step < 110:
			buttons := game.ButtonSprint
			if step >= 66 && step < 84 {
				buttons |= game.ButtonJump
			}
			return game.NewInputCommand(tick, 1, 0.3, 0, 0.2, buttons)
		}
		return game.NewInputCommand(tick, 0, 0, 0, 0, 0)
	}
	last := start + ticks - 1
	sent := start - 1
	var final *protocol.Snapshot
	for final == nil {
		snapshot := client.snapshot(t)
		for sent < min(snapshot.ServerTick+5, last) {
			sent++
			client.send(t, route(sent))
		}
		if snapshot.ServerTick >= start && snapshot.ServerTick <= last && snapshot.Player.InputLead < 0 {
			t.Fatalf("tick %d ran without its command", snapshot.ServerTick)
		}
		// A snapshot may be skipped; after the route the commands are idle anyway.
		if snapshot.ServerTick >= last {
			final = snapshot
		}
	}

	world, err := physics.NewWorld()
	if err != nil {
		t.Fatal(err)
	}
	defer world.Close()
	for _, box := range game.PrototypeScene().Boxes {
		if _, err := world.CreateBox(box); err != nil {
			t.Fatal(err)
		}
	}
	controller, err := game.NewCharacterController(world, server.rules.Movement, server.scene.Spawn)
	if err != nil {
		t.Fatal(err)
	}
	defer controller.Close()
	reference := game.Soldier{ID: first.Player.Soldier, Arsenal: game.NewArsenal(game.DefaultLoadout(), &server.rules.Weapons)}
	if err := controller.Teleport(&reference, server.scene.Spawn); err != nil {
		t.Fatal(err)
	}
	var idle game.InputCommand
	shots := 0
	for tick := spawnTick; tick <= final.ServerTick; tick++ {
		command := idle.Repeated(tick)
		if tick >= start && tick <= last {
			command = route(tick)
		}
		step, err := game.RunCommand(controller, &server.rules.Weapons, &reference, command, client.welcome.MatchSeed)
		if err != nil {
			t.Fatal(err)
		}
		if step.Events.Has(game.EventFired) {
			shots++
		}
		if err := world.Step(game.TickDelta); err != nil {
			t.Fatal(err)
		}
	}
	if final.Player.Position != reference.Position || final.Player.Velocity != reference.Velocity {
		t.Errorf("server ended at %+v v=%+v, the controller at %+v v=%+v",
			final.Player.Position, final.Player.Velocity, reference.Position, reference.Velocity)
	}
	if final.Player.Arsenal != reference.Arsenal {
		t.Errorf("server arsenal %+v, the reference %+v", final.Player.Arsenal, reference.Arsenal)
	}
	// The rifle is out from step 88 and fires once before the reload.
	if shots != 6 {
		t.Errorf("%d shots, want a burst of 5 and a rifle shot", shots)
	}
	if distance := math.Hypot(float64(reference.Position.X), float64(reference.Position.Z-server.scene.Spawn.Z)); distance < 10 {
		t.Errorf("the route moved the soldier only %.1f m", distance)
	}
}

func TestServerRejectsIncompatibleAndExtraClients(t *testing.T) {
	_, listener := startServer(t, config.Server{MaxPlayers: 1, SnapshotRate: 20})
	conn, err := listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	sendMessage(t, conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion + 1})
	if err := expectClosed(conn); !strings.Contains(err, "protocol") {
		t.Errorf("old client was refused with %q", err)
	}
	join(t, listener, "first")
	conn, err = listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	sendMessage(t, conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion})
	if err := expectClosed(conn); !strings.Contains(err, "full") {
		t.Errorf("extra client was refused with %q", err)
	}
}

func TestLeavingPlayerIsRemovedFromSnapshots(t *testing.T) {
	_, listener := startServer(t, config.Server{MaxPlayers: 2, SnapshotRate: game.TickRate})
	stays := join(t, listener, "stays")
	leaves := join(t, listener, "leaves")
	gone := leaves.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 }).Player.Soldier
	stays.waitFor(t, func(s *protocol.Snapshot) bool { return len(s.Soldiers) == 2 })
	_ = leaves.conn.Close("bye")
	removed := stays.waitFor(t, func(s *protocol.Snapshot) bool { return len(s.Removed) > 0 })
	if removed.Removed[0] != gone || len(removed.Soldiers) != 1 {
		t.Errorf("removed %v with %d soldiers left, want %#04x and 1", removed.Removed, len(removed.Soldiers), gone)
	}
}

func TestRespawnReturnsTheSoldierToTheSpawn(t *testing.T) {
	server, listener := startServer(t, config.Server{MaxPlayers: 1, SnapshotRate: game.TickRate})
	client := join(t, listener, "walker")
	snapshot := client.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	tick := snapshot.ServerTick + 3
	for range 60 {
		snapshot = client.snapshot(t)
		for tick <= snapshot.ServerTick+3 {
			client.send(t, game.NewInputCommand(tick, 1, 0, 0, 0, game.ButtonSprint))
			tick++
		}
	}
	if moved := server.scene.Spawn.Z - snapshot.Player.Position.Z; moved < 3 {
		t.Fatalf("the soldier walked only %.2f m", moved)
	}
	// The server keeps repeating the last command, so the soldier walks on from
	// the spawn; one tick of walking is far less than the distance covered.
	sendMessage(t, client.conn, &protocol.Respawn{})
	client.waitFor(t, func(s *protocol.Snapshot) bool {
		offset := s.Player.Position.Sub(server.scene.Spawn)
		return math.Hypot(float64(offset.X), float64(offset.Z)) < 0.5
	})
}

func startServer(t *testing.T, settings config.Server) (*Server, *transport.MemoryListener) {
	t.Helper()
	server, err := NewServer(settings, game.DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
	listener := transport.NewMemoryListener()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx, listener) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
		_ = listener.Close()
		_ = server.Close()
	})
	return server, listener
}

// testClient speaks the protocol directly, without the game client.
type testClient struct {
	conn    transport.Conn
	welcome protocol.Welcome
	history []game.InputCommand
}

func join(t *testing.T, listener *transport.MemoryListener, name string) *testClient {
	t.Helper()
	conn, err := listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close("test over") })
	sendMessage(t, conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion, Name: name})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := conn.ReceiveReliable(ctx)
	if err != nil {
		t.Fatal(err)
	}
	client := &testClient{conn: conn}
	if err := client.welcome.Decode(data); err != nil {
		t.Fatal(err)
	}
	rules := game.DefaultRules()
	if client.welcome.TuningHash != rules.Hash() || client.welcome.TickRate != game.TickRate {
		t.Fatalf("welcome %+v", client.welcome)
	}
	sendMessage(t, conn, &protocol.Ready{})
	return client
}

func (c *testClient) send(t *testing.T, command game.InputCommand) {
	t.Helper()
	c.history = append(c.history, command)
	if len(c.history) > protocol.MaxCommandsPerInput {
		c.history = c.history[1:]
	}
	data, err := (&protocol.InputPacket{Commands: c.history}).Encode(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.conn.SendUnreliable(data); err != nil {
		t.Fatal(err)
	}
}

func (c *testClient) snapshot(t *testing.T) *protocol.Snapshot {
	t.Helper()
	snapshot := &protocol.Snapshot{}
	if err := snapshot.Decode(receiveDatagram(t, c.conn)); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func (c *testClient) waitFor(t *testing.T, condition func(*protocol.Snapshot) bool) *protocol.Snapshot {
	t.Helper()
	for range 10 * game.TickRate {
		if snapshot := c.snapshot(t); condition(snapshot) {
			return snapshot
		}
	}
	t.Fatal("the expected snapshot never came")
	return nil
}

func receiveDatagram(t *testing.T, conn transport.Conn) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data, err := conn.ReceiveUnreliable(ctx)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func sendMessage(t *testing.T, conn transport.Conn, message protocol.Message) {
	t.Helper()
	if err := send(conn, message); err != nil {
		t.Fatal(err)
	}
}

// expectClosed waits for the server to close the connection and returns what
// the client learned: the reject message if it arrived, else the close reason.
func expectClosed(conn transport.Conn) string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, data, err := conn.ReceiveReliable(ctx)
		var closed *transport.CloseError
		if errors.As(err, &closed) {
			return closed.Reason
		}
		if err != nil {
			return err.Error()
		}
		var reject protocol.Reject
		if reject.Decode(data) == nil {
			return reject.Message
		}
	}
}

// A player whose input stops — a frozen client, a broken link — is dropped
// after the input timeout, and its soldier with it. Its place stays reserved:
// a newcomer finds the server full, while the player returns with its token
// to the same place and team.
func TestLostPlayerReturnsToItsPlaceAndTeam(t *testing.T) {
	_, listener := startServer(t, config.Server{
		MaxPlayers: 1, SnapshotRate: game.TickRate, InputTimeout: 200 * time.Millisecond, ReconnectWindow: 5 * time.Second,
	})
	lost := join(t, listener, "lost")
	soldier := lost.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	team := ownTeam(t, soldier)
	if reason := expectClosed(lost.conn); !strings.Contains(reason, "no input") {
		t.Fatalf("the silent player was closed with %q", reason)
	}
	conn, err := listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	sendMessage(t, conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion, Name: "newcomer"})
	if reason := expectClosed(conn); !strings.Contains(reason, "full") {
		t.Errorf("a newcomer took the reserved place: %q", reason)
	}
	back := joinWith(t, listener, "lost", lost.welcome.SessionToken)
	if back.welcome.Player != lost.welcome.Player || back.welcome.SessionToken != lost.welcome.SessionToken {
		t.Errorf("returned as player %d, was %d", back.welcome.Player, lost.welcome.Player)
	}
	returned := back.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	if ownTeam(t, returned) != team || returned.Player.Soldier == soldier.Player.Soldier {
		t.Errorf("returned in team %d with soldier %#04x; was team %d with %#04x",
			ownTeam(t, returned), returned.Player.Soldier, team, soldier.Player.Soldier)
	}
	if len(returned.Soldiers) != 1 {
		t.Errorf("%d soldiers after the return, want 1", len(returned.Soldiers))
	}
}

// A player who quits on purpose frees the place at once.
func TestQuittingPlayerFreesThePlace(t *testing.T) {
	_, listener := startServer(t, config.Server{MaxPlayers: 1, SnapshotRate: 20})
	quitter := join(t, listener, "quitter")
	quitter.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	_ = quitter.conn.Close(protocol.QuitReason)
	// The close travels while the newcomer dials; let the server see it.
	for range 50 {
		conn, err := listener.Dial()
		if err != nil {
			t.Fatal(err)
		}
		sendMessage(t, conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion, Name: "newcomer"})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		_, data, err := conn.ReceiveReliable(ctx)
		cancel()
		var welcome protocol.Welcome
		if err == nil && welcome.Decode(data) == nil {
			_ = conn.Close("test over")
			return
		}
		_ = conn.Close("test over")
		time.Sleep(10 * time.Millisecond)
	}
	t.Error("the place of a player who quit stayed taken")
}

// A player who comes back while its old connection still looks alive — the
// client restarted, or its route changed — replaces it: never two soldiers.
func TestNewConnectionReplacesTheOldOne(t *testing.T) {
	_, listener := startServer(t, config.Server{MaxPlayers: 2, SnapshotRate: game.TickRate})
	watcher := join(t, listener, "watcher")
	old := join(t, listener, "twice")
	old.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 })
	watcher.waitFor(t, func(s *protocol.Snapshot) bool { return len(s.Soldiers) == 2 })
	again := joinWith(t, listener, "twice", old.welcome.SessionToken)
	if reason := expectClosed(old.conn); !strings.Contains(reason, "replaced") {
		t.Errorf("the old connection was closed with %q", reason)
	}
	if again.welcome.Player != old.welcome.Player {
		t.Errorf("came back as player %d, was %d", again.welcome.Player, old.welcome.Player)
	}
	soldier := again.waitFor(t, func(s *protocol.Snapshot) bool { return s.Player.Soldier != 0 }).Player.Soldier
	// The watcher hears the old soldier removed and sees exactly two.
	seen := map[game.SoldierID]bool{}
	watcher.waitFor(t, func(s *protocol.Snapshot) bool {
		for _, id := range s.Removed {
			delete(seen, id)
		}
		for _, record := range s.Soldiers {
			seen[record.State.ID] = true
		}
		return seen[soldier] && len(seen) == 2 && len(s.Removed) > 0
	})
}

// Once the reconnect window passes, the place is free and the token is
// worth nothing.
func TestReservationsExpire(t *testing.T) {
	_, listener := startServer(t, config.Server{
		MaxPlayers: 1, SnapshotRate: 20, InputTimeout: 100 * time.Millisecond, ReconnectWindow: 300 * time.Millisecond,
	})
	lost := join(t, listener, "lost")
	expectClosed(lost.conn)
	time.Sleep(400 * time.Millisecond)
	late := joinWith(t, listener, "late", lost.welcome.SessionToken)
	if late.welcome.SessionToken == lost.welcome.SessionToken {
		t.Error("an expired token was honoured")
	}
}

func joinWith(t *testing.T, listener *transport.MemoryListener, name string, token [16]byte) *testClient {
	t.Helper()
	conn, err := listener.Dial()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close("test over") })
	sendMessage(t, conn, &protocol.Hello{ProtocolVersion: protocol.ProtocolVersion, Name: name, Token: token})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := conn.ReceiveReliable(ctx)
	if err != nil {
		t.Fatal(err)
	}
	client := &testClient{conn: conn}
	if err := client.welcome.Decode(data); err != nil {
		t.Fatalf("no welcome: %v", err)
	}
	sendMessage(t, conn, &protocol.Ready{})
	return client
}

// ownTeam is the team of the receiving player's soldier in a snapshot.
func ownTeam(t *testing.T, snapshot *protocol.Snapshot) game.Team {
	t.Helper()
	for _, record := range snapshot.Soldiers {
		if record.State.ID == snapshot.Player.Soldier && record.Base == 0 {
			return record.State.Team
		}
	}
	t.Fatalf("the snapshot has no full record of the player's soldier")
	return 0
}
