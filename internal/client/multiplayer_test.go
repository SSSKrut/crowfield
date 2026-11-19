package client

import (
	"context"
	"math"
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
	remote := watcher.remotes[walkerID]
	if walkerID == 0 || remote == nil || len(watcher.remotes) != 1 || len(walker.remotes) != 1 {
		t.Fatalf("players do not see each other: %d and %d remotes", len(walker.remotes), len(watcher.remotes))
	}
	seen := remote.at(watcher.clock.renderTick)
	actual := walker.localSoldier()
	// The watcher sees the walker about the interpolation delay late.
	behind := actual.Position.X - seen.Position.X
	if seen.Position.X < 5 || behind < 0 || behind > 1.5 {
		t.Errorf("watcher sees the walker at x=%.2f, the walker is at x=%.2f", seen.Position.X, actual.Position.X)
	}
	t.Logf("walker at x=%.2f, seen at x=%.2f (%.2f m behind)", actual.Position.X, seen.Position.X, behind)
}
