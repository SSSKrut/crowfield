package client

import (
	"context"
	"math"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
	"ravenfield/internal/simulation"
)

// Two players join a hosted server over QUIC and see each other: one walks,
// and the other's interpolated view of it follows.
func TestTwoPlayersSeeEachOtherOverQUIC(t *testing.T) {
	rules := game.DefaultRules()
	local, err := startLocalServer(rules, config.Client{Host: "127.0.0.1:0"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := local.stop(); err != nil {
			t.Error(err)
		}
	}()
	var sessions [2]*session
	for i := range sessions {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		conn, err := transport.DialQUIC(ctx, local.network.Addr(), transport.ClientTLSConfig(nil), transport.QUICOptions{})
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if sessions[i], err = connect(conn, "player", rules, [16]byte{}); err != nil {
			t.Fatal(err)
		}
		defer sessions[i].close()
	}
	walker, watcher := sessions[0], sessions[1]
	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	for range 3 * game.TickRate {
		<-ticker.C
		if _, err := walker.sendCommand(game.NewInputCommand(0, 1, 0, math.Pi/2, 0, 0)); err != nil {
			t.Fatal(err)
		}
		if _, err := watcher.sendCommand(game.InputCommand{}); err != nil {
			t.Fatal(err)
		}
		for _, s := range sessions {
			if _, err := s.poll(); err != nil {
				t.Fatal(err)
			}
			s.clock.advance(game.TickDelta)
		}
	}
	walkerID := walker.player.Soldier
	known := watcher.soldiers[walkerID.Slot()]
	if walkerID == 0 || known == nil || known.soldier.ID != walkerID || remotes(watcher) != 1 || remotes(walker) != 1 {
		t.Fatalf("players do not see each other: %d and %d remotes", remotes(walker), remotes(watcher))
	}
	seen := known.remote.at(watcher.clock.renderTick)
	actual := walker.localSoldier()
	// The watcher sees the walker about the interpolation delay late.
	behind := actual.Position.X - seen.Position.X
	if seen.Position.X < 5 || behind < 0 || behind > 1.5 {
		t.Errorf("watcher sees the walker at x=%.2f, the walker is at x=%.2f", seen.Position.X, actual.Position.X)
	}
	t.Logf("walker at x=%.2f, seen at x=%.2f (%.2f m behind)", actual.Position.X, seen.Position.X, behind)
}

// Headless clients play through QUIC against a hosted server with dummies:
// every tick runs, the clock holds without a jump, no command comes late, no
// delta misses its base, and the prediction never needs a correction.
func TestHeadlessClientsPlayOverQUIC(t *testing.T) {
	rules := game.DefaultRules()
	local, err := startLocalServer(rules, config.Client{Host: "127.0.0.1:0", Dummies: 64})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := local.stop(); err != nil {
			t.Error(err)
		}
	}()
	const clients, seconds = 4, 3
	players := make([]*Headless, clients)
	for i := range players {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		conn, err := transport.DialQUIC(ctx, local.network.Addr(), transport.ClientTLSConfig(nil), transport.QUICOptions{})
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if players[i], err = NewHeadless(conn, "headless", rules, uint64(i+1)); err != nil {
			t.Fatal(err)
		}
		defer players[i].Close()
	}
	ctx, cancel := context.WithTimeout(context.Background(), seconds*time.Second)
	defer cancel()
	var group sync.WaitGroup
	errs := make([]error, clients)
	for i, player := range players {
		group.Go(func() { errs[i] = player.Run(ctx) })
	}
	group.Wait()
	spawn := game.PrototypeScene().Spawn
	for i, player := range players {
		stats := player.Stats()
		if errs[i] != nil || stats.Ticks < seconds*game.TickRate*9/10 || stats.Soldiers != 64+clients {
			t.Errorf("client %d: %v after %d ticks, knowing %d soldiers", i, errs[i], stats.Ticks, stats.Soldiers)
		}
		if stats.Jumps+stats.Late+stats.Unresolved+stats.Corrections > 0 {
			t.Errorf("client %d: %d jumps, %d late, %d unresolved, %d corrections", i, stats.Jumps, stats.Late, stats.Unresolved, stats.Corrections)
		}
		if moved := distance(player.Position(), spawn); moved < 2 {
			t.Errorf("client %d moved only %.2f m", i, moved)
		}
		t.Logf("client %d: %d ticks, %d snapshots, %.1f KB/s, lead %.2f", i, stats.Ticks, stats.Snapshots,
			float64(stats.Bytes)/1024/seconds, stats.Lead)
	}
}

// The main test of disconnection: the link of one player breaks like a
// pulled cable. The server drops the player after the input timeout and the
// other player sees its soldier go; the client notices the silence, comes
// back over a new connection with its token, and gets its place and team
// again. At no moment are there two soldiers of one player.
func TestPlayerComesBackAfterTheLinkBreaks(t *testing.T) {
	address := startTestServer(t, config.Server{
		MaxPlayers: 2, SnapshotRate: 20, InputTimeout: 300 * time.Millisecond, ReconnectWindow: 10 * time.Second,
	})
	rules := game.DefaultRules()
	watcher := joinHeadless(t, address, transport.QUICOptions{}, 1)
	link := &cuttable{}
	breaker := joinHeadless(t, address, transport.QUICOptions{WrapPacketConn: func(udp net.PacketConn) net.PacketConn {
		link.PacketConn = udp
		return link
	}}, 2)
	breaker.session.timeout = 300 * time.Millisecond
	player := breaker.Player()

	ticker := time.NewTicker(game.TickDuration)
	defer ticker.Stop()
	breakerPlays := true
	// play ticks both clients until the condition holds, at most for limit.
	play := func(what string, limit time.Duration, condition func() bool) {
		t.Helper()
		for deadline := time.Now().Add(limit); !condition(); {
			if time.Now().After(deadline) {
				t.Fatalf("%s did not happen within %s", what, limit)
			}
			<-ticker.C
			if err := watcher.Tick(); err != nil {
				t.Fatal(err)
			}
			if breakerPlays {
				if err := breaker.Tick(); err != nil {
					breakerPlays = false
					t.Logf("the breaking client stopped: %v", err)
				}
			}
		}
	}
	play("seeing the other player", 3*time.Second, func() bool { return len(remoteSoldiers(watcher)) == 1 })
	before := remoteSoldiers(watcher)[0]

	link.cut.Store(true)
	play("noticing the silence", 3*time.Second, func() bool { return !breakerPlays })
	play("removing the lost soldier", 3*time.Second, func() bool { return len(remoteSoldiers(watcher)) == 0 })

	conn := dialTestServer(t, address, transport.QUICOptions{})
	if err := breaker.Rejoin(conn, rules); err != nil {
		t.Fatal(err)
	}
	breakerPlays = true
	if breaker.Player() != player {
		t.Errorf("came back as player %d, was %d", breaker.Player(), player)
	}
	play("seeing the player back", 3*time.Second, func() bool { return len(remoteSoldiers(watcher)) == 1 })
	start := time.Now()
	play("a second of play", 2*time.Second, func() bool {
		if count := len(remoteSoldiers(watcher)); count != 1 {
			t.Fatalf("the watcher sees %d soldiers of the other player", count)
		}
		return time.Since(start) >= time.Second
	})
	after := remoteSoldiers(watcher)[0]
	if after.ID == before.ID || after.Team != before.Team {
		t.Errorf("back as soldier %#04x of team %d; was %#04x of team %d", after.ID, after.Team, before.ID, before.Team)
	}
	if others := remoteSoldiers(breaker); len(others) != 1 || breaker.Stats().Corrections != 0 {
		t.Errorf("the returned player sees %d others and had %d corrections: %+v", len(others), breaker.Stats().Corrections, breaker.Stats())
	}
}

// cuttable is a UDP socket whose traffic can be cut both ways at once, like
// a pulled cable: nothing goes out, and what comes in is dropped.
type cuttable struct {
	net.PacketConn
	cut atomic.Bool
}

func (c *cuttable) WriteTo(data []byte, address net.Addr) (int, error) {
	if c.cut.Load() {
		return len(data), nil
	}
	return c.PacketConn.WriteTo(data, address)
}

func (c *cuttable) ReadFrom(data []byte) (int, net.Addr, error) {
	for {
		n, address, err := c.PacketConn.ReadFrom(data)
		if err != nil || !c.cut.Load() {
			return n, address, err
		}
	}
}

// startTestServer runs a dedicated server over QUIC on the loopback.
func startTestServer(t *testing.T, settings config.Server) string {
	t.Helper()
	certificate, _, err := transport.GenerateCertificate()
	if err != nil {
		t.Fatal(err)
	}
	listener, err := transport.ListenQUIC("127.0.0.1:0", transport.ServerTLSConfig(certificate), transport.QUICOptions{})
	if err != nil {
		t.Fatal(err)
	}
	server, err := simulation.NewServer(settings, game.DefaultRules())
	if err != nil {
		t.Fatal(err)
	}
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
	return listener.Addr()
}

func dialTestServer(t *testing.T, address string, options transport.QUICOptions) transport.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := transport.DialQUIC(ctx, address, transport.ClientTLSConfig(nil), options)
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func joinHeadless(t *testing.T, address string, options transport.QUICOptions, seed uint64) *Headless {
	t.Helper()
	player, err := NewHeadless(dialTestServer(t, address, options), "player", game.DefaultRules(), seed)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(player.Close)
	return player
}

// remoteSoldiers are the soldiers a client knows besides its own.
func remoteSoldiers(h *Headless) []game.Soldier {
	var others []game.Soldier
	for _, known := range h.session.soldiers {
		if known.soldier.ID != h.session.player.Soldier {
			others = append(others, known.soldier)
		}
	}
	return others
}
