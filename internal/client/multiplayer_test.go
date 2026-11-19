package client

import (
	"context"
	"math"
	"sync"
	"testing"
	"time"

	"ravenfield/internal/config"
	"ravenfield/internal/game"
	"ravenfield/internal/network/transport"
)

// Two players join a hosted server over QUIC and see each other: one walks,
// and the other's interpolated view of it follows.
func TestTwoPlayersSeeEachOtherOverQUIC(t *testing.T) {
	tuning := game.DefaultMovementTuning()
	local, err := startLocalServer(tuning, config.Client{Host: "127.0.0.1:0"})
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
		if sessions[i], err = connect(conn, "player", tuning); err != nil {
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
	tuning := game.DefaultMovementTuning()
	local, err := startLocalServer(tuning, config.Client{Host: "127.0.0.1:0", Dummies: 64})
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
		if players[i], err = NewHeadless(conn, "headless", tuning, uint64(i+1)); err != nil {
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
